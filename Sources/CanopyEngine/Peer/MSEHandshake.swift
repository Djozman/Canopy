import Foundation
import Network

enum MSEError: Error {
    case peerRefused
    case invalidVC
    case infoHashMismatch
    case cryptoNotSupported
    case invalidPublicKey
    case timeout
    case peerIsPlaintext(raw: Data)  // peer sent plaintext BT instead of MSE
}

enum MSEHandshake {

    // MARK: - Outbound (we initiate)

    static func outbound(conn: NWConnection, infoHash: Data) async throws -> EncryptedStream {
        let (priv, pub) = DH768.generateKeypair()

        // Step 1: Ya || PadA
        let padALen = Int.random(in: 0...512)
        var padA = Data(count: padALen)
        padA.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, padALen, $0.baseAddress!) }
        try await conn.send(content: pub + padA)

        // Step 2: Receive Yb (96 bytes). Some peers send a plaintext BT
        // handshake (68 bytes, byte 0 = 19) instead of MSE. Detect them.
        let yb: Data
        do {
            yb = try await withTimeout(seconds: 2) {
                var buf = Data()
                while buf.count < 96 {
                    let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 96 - buf.count)
                    buf.append(chunk)
                    if buf.count >= 1, buf[0] == 19 { throw MSEError.peerIsPlaintext(raw: buf) }
                }
                return buf
            }
            Log.peer.info("MSE received Yb (96 bytes)")
        } catch let e as MSEError {
            throw e  // rethrow peerIsPlaintext with captured buffer
        } catch {
            Log.peer.info("MSE failed to receive Yb: \(error)")
            throw error
        }
        guard DH768.isValidPublicKey(yb) else {
            if yb[0] == 19 { throw MSEError.peerIsPlaintext(raw: yb) }
            Log.peer.info("MSE invalid Yb public key")
            throw MSEError.invalidPublicKey
        }

        // Compute shared secret + derive keyA (A→B) and keyB (B→A)
        let S = DH768.computeShared(publicKey: yb, privateKey: priv)
        let sendCipher = RC4(key: SHA1.hash(Data("keyA".utf8) + S + infoHash))
        let recvCipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))

        // Step 3: HASH('req1', S) || HASH('req2', SKEY) XOR HASH('req3', S) || ENCRYPT(VC || crypto_provide || padC_len || PadC || ia_len)
        let req1 = SHA1.hash(Data("req1".utf8) + S)
        let h2 = SHA1.hash(Data("req2".utf8) + infoHash)
        let h3 = SHA1.hash(Data("req3".utf8) + S)

        var encPayload = Data()
        encPayload.append(Data(repeating: 0, count: 8))                // VC
        encPayload.append(contentsOf: [0x00, 0x00, 0x00, 0x03])        // crypto_provide = RC4 | plaintext
        let padCLenVal = Int.random(in: 0...512)
        var padC = Data(count: padCLenVal)
        padC.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, padCLenVal, $0.baseAddress!) }
        var padCLenBE = UInt16(padCLenVal).bigEndian
        encPayload.append(Data(bytes: &padCLenBE, count: 2))
        encPayload.append(padC)
        var iaLenBE: UInt16 = 0
        encPayload.append(Data(bytes: &iaLenBE, count: 2))

        var step3 = Data()
        step3.append(req1)
        step3.append(xorData(h2, h3))
        step3.append(sendCipher.process(encPayload))
        Log.peer.info("MSE sending step 3 (\(step3.count) bytes)")
        try await conn.send(content: step3)
        Log.peer.info("MSE step 3 sent, entering vcMarker scan")

        // Step 4: Sync on ENCRYPT(VC) across PadB — PadB is plaintext, so scan raw bytes
        let vcMarker = recvCipher.process(Data(repeating: 0, count: 8))
        let markerHex = vcMarker.map { String(format: "%02x", $0) }.joined()
        Log.peer.info("MSE vcMarker = \(markerHex, privacy: .public)")

        var raw = Data()
        while true {
            let maxRead = min(512 + 14 - raw.count, 128)
            let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: maxRead)
            raw.append(chunk)
            // Peek: if the first byte is 19 (BT protocol length), the peer is
            // speaking plaintext BitTorrent — not MSE. Hand the raw data back
            // so the caller can use it for a plaintext handshake on this socket.
            if raw.count >= 1, raw[0] == 19 {
                throw MSEError.peerIsPlaintext(raw: raw)
            }
            if let range = raw.firstRange(of: vcMarker) {
                let padBLen = range.lowerBound
                if padBLen > 512 { throw MSEError.invalidVC }
                Log.peer.info("MSE vcMarker found at offset \(padBLen)")
                var dec = Data(repeating: 0, count: 8)
                let remaining = Data(raw.dropFirst(range.upperBound))
                if !remaining.isEmpty {
                    dec.append(recvCipher.process(remaining))
                }
                let fixedLen = 8 + 4 + 2
                while dec.count < fixedLen {
                    let more = try await conn.receive(minimumIncompleteLength: 1,
                                                       maximumLength: fixedLen - dec.count)
                    dec.append(recvCipher.process(more))
                }
                guard dec[11] & 0x02 != 0 else { throw MSEError.cryptoNotSupported }
                let padDLen = Int((UInt16(dec[12]) << 8) | UInt16(dec[13]))
                while dec.count < fixedLen + padDLen {
                    let more = try await conn.receive(minimumIncompleteLength: 1,
                                                       maximumLength: fixedLen + padDLen - dec.count)
                    dec.append(recvCipher.process(more))
                }
                return EncryptedStream(conn: conn, encryptCipher: sendCipher,
                                        decryptCipher: recvCipher)
            }
            if raw.count > 512 + 8 {
                Log.peer.warning("MSE vcMarker not found after \(raw.count) raw bytes")
                throw MSEError.invalidVC
            }
        }
    }

    // MARK: - Inbound (we accept)

    /// Returns (stream, matchedInfoHash, iaBytes).
    /// iaBytes is the decrypted initial application data (BT handshake) from the peer,
    /// needed when the peer embeds the handshake in MSE (ia_len = 68 in libtorrent).
    static func inbound(conn: NWConnection, knownInfoHashes: Set<Data>,
                        initialBytes: Data) async throws -> (EncryptedStream, Data, Data?) {
        // Step 1: Accumulate Ya (96 bytes).  Remaining bytes are PadA + step-3 start.
        var buf = initialBytes
        while buf.count < 96 {
            let chunk = try await conn.receive(minimumIncompleteLength: 1,
                                                maximumLength: 96 - buf.count + 512)
            buf.append(chunk)
        }
        let ya = buf.prefix(96)
        buf = Data(buf.dropFirst(96))
        guard DH768.isValidPublicKey(ya) else { throw MSEError.invalidPublicKey }

        // Step 2: Send Yb || PadB
        let (priv, pub) = DH768.generateKeypair()
        let padBLen = Int.random(in: 0...512)
        var padB = Data(count: padBLen)
        padB.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, padBLen, $0.baseAddress!) }
        try await conn.send(content: pub + padB)

        // Compute DH shared secret + req1 (needed to sync).  Ciphers deferred until infoHash known.
        let S = DH768.computeShared(publicKey: ya, privateKey: priv)
        let req1 = SHA1.hash(Data("req1".utf8) + S)

        // Step 3a: Sync on HASH('req1', S) in the plaintext stream (after PadA)
        while true {
            if let range = buf.firstRange(of: req1) {
                guard range.lowerBound <= 512 else { throw MSEError.peerRefused }
                buf = Data(buf.dropFirst(range.lowerBound + req1.count))
                break
            }
            let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 512)
            buf.append(chunk)
            if buf.count > 512 + 20 { throw MSEError.peerRefused }
        }

        // Step 3b: Read xored hashes (20 bytes plaintext)
        while buf.count < 20 {
            let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 20 - buf.count)
            buf.append(chunk)
        }
        let xored = buf.prefix(20)
        buf = Data(buf.dropFirst(20))

        let h3 = SHA1.hash(Data("req3".utf8) + S)
        let h2Cand = xorData(xored, h3)

        var matchedIH: Data?
        for ih in knownInfoHashes {
            if SHA1.hash(Data("req2".utf8) + ih) == h2Cand { matchedIH = ih; break }
        }
        guard let infoHash = matchedIH else { throw MSEError.infoHashMismatch }

        // Now derive ciphers (inbound sends with keyB, receives with keyA)
        let sendCipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))
        let recvCipher = RC4(key: SHA1.hash(Data("keyA".utf8) + S + infoHash))

        // Step 3c: Decrypt remaining bytes — VC || crypto_provide || padC_len || PadC || ia_len || IA
        var dec = recvCipher.process(buf)
        let fixedLen = 8 + 4 + 2
        while dec.count < fixedLen {
            let raw = try await conn.receive(minimumIncompleteLength: 1, maximumLength: fixedLen - dec.count)
            dec.append(recvCipher.process(raw))
        }
        guard dec.prefix(8) == Data(repeating: 0, count: 8) else { throw MSEError.invalidVC }
        guard dec[11] & 0x02 != 0 else { throw MSEError.cryptoNotSupported }
        let padCLen = Int((UInt16(dec[12]) << 8) | UInt16(dec[13]))
        while dec.count < fixedLen + padCLen + 2 {
            let raw = try await conn.receive(minimumIncompleteLength: 1,
                                              maximumLength: fixedLen + padCLen + 2 - dec.count)
            dec.append(recvCipher.process(raw))
        }
        let iaLenOffset = fixedLen + padCLen
        let iaLen = Int((UInt16(dec[iaLenOffset]) << 8) | UInt16(dec[iaLenOffset + 1]))
        var iaBytes: Data? = nil
        if iaLen > 0 {
            while dec.count < iaLenOffset + 2 + iaLen {
                let raw = try await conn.receive(minimumIncompleteLength: 1,
                                                  maximumLength: iaLenOffset + 2 + iaLen - dec.count)
                dec.append(recvCipher.process(raw))
            }
            iaBytes = dec.subdata(in: (iaLenOffset + 2)..<(iaLenOffset + 2 + iaLen))
        }

        // Step 4: Send ENCRYPT(VC || crypto_select || padD_len || PadD)
        var resp = Data()
        resp.append(Data(repeating: 0, count: 8))              // VC
        resp.append(contentsOf: [0x00, 0x00, 0x00, 0x02])      // crypto_select = RC4
        let padDLenVal = Int.random(in: 0...512)
        var padD = Data(count: padDLenVal)
        padD.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, padDLenVal, $0.baseAddress!) }
        var padDLenBE = UInt16(padDLenVal).bigEndian
        resp.append(Data(bytes: &padDLenBE, count: 2))
        resp.append(padD)
        try await conn.send(content: sendCipher.process(resp))

        return (EncryptedStream(conn: conn, encryptCipher: sendCipher, decryptCipher: recvCipher), infoHash, iaBytes)
    }
}

// MARK: - Helpers

private func xorData(_ a: Data, _ b: Data) -> Data {
    Data(zip(a, b).map { $0 ^ $1 })
}

private extension NWConnection {
    func receiveExact(_ count: Int) async throws -> Data {
        var buf = Data()
        while buf.count < count {
            let chunk = try await receive(minimumIncompleteLength: 1, maximumLength: count - buf.count)
            buf.append(chunk)
        }
        return buf
    }
}
