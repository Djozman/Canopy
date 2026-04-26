import Foundation
import CryptoKit
import BigInt

/// BEP 10 / Message Stream Encryption (MSE) / Protocol Encryption (PE).
/// Provides a way to obfuscate BitTorrent traffic to avoid ISP throttling.

final class MSEDH {
    private static let pHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A3620FFFFFFFFFFFFFFFF"
    private static let P = BigUInt(pHex, radix: 16)!
    private static let G = BigUInt(2)

    private let privateKey: BigUInt
    let publicKeyData: Data

    init() {
        // Generate a 160-bit random private key
        var rand = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &rand)
        self.privateKey = BigUInt(Data(rand))

        // Ya = G^a mod P
        let ya = Self.G.power(self.privateKey, modulus: Self.P)
        
        // Pad to 96 bytes (768 bits)
        var yaData = ya.serialize()
        if yaData.count < 96 {
            yaData = Data(repeating: 0, count: 96 - yaData.count) + yaData
        } else if yaData.count > 96 {
            yaData = yaData.suffix(96)
        }
        self.publicKeyData = yaData
    }

    func computeSharedSecret(remotePublicKeyData: Data) -> Data {
        let Yb = BigUInt(remotePublicKeyData)
        let S = Yb.power(privateKey, modulus: Self.P)
        
        // Pad to 96 bytes
        var sData = S.serialize()
        if sData.count < 96 {
            sData = Data(repeating: 0, count: 96 - sData.count) + sData
        } else if sData.count > 96 {
            sData = sData.suffix(96)
        }
        return sData
    }
}

final class MSEncryption {
    private var s_key: Data     // Shared secret
    private var encryptor: RC4?
    private var decryptor: RC4?
    
    init(sharedSecret: Data, infoHash: Data) {
        self.s_key = sharedSecret

        // MSE spec: initiator→recipient stream key = RC4(SHA1("keyA" + S + SKEY))
        //           recipient→initiator stream key = RC4(SHA1("keyB" + S + SKEY))
        // The "keyA"/"keyB" prefixes differentiate the two directions so they use
        // independent RC4 key streams even though both sides share the same S and SKEY.
        var encKeyData = Data("keyA".utf8)
        encKeyData.append(sharedSecret)
        encKeyData.append(infoHash)
        let encKey = Insecure.SHA1.hash(data: encKeyData)
        self.encryptor = RC4(key: Data(encKey))

        var decKeyData = Data("keyB".utf8)
        decKeyData.append(sharedSecret)
        decKeyData.append(infoHash)
        let decKey = Insecure.SHA1.hash(data: decKeyData)
        self.decryptor = RC4(key: Data(decKey))

        // Discard first 1024 bytes of each RC4 stream as required by the MSE spec
        _ = self.encryptor?.process(Data(count: 1024))
        _ = self.decryptor?.process(Data(count: 1024))
    }
    
    func encrypt(_ data: Data) -> Data {
        return encryptor?.process(data) ?? data
    }
    
    func decrypt(_ data: Data) -> Data {
        return decryptor?.process(data) ?? data
    }
}

/// Simple RC4 implementation for protocol obfuscation.
private final class RC4 {
    private var s = [UInt8](0...255)
    private var i: Int = 0
    private var j: Int = 0
    
    init(key: Data) {
        var j: Int = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) % 256
            s.swapAt(i, j)
        }
    }
    
    func process(_ data: Data) -> Data {
        var result = Data(count: data.count)
        for idx in 0..<data.count {
            i = (i + 1) % 256
            j = (j + Int(s[i])) % 256
            s.swapAt(i, j)
            let t = (Int(s[i]) + Int(s[j])) % 256
            let k = s[t]
            result[idx] = data[idx] ^ k
        }
        return result
    }
}
