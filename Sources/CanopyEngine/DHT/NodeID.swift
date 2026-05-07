import Foundation

/// 160-bit DHT node identifier (BEP 5).
public struct NodeID: Equatable, Hashable, Comparable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    public static func random() -> NodeID {
        var randomBytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &randomBytes)
        return NodeID(bytes: Data(randomBytes))!
    }

    /// XOR distance between two node IDs (BEP 5 distance metric).
    public func xor(_ other: NodeID) -> NodeID {
        let a = Array(bytes), b = Array(other.bytes)
        var result = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 { result[i] = a[i] ^ b[i] }
        return NodeID(bytes: Data(result))!
    }

    /// Lexicographic comparison for sorting (big-endian unsigned 160-bit).
    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    // MARK: - Persistence

    private static let storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".canopy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dht_node_id")
    }()

    public static func loadOrCreate() -> NodeID {
        if let data = try? Data(contentsOf: storageURL), let id = NodeID(bytes: data.prefix(20)) {
            return id
        }
        let id = random()
        try? id.bytes.write(to: storageURL, options: .atomic)
        return id
    }
}

extension NodeID: CustomDebugStringConvertible {
    public var debugDescription: String { "NodeID(\(bytes.hexString.prefix(12))...)" }
}
