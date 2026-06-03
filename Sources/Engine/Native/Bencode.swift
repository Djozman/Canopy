// Bencode.swift — BEP 3 bencoding: strict parser + canonical encoder.
// Pure Swift, Foundation only. Strings are byte strings (Data): piece hashes
// and some names are raw binary that is not valid UTF-8.

import Foundation

public enum Bencode: Equatable {
    case integer(Int64)
    case bytes(Data)
    case list([Bencode])
    case dict([String: Bencode])
}

public struct BencodeError: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "Bencode error at byte \(offset): \(message)" }
}

public final class BencodeParser {
    private let bytes: [UInt8]
    private var i = 0
    private var depth = 0

    /// Byte range of the root-level "info" value, captured while parsing, so the
    /// info-hash can be taken from the EXACT original bytes (no decode/re-encode).
    public private(set) var infoRange: Range<Int>?

    public init(_ data: Data) { self.bytes = [UInt8](data) }

    /// Raw bytes of the root "info" dictionary, for the SHA-1 info-hash.
    public var infoData: Data? {
        guard let r = infoRange else { return nil }
        return Data(bytes[r])
    }

    public static func decode(_ data: Data) throws -> Bencode {
        try BencodeParser(data).parseValue()
    }

    public func parseRoot() throws -> Bencode { try parseValue() }

    // MARK: - Helpers

    private func peek() throws -> UInt8 {
        guard i < bytes.count else { throw err("unexpected end of input") }
        return bytes[i]
    }
    private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private func err(_ m: String) -> BencodeError { BencodeError(message: m, offset: i) }

    // MARK: - Recursive descent

    private func parseValue() throws -> Bencode {
        let c = try peek()
        switch c {
        case UInt8(ascii: "i"): return try parseInteger()
        case UInt8(ascii: "l"): return try parseList()
        case UInt8(ascii: "d"): return try parseDict()
        case 0x30...0x39: return .bytes(try parseString())
        default: throw err("unexpected byte 0x\(String(c, radix: 16))")
        }
    }

    private func parseInteger() throws -> Bencode {
        i += 1  // 'i'
        var negative = false
        if try peek() == UInt8(ascii: "-") {
            negative = true
            i += 1
        }
        let start = i
        while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "e") else {
            throw err("invalid/unterminated integer")
        }
        let digits = Array(bytes[start..<i])
        guard !digits.isEmpty else { throw err("integer has no digits") }
        // BEP 3: reject leading zeros (i03e) and negative zero (i-0e). i0e is valid.
        if digits.count > 1, digits[0] == UInt8(ascii: "0") {
            throw err("integer has a leading zero")
        }
        if negative, digits == [UInt8(ascii: "0")] { throw err("negative zero is invalid") }
        i += 1  // 'e'
        let s = (negative ? "-" : "") + String(decoding: digits, as: UTF8.self)
        guard let n = Int64(s) else { throw err("integer out of Int64 range '\(s)'") }
        return .integer(n)
    }

    private func parseString() throws -> Data {
        let start = i
        while i < bytes.count, isDigit(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
            throw err("invalid string length prefix")
        }
        let lenDigits = Array(bytes[start..<i])
        guard !lenDigits.isEmpty else { throw err("missing string length") }
        if lenDigits.count > 1, lenDigits[0] == UInt8(ascii: "0") {
            throw err("string length has a leading zero")
        }
        guard let len = Int(String(decoding: lenDigits, as: UTF8.self)) else {
            throw err("string length out of range")
        }
        i += 1  // ':'
        guard i + len <= bytes.count else { throw err("string runs past end of input") }
        let slice = bytes[i..<(i + len)]
        i += len
        return Data(slice)
    }

    private func parseList() throws -> Bencode {
        i += 1  // 'l'
        depth += 1
        defer { depth -= 1 }
        var out: [Bencode] = []
        while try peek() != UInt8(ascii: "e") { out.append(try parseValue()) }
        i += 1  // 'e'
        return .list(out)
    }

    private func parseDict() throws -> Bencode {
        i += 1  // 'd'
        let atRoot = (depth == 0)
        depth += 1
        defer { depth -= 1 }
        var out: [String: Bencode] = [:]
        while try peek() != UInt8(ascii: "e") {
            let key = String(decoding: try parseString(), as: UTF8.self)
            guard out[key] == nil else { throw err("duplicate dictionary key '\(key)'") }
            let valueStart = i
            let value = try parseValue()
            if atRoot, key == "info" { infoRange = valueStart..<i }  // exact info bytes
            out[key] = value
        }
        i += 1  // 'e'
        return .dict(out)
    }
}

// MARK: - Canonical encoder (sorted keys, per BEP 3)

public enum BencodeEncoder {
    public static func encode(_ value: Bencode) -> Data {
        var out = Data()
        encode(value, into: &out)
        return out
    }
    private static func encode(_ value: Bencode, into out: inout Data) {
        switch value {
        case .integer(let n):
            out.append(UInt8(ascii: "i"))
            out.append(contentsOf: Array(String(n).utf8))
            out.append(UInt8(ascii: "e"))
        case .bytes(let d):
            out.append(contentsOf: Array(String(d.count).utf8))
            out.append(UInt8(ascii: ":"))
            out.append(d)
        case .list(let items):
            out.append(UInt8(ascii: "l"))
            items.forEach { encode($0, into: &out) }
            out.append(UInt8(ascii: "e"))
        case .dict(let map):
            out.append(UInt8(ascii: "d"))
            for key in map.keys.sorted() {  // ASCII keys: String sort == raw byte sort
                let k = Array(key.utf8)
                out.append(contentsOf: Array(String(k.count).utf8))
                out.append(UInt8(ascii: ":"))
                out.append(contentsOf: k)
                encode(map[key]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }
}

// MARK: - Accessors

extension Bencode {
    public var intValue: Int64? {
        if case .integer(let n) = self { return n }
        return nil
    }
    public var dataValue: Data? {
        if case .bytes(let d) = self { return d }
        return nil
    }
    public var stringValue: String? {
        if case .bytes(let d) = self { return String(data: d, encoding: .utf8) }
        return nil
    }
    public var listValue: [Bencode]? {
        if case .list(let l) = self { return l }
        return nil
    }
    public var dictValue: [String: Bencode]? {
        if case .dict(let d) = self { return d }
        return nil
    }
    public subscript(_ key: String) -> Bencode? { dictValue?[key] }
}
