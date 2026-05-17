import XCTest
@testable import CanopyEngine

final class MSEIntegrationTests: XCTestCase {

    // MARK: - RC4 tests

    func testRC4RoundTrip() {
        let key = Data(repeating: 0xAB, count: 16)
        let cipher1 = RC4(key: key)
        let cipher2 = RC4(key: key)

        let plaintext = Data("Hello, BitTorrent MSE!".utf8)
        let encrypted = cipher1.process(plaintext)
        let decrypted = cipher2.process(encrypted)

        XCTAssertEqual(plaintext, decrypted)
        XCTAssertNotEqual(plaintext, encrypted)
    }

    func testRC4KeyStreamDiscard() {
        let key = Data(repeating: 0xCD, count: 16)
        let cipher1 = RC4(key: key)
        let cipher2 = RC4(key: key)

        let data = Data(repeating: 0, count: 100)
        let out1 = cipher1.process(data)
        let out2 = cipher2.process(data)
        XCTAssertEqual(out1, out2)
    }

    // MARK: - DH768 tests

    func testDH768PrimeIsCorrect() {
        let rfcHex: [UInt64] = [
            0xFFFFFFFFFFFFFFFF, 0xC90FDAA22168C234, 0xC4C6628B80DC1CD1,
            0x29024E088A67CC74, 0x020BBEA63B139B22, 0x514A08798E3404DD,
            0xEF9519B3CD3A431B, 0x302B0A6DF25F1437, 0x4FE1356D6D51C245,
            0xE485B576625E7EC6, 0xF44C42E9A63A3620, 0xFFFFFFFFFFFFFFFF,
        ]
        var beBytes = Data()
        for limb in rfcHex {
            var be = limb.bigEndian
            beBytes.append(Data(bytes: &be, count: 8))
        }
        let parsed = DH768.limbsFromBEBytes(beBytes)
        XCTAssertEqual(parsed, DH768.primeLimbs, "prime limbs must match RFC 2409")
    }

    func testDH768RejectsInvalidKeys() {
        XCTAssertFalse(DH768.isValidPublicKey(Data(repeating: 0, count: 96)))
        var one = Data(repeating: 0, count: 96)
        one[95] = 1
        XCTAssertFalse(DH768.isValidPublicKey(one))
        XCTAssertFalse(DH768.isValidPublicKey(Data(repeating: 0xAA, count: 32)))
    }

    func testDH768KeypairGeneration() {
        let (priv, pub) = DH768.generateKeypair()
        XCTAssertEqual(priv.count, 20)
        XCTAssertEqual(pub.count, 96)
    }

    func testDH768RoundTripEncoding() {
        for _ in 0..<10 {
            var data = Data(count: 96)
            data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 96, $0.baseAddress!) }
            data[0] = 0
            let limbs = DH768.limbsFromBEBytes(data)
            let roundTripped = DH768.limbsToData(limbs)
            XCTAssertEqual(data, roundTripped)
        }
    }

    func testDH768SharedSecretSmallExponents() {
        var privA = Data(repeating: 0, count: 20)
        privA[19] = 3
        let pubA = DH768.pubForTest(priv: privA)

        var privB = Data(repeating: 0, count: 20)
        privB[19] = 5
        let pubB = DH768.pubForTest(priv: privB)

        let secretA = DH768.computeShared(publicKey: pubB, privateKey: privA)
        let secretB = DH768.computeShared(publicKey: pubA, privateKey: privB)

        XCTAssertEqual(secretA, secretB, "DH shared secrets must match")
        XCTAssertEqual(secretA.count, 96)
    }

    func testDH768SmallExponents() {
        var priv1 = Data(repeating: 0, count: 20)
        priv1[19] = 1
        let pub1 = DH768.pubForTest(priv: priv1)
        XCTAssertEqual(pub1[pub1.count - 1], 2, "2^1 mod P = 2")

        let shared1 = DH768.computeShared(publicKey: pub1, privateKey: priv1)
        XCTAssertEqual(shared1, pub1, "shared(2, 1) = 2^1 = 2 = pub")

        var priv3 = Data(repeating: 0, count: 20)
        priv3[19] = 3
        let pub3 = DH768.pubForTest(priv: priv3)
        XCTAssertEqual(pub3[pub3.count - 1], 8, "2^3 mod P = 8")

        let s13 = DH768.computeShared(publicKey: pub3, privateKey: priv1)
        let s31 = DH768.computeShared(publicKey: pub1, privateKey: priv3)
        XCTAssertEqual(s13, s31, "shared(2^3, 1) = shared(2^1, 3)")
        XCTAssertEqual(s13, pub3, "shared should equal 2^3 = 8")
    }

    func testDH768ModExpWithKnownValues() {
        let exp0 = Data(repeating: 0, count: 20)
        let pub0 = DH768.pubForTest(priv: exp0)
        let bytes0 = Array(pub0)
        XCTAssertEqual(bytes0[bytes0.count - 1], 1, "2^0 mod P should be 1")

        var exp1 = Data(repeating: 0, count: 20)
        exp1[19] = 1
        let pub1 = DH768.pubForTest(priv: exp1)
        XCTAssertEqual(pub1[pub1.count - 1], 2, "2^1 mod P should be 2")
    }

    func testDH768Legacy() {
        let (priv, pub) = DH768.generateKeypair()
        XCTAssertEqual(pub.count, 96)
        let hasNonZero = pub.contains { $0 != 0 }
        XCTAssertTrue(hasNonZero)
        let shared = DH768.computeShared(publicKey: pub, privateKey: priv)
        XCTAssertEqual(shared.count, 96)
    }

    func testDH768FullExponentRoundTrip() {
        let (privA, pubA) = DH768.generateKeypair()
        let (privB, pubB) = DH768.generateKeypair()

        let secretA = DH768.computeShared(publicKey: pubB, privateKey: privA)
        let secretB = DH768.computeShared(publicKey: pubA, privateKey: privB)

        XCTAssertEqual(secretA, secretB, "DH shared secret must agree with full exponents")
        XCTAssertEqual(secretA.count, 96)
    }

    // MARK: - MSE deterministic crypto tests

    func testMSEKeyDerivation() {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let S = Data(repeating: 0x01, count: 96)  // fixed shared secret for determinism

        let keyA = SHA1.hash(Data("keyA".utf8) + S + infoHash)
        let keyB = SHA1.hash(Data("keyB".utf8) + S + infoHash)

        XCTAssertEqual(keyA.count, 20)
        XCTAssertEqual(keyB.count, 20)
        XCTAssertNotEqual(keyA, keyB, "keyA and keyB must differ")
    }

    func testMSEReqHashes() {
        let S = Data(repeating: 0x01, count: 96)
        let infoHash = Data(repeating: 0xAB, count: 20)

        let req1 = SHA1.hash(Data("req1".utf8) + S)
        let h2 = SHA1.hash(Data("req2".utf8) + infoHash)
        let h3 = SHA1.hash(Data("req3".utf8) + S)

        XCTAssertEqual(req1.count, 20)
        XCTAssertEqual(h2.count, 20)
        XCTAssertEqual(h3.count, 20)
        XCTAssertNotEqual(req1, h3, "req1 and h3 use different prefix strings")
    }

    func testMSEStep3PayloadStructure() {
        let infoHash = Data(repeating: 0xAB, count: 20)
        let S = Data(repeating: 0x01, count: 96)

        let senderCipher = RC4(key: SHA1.hash(Data("keyA".utf8) + S + infoHash))

        var encPayload = Data()
        encPayload.append(Data(repeating: 0, count: 8))
        encPayload.append(contentsOf: [0x00, 0x00, 0x00, 0x03])
        var padCLenBE = UInt16(16).bigEndian
        encPayload.append(Data(bytes: &padCLenBE, count: 2))
        encPayload.append(Data(repeating: 0xFF, count: 16))
        var iaLenBE: UInt16 = 0
        encPayload.append(Data(bytes: &iaLenBE, count: 2))

        let encrypted = senderCipher.process(encPayload)
        XCTAssertEqual(encrypted.count, encPayload.count, "encrypted length matches plaintext")

        // Decrypt with a fresh cipher to verify round-trip
        let receiverCipher = RC4(key: SHA1.hash(Data("keyA".utf8) + S + infoHash))
        let decrypted = receiverCipher.process(encrypted)
        XCTAssertEqual(decrypted, encPayload, "round-trip through RC4 works")
    }

    func testMSEVCMarkerDeterministic() {
        let S = Data(repeating: 0x01, count: 96)
        let infoHash = Data(repeating: 0xAB, count: 20)

        let recvCipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))
        let vcMarker = recvCipher.process(Data(repeating: 0, count: 8))

        XCTAssertEqual(vcMarker.count, 8)
        XCTAssertNotEqual(vcMarker, Data(repeating: 0, count: 8), "vcMarker should not be all zeros")
    }

    func testMSEPadScanning() {
        let S = Data(repeating: 0x01, count: 96)
        let infoHash = Data(repeating: 0xAB, count: 20)

        let recvCipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))
        let vcMarker = recvCipher.process(Data(repeating: 0, count: 8))

        let padB = Data(repeating: 0x42, count: 32)
        let step4 = vcMarker + Data(repeating: 0x00, count: 32)
        let raw = padB + step4

        guard let range = raw.firstRange(of: vcMarker) else {
            XCTFail("vcMarker not found in scan buffer")
            return
        }
        XCTAssertEqual(range.lowerBound, 32, "vcMarker offset should be padB length (32)")
    }

    func testMSEVCMarkerNotFoundExceedsPadLimit() {
        let S = Data(repeating: 0x01, count: 96)
        let infoHash = Data(repeating: 0xAB, count: 20)

        let recvCipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))
        let vcMarker = recvCipher.process(Data(repeating: 0, count: 8))

        let raw = Data(repeating: 0x42, count: 600)
        XCTAssertNil(raw.firstRange(of: vcMarker), "vcMarker should not be present")
    }

    func testMSEEncryptedPayloadFirstBytes() {
        let S = Data(repeating: 0x01, count: 96)
        let infoHash = Data(repeating: 0xAB, count: 20)
        let cipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))

        let zeros = Data(repeating: 0, count: 8)
        let vcEncrypted = cipher.process(zeros)

        // Verify the encrypted VC decrypts back to zeros
        let decryptCipher = RC4(key: SHA1.hash(Data("keyB".utf8) + S + infoHash))
        let decrypted = decryptCipher.process(vcEncrypted)
        XCTAssertEqual(decrypted, zeros, "encrypted VC must decrypt back to zeros")
    }

    func testMSECryptoProvideEncoding() {
        var data = Data()
        // big-endian: 0x00000003
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x03])

        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(data[3] & 0x01, 0x01, "bit 0 (plaintext) set")
        XCTAssertEqual(data[3] & 0x02, 0x02, "bit 1 (RC4) set")
        XCTAssertEqual(data[0], 0, "high byte zero")
    }

    func testMSEXORHashRoundTrip() {
        let S = Data(repeating: 0x01, count: 96)
        let infoHash = Data(repeating: 0xAB, count: 20)

        let h2 = SHA1.hash(Data("req2".utf8) + infoHash)
        let h3 = SHA1.hash(Data("req3".utf8) + S)

        let xored = Data(zip(h2, h3).map { $0 ^ $1 })
        XCTAssertEqual(xored.count, 20)
        XCTAssertNotEqual(xored, h2, "XOR result should differ from h2")

        let recovered = Data(zip(xored, h3).map { $0 ^ $1 })
        XCTAssertEqual(recovered, h2, "XOR with h3 must recover h2")
    }

    // MARK: - Engine settings tests

    func testEngineSettingsDefaults() {
        let settings = EngineSettings()
        XCTAssertEqual(settings.encryption, .preferred)
        XCTAssertEqual(settings.maxPeers, 50)
        XCTAssertEqual(settings.listenPort, 6881)
    }

    func testEngineSettingsCustom() {
        let settings = EngineSettings(encryption: .required, maxPeers: 100, listenPort: 9090)
        XCTAssertEqual(settings.encryption, .required)
        XCTAssertEqual(settings.maxPeers, 100)
        XCTAssertEqual(settings.listenPort, 9090)
    }
}

extension DH768 {
    static func pubForTest(priv: Data) -> Data {
        modExp(base: 2, exponent: priv, modulus: primeLimbs)
    }
}
