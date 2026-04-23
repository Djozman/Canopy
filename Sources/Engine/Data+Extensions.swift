import Foundation

extension Data {
    func readUInt64(at offset: Int) -> UInt64 {
        let s = index(startIndex, offsetBy: offset)
        let e = index(startIndex, offsetBy: offset + 8)
        return self[s..<e].withUnsafeBytes { $0.load(as: UInt64.self).byteSwapped }
    }
    
    func readUInt32(at offset: Int) -> UInt32 {
        let s = index(startIndex, offsetBy: offset)
        let e = index(startIndex, offsetBy: offset + 4)
        return self[s..<e].withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }
    }
    
    func readUInt16(at offset: Int) -> UInt16 {
        let s = index(startIndex, offsetBy: offset)
        let e = index(startIndex, offsetBy: offset + 2)
        return self[s..<e].withUnsafeBytes { $0.load(as: UInt16.self).byteSwapped }
    }
    
    mutating func appendUInt64(_ v: UInt64) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    
    mutating func appendUInt32(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    
    mutating func appendInt32(_ v: Int32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    
    mutating func appendUInt16(_ v: UInt16) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
