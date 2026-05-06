import Foundation

public enum BencodeError: Error {
    case unexpectedEnd
    case invalidFormat(String)
    case invalidStringLength
}

public struct BencodeDecoder {
    private let data: Data
    private var index: Data.Index

    private init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    public static func decode(_ data: Data) throws -> (BencodeValue, Range<Int>) {
        var decoder = BencodeDecoder(data: data)
        let start = decoder.index
        let value = try decoder.decodeValue()
        let range = start..<decoder.index
        return (value, range)
    }

    private mutating func decodeValue() throws -> BencodeValue {
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        switch data[index] {
        case UInt8(ascii: "i"): return try decodeInteger()
        case UInt8(ascii: "l"): return try decodeList()
        case UInt8(ascii: "d"): return try decodeDict()
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return .string(try decodeStringBytes())
        default: throw BencodeError.invalidFormat("Unexpected byte at \(index): \(data[index])")
        }
    }

    private mutating func decodeInteger() throws -> BencodeValue {
        index = data.index(after: index) // skip 'i'
        let start = index
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            index = data.index(after: index)
        }
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        let numStr = String(data: data[start..<index], encoding: .ascii) ?? ""
        index = data.index(after: index) // skip 'e'
        guard let n = Int64(numStr) else { throw BencodeError.invalidFormat("Invalid integer: \(numStr)") }
        return .integer(n)
    }

    private mutating func decodeStringBytes() throws -> Data {
        let colonIndex = data[index...].firstIndex(of: UInt8(ascii: ":")) ?? data.endIndex
        guard colonIndex < data.endIndex else { throw BencodeError.invalidStringLength }
        let lenStr = String(data: data[index..<colonIndex], encoding: .ascii) ?? ""
        guard let length = Int(lenStr) else { throw BencodeError.invalidStringLength }
        index = data.index(after: colonIndex)
        guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else {
            throw BencodeError.unexpectedEnd
        }
        let bytes = data[index..<end]
        index = end
        return Data(bytes)
    }

    private mutating func decodeList() throws -> BencodeValue {
        index = data.index(after: index) // skip 'l'
        var items: [BencodeValue] = []
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            items.append(try decodeValue())
        }
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        index = data.index(after: index) // skip 'e'
        return .list(items)
    }

    private mutating func decodeDict() throws -> BencodeValue {
        index = data.index(after: index) // skip 'd'
        var items: [(String, BencodeValue)] = []
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            let keyBytes = try decodeStringBytes()
            guard let key = String(data: keyBytes, encoding: .utf8) else {
                throw BencodeError.invalidFormat("Non-UTF8 dictionary key")
            }
            let val = try decodeValue()
            items.append((key, val))
        }
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        index = data.index(after: index) // skip 'e'
        return .dict(items)
    }
}
