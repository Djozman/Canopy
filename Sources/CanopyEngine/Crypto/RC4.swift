import Foundation

final class RC4: @unchecked Sendable {
    private var s: [UInt8] = Array(0...255)
    private var i: UInt8 = 0
    private var j: UInt8 = 0
    private let lock = NSLock()

    init(key: Data) {
        let keyBytes = Array(key)
        var j: Int = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(keyBytes[i % keyBytes.count])) & 0xFF
            s.swapAt(i, j)
        }
        // Discard first 1024 bytes of keystream (anti-Fluhrer-Mantin-Shamir)
        for _ in 0..<1024 { _ = nextByte() }
        i = 0
        j = 0
    }

    private func nextByte() -> UInt8 {
        i = i &+ 1
        j = j &+ s[Int(i)]
        s.swapAt(Int(i), Int(j))
        return s[(Int(s[Int(i)]) + Int(s[Int(j)])) & 0xFF]
    }

    func process(_ data: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        var result = Data(capacity: data.count)
        for byte in data {
            result.append(byte ^ nextByte())
        }
        return result
    }
}
