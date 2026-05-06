import Foundation

/// BitTorrent peer handshake (BEP 3). 68 bytes total.
public struct Handshake {
    public static let protocolIdentifier = "BitTorrent protocol"
    public static let protocolLength: UInt8 = 19

    public let infoHash: Data    // 20 bytes
    public let peerID: Data      // 20 bytes
    public let extensions: [UInt8]  // 8 reserved bytes (BEP 10 flags in byte 5)

    /// Build outgoing handshake.
    public func encode() -> Data {
        var data = Data()
        data.append(Self.protocolLength)
        data.append(contentsOf: Self.protocolIdentifier.utf8)
        data.append(contentsOf: extensions.prefix(8) + Array(repeating: 0, count: max(0, 8 - extensions.count)))
        data.append(infoHash)
        data.append(peerID)
        return data
    }

    /// Parse incoming handshake. Returns nil if malformed.
    public static func decode(from data: Data) -> Handshake? {
        guard data.count == 68 else { return nil }
        let protoLen = data[0]
        guard protoLen == 19 else { return nil }
        guard let proto = String(data: data[1..<20], encoding: .ascii),
              proto == protocolIdentifier else { return nil }
        let extensions = Array(data[20..<28])
        let infoHash = data[28..<48]
        let peerID = data[48..<68]
        return Handshake(infoHash: Data(infoHash), peerID: Data(peerID), extensions: extensions)
    }
}
