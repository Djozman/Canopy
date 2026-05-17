import Foundation

public struct EngineSettings: Sendable {
    public enum EncryptionMode: Sendable {
        case disabled
        case preferred
        case required
    }

    public var encryption: EncryptionMode
    public var maxPeers: Int
    public var listenPort: UInt16
    /// Upload bandwidth limit in KiB/s. 0 = unlimited.
    public var uploadLimitKiB: Int
    /// Download bandwidth limit in KiB/s. 0 = unlimited.
    public var downloadLimitKiB: Int

    public init(encryption: EncryptionMode = .preferred,
                maxPeers: Int = 50,
                listenPort: UInt16 = 6881,
                uploadLimitKiB: Int = 0,
                downloadLimitKiB: Int = 0) {
        self.encryption = encryption
        self.maxPeers = maxPeers
        self.listenPort = listenPort
        self.uploadLimitKiB = uploadLimitKiB
        self.downloadLimitKiB = downloadLimitKiB
    }
}
