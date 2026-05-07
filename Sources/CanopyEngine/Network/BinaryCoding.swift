import Foundation

// MARK: - Big-endian writers

public func writeUInt64(_ v: UInt64) -> Data {
    var val = v.bigEndian
    return Data(bytes: &val, count: 8)
}
public func writeUInt32(_ v: UInt32) -> Data {
    var val = v.bigEndian
    return Data(bytes: &val, count: 4)
}
public func writeUInt16(_ v: UInt16) -> Data {
    var val = v.bigEndian
    return Data(bytes: &val, count: 2)
}
public func writeInt64(_ v: Int64) -> Data {
    var val = UInt64(bitPattern: v).bigEndian
    return Data(bytes: &val, count: 8)
}
public func writeInt32(_ v: Int32) -> Data {
    var val = UInt32(bitPattern: v).bigEndian
    return Data(bytes: &val, count: 4)
}

// MARK: - Big-endian readers

public func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    let b = Array(data.subdata(in: offset..<min(offset + 8, data.count)))
    var result: UInt64 = 0
    for byte in b.prefix(8) { result = (result << 8) | UInt64(byte) }
    return result
}
public func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let b = Array(data.subdata(in: offset..<min(offset + 4, data.count)))
    var result: UInt32 = 0
    for byte in b.prefix(4) { result = (result << 8) | UInt32(byte) }
    return result
}
