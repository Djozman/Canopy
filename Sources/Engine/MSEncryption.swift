import Foundation
import CryptoKit

/// BEP 10 / Message Stream Encryption (MSE) / Protocol Encryption (PE).
/// Provides a way to obfuscate BitTorrent traffic to avoid ISP throttling.
final class MSEncryption {
    private var s_key: Data     // Shared secret
    private var encryptor: RC4?
    private var decryptor: RC4?
    
    init(sharedSecret: Data, infoHash: Data) {
        // Shared secret is derived from DH exchange (not implemented here for brevity, 
        // using a placeholder for the logic structure)
        self.s_key = sharedSecret
        
        // Key for encryption: SHA1(sharedSecret + infoHash)
        var encKeyData = Data()
        encKeyData.append(sharedSecret)
        encKeyData.append(infoHash)
        let encKey = Insecure.SHA1.hash(data: encKeyData)
        self.encryptor = RC4(key: Data(encKey))
        
        // Key for decryption: SHA1(sharedSecret + infoHash)
        var decKeyData = Data()
        decKeyData.append(sharedSecret)
        decKeyData.append(infoHash)
        let decKey = Insecure.SHA1.hash(data: decKeyData)
        self.decryptor = RC4(key: Data(decKey))
        
        // Discard first 1024 bytes of RC4 stream as per spec
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
