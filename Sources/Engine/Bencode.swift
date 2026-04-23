import Foundation

indirect enum BValue {
    case int(Int)
    case bytes(Data)
    case list([BValue])
    case dict([(key: String, value: BValue)])  // ordered to preserve info-hash accuracy

    var string: String? {
        guard case .bytes(let d) = self else { return nil }
        return String(data: d, encoding: .utf8)
    }
    var int: Int? {
        guard case .int(let i) = self else { return nil }
        return i
    }
    var data: Data? {
        guard case .bytes(let d) = self else { return nil }
        return d
    }
    var list: [BValue]? {
        guard case .list(let l) = self else { return nil }
        return l
    }
    var dict: [(key: String, value: BValue)]? {
        guard case .dict(let d) = self else { return nil }
        return d
    }
    subscript(_ key: String) -> BValue? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first(where: { $0.key == key })?.value
    }
}

enum BencodeError: Error { case invalid, overflow }

extension Bencode {
    static func encode(_ value: BValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }
    private static func write(_ v: BValue, into out: inout Data) {
        switch v {
        case .int(let n):
            out.append(contentsOf: "i\(n)e".utf8)
        case .bytes(let b):
            out.append(contentsOf: "\(b.count):".utf8)
            out.append(b)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            items.forEach { write($0, into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let pairs):
            out.append(UInt8(ascii: "d"))
            for (k, v) in pairs.sorted(by: { $0.key < $1.key }) {
                write(.bytes(Data(k.utf8)), into: &out)
                write(v, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}

struct Bencode {
    static func decode(_ data: Data) throws -> BValue {
        var idx = data.startIndex
        return try parse(data, &idx)
    }

    // Returns raw bytes of the "info" dictionary for hash computation
    static func infoBytes(_ data: Data) -> Data? {
        guard let infoRange = findInfoRange(in: data) else { return nil }
        return data[infoRange]
    }

    // MARK: - Parser

    private static func parse(_ data: Data, _ i: inout Data.Index) throws -> BValue {
        guard i < data.endIndex else { throw BencodeError.invalid }
        let byte = data[i]
        switch byte {
        case UInt8(ascii: "i"): return try parseInt(data, &i)
        case UInt8(ascii: "l"): return try parseList(data, &i)
        case UInt8(ascii: "d"): return try parseDict(data, &i)
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseBytes(data, &i)
        default: throw BencodeError.invalid
        }
    }

    private static func parseInt(_ data: Data, _ i: inout Data.Index) throws -> BValue {
        i = data.index(after: i) // skip 'i'
        var neg = false
        if i < data.endIndex && data[i] == UInt8(ascii: "-") {
            neg = true
            i = data.index(after: i)
        }
        var n = 0
        while i < data.endIndex && data[i] != UInt8(ascii: "e") {
            let d = Int(data[i]) - Int(UInt8(ascii: "0"))
            guard d >= 0 && d <= 9 else { throw BencodeError.invalid }
            n = n * 10 + d
            i = data.index(after: i)
        }
        guard i < data.endIndex else { throw BencodeError.invalid }
        i = data.index(after: i) // skip 'e'
        return .int(neg ? -n : n)
    }

    private static func parseBytes(_ data: Data, _ i: inout Data.Index) throws -> BValue {
        var len = 0
        while i < data.endIndex && data[i] != UInt8(ascii: ":") {
            let d = Int(data[i]) - Int(UInt8(ascii: "0"))
            guard d >= 0 && d <= 9 else { throw BencodeError.invalid }
            len = len * 10 + d
            i = data.index(after: i)
        }
        guard i < data.endIndex else { throw BencodeError.invalid }
        i = data.index(after: i) // skip ':'
        guard let end = data.index(i, offsetBy: len, limitedBy: data.endIndex), end <= data.endIndex else {
            throw BencodeError.overflow
        }
        let bytes = Data(data[i..<end])  // copy to rebase indices to 0
        i = end
        return .bytes(bytes)
    }

    private static func parseList(_ data: Data, _ i: inout Data.Index) throws -> BValue {
        i = data.index(after: i) // skip 'l'
        var items: [BValue] = []
        while i < data.endIndex && data[i] != UInt8(ascii: "e") {
            items.append(try parse(data, &i))
        }
        guard i < data.endIndex else { throw BencodeError.invalid }
        i = data.index(after: i) // skip 'e'
        return .list(items)
    }

    private static func parseDict(_ data: Data, _ i: inout Data.Index) throws -> BValue {
        i = data.index(after: i) // skip 'd'
        var pairs: [(key: String, value: BValue)] = []
        while i < data.endIndex && data[i] != UInt8(ascii: "e") {
            let keyVal = try parseBytes(data, &i)
            guard let key = keyVal.string else { throw BencodeError.invalid }
            let value = try parse(data, &i)
            pairs.append((key, value))
        }
        guard i < data.endIndex else { throw BencodeError.invalid }
        i = data.index(after: i) // skip 'e'
        return .dict(pairs)
    }

    // Find byte range of the "info" value in a torrent file
    private static func findInfoRange(in data: Data) -> Range<Data.Index>? {
        let infoKey = Data("4:info".utf8)
        guard let keyStart = data.range(of: infoKey) else { return nil }
        var i = keyStart.upperBound
        let start = i
        // skip the value to find its end
        guard (try? parse(data, &i)) != nil else { return nil }
        return start..<i
    }
}
