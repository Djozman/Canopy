import Foundation
import CryptoKit
import Network
import BigInt

// MARK: - MSE/PE — Message Stream Encryption / Protocol Encryption
//
// Implementation of the protocol specified in:
//   https://wiki.vuze.com/w/Message_Stream_Encryption
//
// 5-step handshake:
//   1.  A→B:  Ya || PadA            (DH public key + 0–512 random padding)
//   2.  B→A:  Yb || PadB
//   3.  A→B:  HASH('req1', S) ||
//             HASH('req2', SKEY) XOR HASH('req3', S) ||
//             ENC(VC || crypto_provide || len(PadC) || PadC || len(IA)) ||
//             ENC(IA)
//   4.  B→A:  ENC(VC || crypto_select || len(padD) || padD)
//   5.  Both sides switch to ENCRYPT2 (RC4 if select=0x02, plaintext if select=0x01)
//
// Key derivation (per direction):
//   K_A = SHA1("keyA" || S || SKEY)   – initiator → responder stream
//   K_B = SHA1("keyB" || S || SKEY)   – responder → initiator stream
// First 1024 bytes of each RC4 keystream are discarded (defeats early-keystream attacks).

// MARK: - Encryption mode

enum MSEMode: String, Sendable, CaseIterable, Identifiable {
    case disabled       // always plaintext, reject MSE peers
    case enabled        // prefer MSE outbound; accept either inbound; per-peer fallback to plaintext
    case forced         // always MSE (initiator + responder); reject plaintext peers
    var id: String { rawValue }
    var label: String {
        switch self {
        case .disabled: "Disabled (plaintext only)"
        case .enabled:  "Enabled (prefer encryption, fall back)"
        case .forced:   "Required (encrypted only)"
        }
    }
}

// MARK: - Diffie-Hellman (RFC 2412 group 1, 768-bit MODP)

final class MSEDH {
    private static let pHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A3620FFFFFFFFFFFFFFFF"
    private static let P = BigUInt(pHex, radix: 16)!
    private static let G = BigUInt(2)

    private let privateKey: BigUInt
    let publicKeyData: Data       // Ya / Yb — always 96 bytes (768 bits)

    init() {
        var rand = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &rand)
        self.privateKey = BigUInt(Data(rand))
        let y = Self.G.power(self.privateKey, modulus: Self.P)
        self.publicKeyData = Self.pad96(y.serialize())
    }

    /// Computes S = peer_public ^ private mod P. CPU-bound (~30–80 ms on M1) — call from
    /// `Task.detached(priority: .userInitiated)` to avoid blocking the actor.
    func computeSharedSecret(remotePublicKeyData: Data) -> Data {
        let Yb = BigUInt(remotePublicKeyData)
        let S = Yb.power(privateKey, modulus: Self.P)
        return Self.pad96(S.serialize())
    }

    private static func pad96(_ data: Data) -> Data {
        if data.count == 96 { return data }
        if data.count < 96 { return Data(repeating: 0, count: 96 - data.count) + data }
        return data.suffix(96)
    }
}

// MARK: - RC4 (used for the obfuscation cipher)

private final class RC4 {
    private var s = [UInt8](0...255)
    private var i: Int = 0
    private var j: Int = 0

    init(key: Data) {
        var jj = 0
        for ii in 0..<256 {
            jj = (jj + Int(s[ii]) + Int(key[key.startIndex + (ii % key.count)])) % 256
            s.swapAt(ii, jj)
        }
    }

    func process(_ data: Data) -> Data {
        var out = Data(count: data.count)
        let base = data.startIndex
        for idx in 0..<data.count {
            i = (i + 1) % 256
            j = (j + Int(s[i])) % 256
            s.swapAt(i, j)
            let k = s[(Int(s[i]) + Int(s[j])) % 256]
            out[idx] = data[base + idx] ^ k
        }
        return out
    }
}

// MARK: - Stream cipher (one direction at a time)

/// Two RC4 streams (encrypt + decrypt), independently keyed per MSE spec, with the
/// 1024-byte discard already applied. `incomingVCMarker` / `outgoingVCMarker` are the
/// 8-byte ciphertexts of the all-zero VC — used for sync-scanning across PadB / PadA.
final class MSECipher {
    enum Role { case initiator, responder }

    private let encryptor: RC4
    private let decryptor: RC4
    let incomingVCMarker: Data
    let outgoingVCMarker: Data

    init(sharedSecret S: Data, infoHash SKEY: Data, role: Role) {
        let aKey = Self.sha1(prefix: "keyA", S: S, SKEY: SKEY)
        let bKey = Self.sha1(prefix: "keyB", S: S, SKEY: SKEY)

        let outKey: Data
        let inKey:  Data
        switch role {
        case .initiator: outKey = aKey; inKey = bKey
        case .responder: outKey = bKey; inKey = aKey
        }

        self.encryptor = RC4(key: outKey)
        self.decryptor = RC4(key: inKey)
        _ = self.encryptor.process(Data(count: 1024))
        _ = self.decryptor.process(Data(count: 1024))

        // Compute markers via fresh preview RC4s — advancing the live ciphers would
        // desync them.
        let outPreview = RC4(key: outKey); _ = outPreview.process(Data(count: 1024))
        self.outgoingVCMarker = outPreview.process(Data(count: 8))
        let inPreview  = RC4(key: inKey);  _ = inPreview.process(Data(count: 1024))
        self.incomingVCMarker = inPreview.process(Data(count: 8))
    }

    func encrypt(_ data: Data) -> Data { encryptor.process(data) }
    func decrypt(_ data: Data) -> Data { decryptor.process(data) }

    private static func sha1(prefix: String, S: Data, SKEY: Data) -> Data {
        var buf = Data(prefix.utf8); buf.append(S); buf.append(SKEY)
        return Data(Insecure.SHA1.hash(data: buf))
    }
}

// MARK: - Protocol-level helpers

enum MSEHashes {
    static let req1 = "req1".data(using: .utf8)!
    static let req2 = "req2".data(using: .utf8)!
    static let req3 = "req3".data(using: .utf8)!

    static func req1Hash(S: Data) -> Data {
        var buf = req1; buf.append(S)
        return Data(Insecure.SHA1.hash(data: buf))
    }
    static func req2Hash(SKEY: Data) -> Data {
        var buf = req2; buf.append(SKEY)
        return Data(Insecure.SHA1.hash(data: buf))
    }
    static func req3Hash(S: Data) -> Data {
        var buf = req3; buf.append(S)
        return Data(Insecure.SHA1.hash(data: buf))
    }
    static func xor(_ a: Data, _ b: Data) -> Data {
        precondition(a.count == b.count)
        var out = Data(count: a.count)
        for i in 0..<a.count {
            out[i] = a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return out
    }
}

// MARK: - Constants

enum MSEConst {
    static let vc           = Data(repeating: 0, count: 8)
    static let cryptoPlain: UInt32 = 0x01
    static let cryptoRC4:   UInt32 = 0x02
    static let maxPad       = 512
    /// Generous scan ceiling: 512 (PadA/PadB) + 20 (req1) + slack — must exceed
    /// `maxPad + max(reqHash=20, vcMarker=8)` to cover the spec's worst case.
    static let maxScan      = 600
    /// Hard cap on the whole MSE handshake — fail fast if a peer doesn't speak our flavor.
    static let handshakeTimeoutSeconds = 10.0
}

enum MSEPad {
    static func random() -> Data {
        let len = Int.random(in: 0...MSEConst.maxPad)
        guard len > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: len)
        _ = SecRandomCopyBytes(kSecRandomDefault, len, &bytes)
        return Data(bytes)
    }
}

// MARK: - Connection I/O helper

/// Transport-agnostic byte stream for the MSE handshake. The TCP convenience init wraps
/// `NWConnection`; the generic init takes closures so callers can plug in any transport
/// (used by `UTPConnection` to drive MSE over uTP).
final class MSEStream: @unchecked Sendable {
    private let sendImpl: (Data) async throws -> Void
    private let receiveImpl: () async throws -> Data
    private var buffer = Data()
    private let lock = NSLock()

    init(prebuffer: Data,
         send: @escaping (Data) async throws -> Void,
         receive: @escaping () async throws -> Data) {
        self.buffer = prebuffer
        self.sendImpl = send
        self.receiveImpl = receive
    }

    convenience init(connection: NWConnection, prebuffer: Data = Data()) {
        self.init(prebuffer: prebuffer,
                  send: { data in
                      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                          connection.send(content: data, completion: .contentProcessed { err in
                              if let err = err { cont.resume(throwing: err) } else { cont.resume() }
                          })
                      }
                  },
                  receive: {
                      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                          connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, done, err in
                              if let err = err { cont.resume(throwing: err); return }
                              if let data, !data.isEmpty { cont.resume(returning: data); return }
                              if done { cont.resume(throwing: MSEError.eof); return }
                              cont.resume(returning: Data())
                          }
                      }
                  })
    }

    func leftover() -> Data { lock.withLock { let b = buffer; buffer = Data(); return b } }

    func send(_ data: Data) async throws { try await sendImpl(data) }

    func readExact(_ count: Int) async throws -> Data {
        while true {
            if let result: Data = lock.withLock({ () -> Data? in
                guard buffer.count >= count else { return nil }
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                return out
            }) { return result }
            try await pumpOnce()
        }
    }

    func readUntil(pattern: Data, maxAhead: Int) async throws -> Data {
        var scanned = 0
        while true {
            if let pre: Data = lock.withLock({ () -> Data? in
                guard let r = buffer.firstRange(of: pattern) else { return nil }
                let pre = Data(buffer[buffer.startIndex..<r.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return pre
            }) { return pre }
            if scanned >= maxAhead { throw MSEError.scanLimit }
            let before = lock.withLock { buffer.count }
            try await pumpOnce()
            let after  = lock.withLock { buffer.count }
            scanned += (after - before)
        }
    }

    private func pumpOnce() async throws {
        let chunk = try await receiveImpl()
        lock.withLock { buffer.append(chunk) }
    }
}

enum MSEError: LocalizedError {
    case eof
    case scanLimit
    case badHandshake(String)
    case unknownInfoHash
    case noEncryptionAgreement
    case timeout
    var errorDescription: String? {
        switch self {
        case .eof: return "Peer closed during MSE handshake"
        case .scanLimit: return "Padding scan limit exceeded"
        case .badHandshake(let m): return "MSE handshake error: \(m)"
        case .unknownInfoHash: return "MSE peer requested unknown info-hash"
        case .noEncryptionAgreement: return "No common crypto_provide/crypto_select"
        case .timeout: return "MSE handshake timed out"
        }
    }
}

/// Wraps an async operation with a hard timeout. On timeout, throws `MSEError.timeout`.
func withMSETimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MSEError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Self-test

/// In-memory MSE round-trip — initiator + responder linked by a Pipe actor. Catches
/// regressions in DH math, RC4 keying / 1024-byte discard, VC marker scanning,
/// req-hash routing, padding, crypto_provide / crypto_select, and post-handshake
/// bidirectional decryption. Logs result; returns Bool.
enum MSESelfTest {
    private actor Pipe {
        private var aBuf = Data()
        private var bBuf = Data()
        private var aWaiter: CheckedContinuation<Data, Error>?
        private var bWaiter: CheckedContinuation<Data, Error>?

        func sendToA(_ data: Data) {
            if let w = aWaiter { aWaiter = nil; w.resume(returning: data) }
            else { aBuf.append(data) }
        }
        func sendToB(_ data: Data) {
            if let w = bWaiter { bWaiter = nil; w.resume(returning: data) }
            else { bBuf.append(data) }
        }
        func recvA() async throws -> Data {
            if !aBuf.isEmpty { let c = aBuf; aBuf = Data(); return c }
            return try await withCheckedThrowingContinuation { aWaiter = $0 }
        }
        func recvB() async throws -> Data {
            if !bBuf.isEmpty { let c = bBuf; bBuf = Data(); return c }
            return try await withCheckedThrowingContinuation { bWaiter = $0 }
        }
    }

    static func run() async -> Bool {
        let pipe = Pipe()
        let infoHash = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        let myPeerId = Data((0..<20).map { _ in UInt8.random(in: 0...255) })

        var ia = Data()
        ia.append(19); ia.append(contentsOf: "BitTorrent protocol".utf8)
        ia.append(contentsOf: [UInt8](repeating: 0, count: 8))
        ia.append(infoHash); ia.append(myPeerId)

        let initStream = MSEStream(
            prebuffer: Data(),
            send: { d in await pipe.sendToB(d) },
            receive: { try await pipe.recvA() })

        let respStream = MSEStream(
            prebuffer: Data(),
            send: { d in await pipe.sendToA(d) },
            receive: { try await pipe.recvB() })

        async let initResultTask: MSEInitiatorResult? = {
            try? await MSEInitiator.run(stream: initStream, infoHash: infoHash, ia: ia, mode: .forced)
        }()
        async let respResultTask: MSEResponderResult? = {
            try? await MSEResponder.run(stream: respStream, knownInfoHashes: [infoHash], mode: .forced)
        }()
        let (initResult, respResult) = await (initResultTask, respResultTask)

        guard let ir = initResult, let rr = respResult else {
            print("[MSE-SELFTEST] FAIL — handshake did not complete on both sides"); return false
        }
        guard let initCipher = ir.cipher, let respCipher = rr.cipher else {
            print("[MSE-SELFTEST] FAIL — RC4 mode not negotiated"); return false
        }
        guard rr.infoHash == infoHash else {
            print("[MSE-SELFTEST] FAIL — info-hash routing"); return false
        }
        guard rr.ia == ia else {
            print("[MSE-SELFTEST] FAIL — IA round-trip"); return false
        }

        let payload1 = Data("hello from initiator".utf8)
        await pipe.sendToB(initCipher.encrypt(payload1))
        let recv1 = (try? await pipe.recvA()) ?? Data()
        guard respCipher.decrypt(recv1) == payload1 else {
            print("[MSE-SELFTEST] FAIL — initiator → responder payload"); return false
        }

        let payload2 = Data("hello from responder".utf8)
        await pipe.sendToA(respCipher.encrypt(payload2))
        let recv2 = (try? await pipe.recvB()) ?? Data()
        guard initCipher.decrypt(recv2) == payload2 else {
            print("[MSE-SELFTEST] FAIL — responder → initiator payload"); return false
        }

        print("[MSE-SELFTEST] OK — DH, keying, VC sync, IA, payload all verified")
        return true
    }
}

// MARK: - Initiator handshake

struct MSEInitiatorResult {
    let cipher: MSECipher?
    let decryptedLeftover: Data
}

enum MSEInitiator {
    /// Runs the 5-step initiator handshake on a connected stream. `ia` is sent inside
    /// step 3 (encrypted) — for BitTorrent this is the standard 68-byte BT handshake.
    static func run(stream: MSEStream,
                    infoHash: Data,
                    ia: Data,
                    mode: MSEMode) async throws -> MSEInitiatorResult {
        // Step 1: Ya || PadA
        let dh = MSEDH()
        var step1 = dh.publicKeyData
        step1.append(MSEPad.random())
        try await stream.send(step1)

        // Step 2: read Yb
        let yb = try await stream.readExact(96)
        let S = await Task.detached(priority: .userInitiated) {
            dh.computeSharedSecret(remotePublicKeyData: yb)
        }.value

        // Step 3: req1, req2^req3, ENC(VC | provide | len(PadC) | PadC | len(IA) | IA)
        let cipher = MSECipher(sharedSecret: S, infoHash: infoHash, role: .initiator)
        let req1 = MSEHashes.req1Hash(S: S)
        let req2 = MSEHashes.req2Hash(SKEY: infoHash)
        let req3 = MSEHashes.req3Hash(S: S)
        let req2x3 = MSEHashes.xor(req2, req3)

        let cryptoProvide: UInt32 = (mode == .forced) ? MSEConst.cryptoRC4
                                                       : (MSEConst.cryptoPlain | MSEConst.cryptoRC4)
        let padC = MSEPad.random()

        var headerPlain = Data()
        headerPlain.append(MSEConst.vc)
        headerPlain.appendUInt32(cryptoProvide)
        headerPlain.appendUInt16(UInt16(padC.count))
        headerPlain.append(padC)
        headerPlain.appendUInt16(UInt16(ia.count))
        headerPlain.append(ia)
        let encHeader = cipher.encrypt(headerPlain)

        var step3 = Data()
        step3.append(req1)
        step3.append(req2x3)
        step3.append(encHeader)
        try await stream.send(step3)

        // Step 4: scan past PadB for encrypted-VC marker
        _ = try await stream.readUntil(pattern: cipher.incomingVCMarker, maxAhead: MSEConst.maxScan)
        // The marker itself IS the encrypted VC — advance the cipher's decryptor 8 bytes
        _ = cipher.decrypt(Data(count: 8))

        let csAndLen = try await stream.readExact(6)
        let plainCS  = cipher.decrypt(csAndLen)
        let cryptoSelect = plainCS.readUInt32(at: 0)
        let padDLen = Int(plainCS.readUInt16(at: 4))

        if padDLen > 0 {
            let padD = try await stream.readExact(padDLen)
            _ = cipher.decrypt(padD)
        }

        let useRC4: Bool
        switch cryptoSelect {
        case MSEConst.cryptoRC4:   useRC4 = true
        case MSEConst.cryptoPlain: useRC4 = false
        default: throw MSEError.noEncryptionAgreement
        }
        if mode == .forced && !useRC4 { throw MSEError.noEncryptionAgreement }

        var leftover = stream.leftover()
        if useRC4 && !leftover.isEmpty { leftover = cipher.decrypt(leftover) }

        return MSEInitiatorResult(cipher: useRC4 ? cipher : nil, decryptedLeftover: leftover)
    }
}

// MARK: - Responder handshake

struct MSEResponderResult {
    let infoHash: Data
    let cipher: MSECipher?
    let ia: Data
    let decryptedLeftover: Data
}

enum MSEResponder {
    /// Performs the responder side. `knownInfoHashes` are all SKEYs we currently care
    /// about (one per active torrent); the matching one is chosen from `req2 ⊕ req3`.
    static func run(stream: MSEStream,
                    knownInfoHashes: [Data],
                    mode: MSEMode) async throws -> MSEResponderResult {
        let ya = try await stream.readExact(96)
        let dh = MSEDH()
        let S = await Task.detached(priority: .userInitiated) {
            dh.computeSharedSecret(remotePublicKeyData: ya)
        }.value

        var step2 = dh.publicKeyData
        step2.append(MSEPad.random())
        try await stream.send(step2)

        let req1 = MSEHashes.req1Hash(S: S)
        _ = try await stream.readUntil(pattern: req1, maxAhead: MSEConst.maxScan)

        let req2x3Received = try await stream.readExact(20)
        let req3 = MSEHashes.req3Hash(S: S)
        var matchedHash: Data?
        for hash in knownInfoHashes {
            let candidate = MSEHashes.xor(MSEHashes.req2Hash(SKEY: hash), req3)
            if candidate == req2x3Received { matchedHash = hash; break }
        }
        guard let infoHash = matchedHash else { throw MSEError.unknownInfoHash }

        let cipher = MSECipher(sharedSecret: S, infoHash: infoHash, role: .responder)

        let vcEnc       = try await stream.readExact(8)
        let vcPlain     = cipher.decrypt(vcEnc)
        guard vcPlain == MSEConst.vc else { throw MSEError.badHandshake("VC mismatch") }

        let providePadC = try await stream.readExact(6)
        let providePlain = cipher.decrypt(providePadC)
        let cryptoProvide = providePlain.readUInt32(at: 0)
        let padCLen = Int(providePlain.readUInt16(at: 4))
        if padCLen > MSEConst.maxPad { throw MSEError.badHandshake("PadC > 512") }
        if padCLen > 0 {
            let padC = try await stream.readExact(padCLen)
            _ = cipher.decrypt(padC)
        }
        let iaLenEnc = try await stream.readExact(2)
        let iaLen    = Int(cipher.decrypt(iaLenEnc).readUInt16(at: 0))
        let iaEnc    = try await stream.readExact(iaLen)
        let ia       = cipher.decrypt(iaEnc)

        let prefersRC4 = (mode == .forced) || (mode == .enabled)
        let select: UInt32
        if prefersRC4 && (cryptoProvide & MSEConst.cryptoRC4) != 0 {
            select = MSEConst.cryptoRC4
        } else if (cryptoProvide & MSEConst.cryptoPlain) != 0 && mode != .forced {
            select = MSEConst.cryptoPlain
        } else if (cryptoProvide & MSEConst.cryptoRC4) != 0 {
            select = MSEConst.cryptoRC4
        } else {
            throw MSEError.noEncryptionAgreement
        }

        let padD = MSEPad.random()
        var step4Plain = Data()
        step4Plain.append(MSEConst.vc)
        step4Plain.appendUInt32(select)
        step4Plain.appendUInt16(UInt16(padD.count))
        step4Plain.append(padD)
        try await stream.send(cipher.encrypt(step4Plain))

        var leftover = stream.leftover()
        let useRC4 = (select == MSEConst.cryptoRC4)
        if useRC4 && !leftover.isEmpty { leftover = cipher.decrypt(leftover) }

        return MSEResponderResult(infoHash: infoHash,
                                  cipher: useRC4 ? cipher : nil,
                                  ia: ia,
                                  decryptedLeftover: leftover)
    }
}
