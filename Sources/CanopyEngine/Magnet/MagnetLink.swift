import Foundation

/// Parsed magnet link (BEP 9).
public struct MagnetLink: Equatable {
    public let infoHash: Data       // always exactly 20 bytes
    public let displayName: String? // from dn=
    public let trackers: [String]   // from tr=

    /// Parse a magnet URI. Returns nil if xt is missing or invalid.
    public static func parse(_ uri: String) -> MagnetLink? {
        guard uri.hasPrefix("magnet:?") else { return nil }
        let query = String(uri.dropFirst(8))
        let params = query.split(separator: "&", omittingEmptySubsequences: true)

        var infoHash: Data?
        var displayName: String?
        var trackers: [String] = []

        for param in params {
            let parts = param.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            let rawValue = String(parts[1])

            switch key {
            case "xt":
                // xt=urn:btih:<hash>
                let lower = rawValue.lowercased()
                guard lower.hasPrefix("urn:btih:") else { break }
                let hashStr = String(lower.dropFirst(9))
                if hashStr.count == 40 {
                    // Hex format
                    infoHash = Data(hex: hashStr)
                } else if hashStr.count == 32 {
                    // Base32 format (RFC 4648)
                    infoHash = Data(base32: hashStr)
                }
            case "dn":
                displayName = rawValue.removingPercentEncoding
            case "tr":
                if let decoded = rawValue.removingPercentEncoding {
                    trackers.append(decoded)
                }
            default:
                break
            }
        }

        guard let infoHash, infoHash.count == 20 else { return nil }
        return MagnetLink(infoHash: infoHash, displayName: displayName, trackers: trackers)
    }
}

// MARK: - Hex decoding

private extension Data {
    init?(hex: String) {
        guard hex.count == 40 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}

// MARK: - Base32 decoding (RFC 4648, uppercase or lowercase)

private let base32Alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

private extension Data {
    init?(base32: String) {
        let cleaned = base32.uppercased().filter { $0 != "=" }
        guard cleaned.count == 32 else { return nil }
        var bits: UInt64 = 0
        var bitCount = 0
        var bytes = [UInt8]()
        for char in cleaned {
            guard let value = base32Alphabet.firstIndex(of: char) else { return nil }
            bits = (bits << 5) | UInt64(value)
            bitCount += 5
            while bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((bits >> bitCount) & 0xFF))
            }
        }
        guard bytes.count == 20 else { return nil }
        self = Data(bytes)
    }
}
