import Foundation

public struct PeerID {
    /// Format: -CA0100-XXXXXXXXXXXX (20 bytes total)
    /// CA = Canopy, 0100 = v0.1.0.0 (MAJ.MIN.PATCH.0)
    /// Generated once per launch, lives purely in memory.
    public static let current: Data = generate()

    public static func generate() -> Data {
        let prefix = "-CA0100-".data(using: .ascii)! // 8 bytes
        let random = (0..<12).map { _ in UInt8.random(in: 0...255) }
        return prefix + Data(random)
    }
}
