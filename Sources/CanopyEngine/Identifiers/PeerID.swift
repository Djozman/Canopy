import Foundation

public struct PeerID {
    /// Format: -CA0100-XXXXXXXXXXXX (20 bytes total)
    /// CA = Canopy, 0100 = v0.1.0.0 (MAJ.MIN.PATCH.0)
    public static func generate() -> Data {
        let prefix = "-CA0100-".data(using: .ascii)! // 8 bytes
        let random = (0..<12).map { _ in UInt8.random(in: 0...255) }
        return prefix + Data(random)
    }

    /// Persisted per launch. Read from UserDefaults, generate if missing.
    public static var current: Data {
        let key = "CanopyEngine.PeerID"
        if let existing = UserDefaults.standard.data(forKey: key) {
            return existing
        }
        let id = generate()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
