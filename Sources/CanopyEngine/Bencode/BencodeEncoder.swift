import Foundation

public struct BencodeEncoder {
    public static func encode(_ value: BencodeValue) -> Data {
        var data = Data()
        encode(value, into: &data)
        return data
    }

    private static func encode(_ value: BencodeValue, into data: inout Data) {
        switch value {
        case .integer(let n):
            data.append(contentsOf: "i\(n)e".utf8)
        case .string(let bytes):
            data.append(contentsOf: "\(bytes.count):".utf8)
            data.append(bytes)
        case .list(let items):
            data.append(UInt8(ascii: "l"))
            for item in items { encode(item, into: &data) }
            data.append(UInt8(ascii: "e"))
        case .dict(let pairs):
            data.append(UInt8(ascii: "d"))
            for (key, val) in pairs.sorted(by: { $0.0 < $1.0 }) {
                encode(.string(Data(key.utf8)), into: &data)
                encode(val, into: &data)
            }
            data.append(UInt8(ascii: "e"))
        }
    }
}
