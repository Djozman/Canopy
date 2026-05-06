import Foundation

/// Per-peer extension negotiation state (BEP 10).
/// Stores the remote peer's assigned extension IDs and metadata size.
public struct PeerExtensions {
    public var utPEX: UInt8?       // remote's ID for ut_pex
    public var utMetadata: UInt8?  // remote's ID for ut_metadata
    public var metadataSize: Int?  // from metadata_size in extension handshake
}

/// Build the extension handshake payload (raw bencoded dict, no length prefix).
/// Local extension IDs: ut_pex=1, ut_metadata=2.
public func buildExtensionHandshake() -> Data {
    let m: BencodeValue = .dict([
        ("ut_pex", .integer(1)),
        ("ut_metadata", .integer(2)),
    ])
    let dict: BencodeValue = .dict([
        ("m", m),
    ])
    return BencodeEncoder.encode(dict)
}

/// Parse the remote peer's extension handshake dict. Returns nil if malformed.
public func parseExtensionHandshake(from data: Data) -> PeerExtensions? {
    guard let (value, _) = try? BencodeDecoder.decode(data),
          case .dict(let dict) = value else { return nil }

    var ext = PeerExtensions()

    // Parse "m" dict for extension IDs
    if let mPair = dict.first(where: { $0.0 == "m" }),
       case .dict(let mDict) = mPair.1 {
        if let utPexPair = mDict.first(where: { $0.0 == "ut_pex" }),
           case .integer(let id) = utPexPair.1 {
            ext.utPEX = UInt8(id)
        }
        if let utMetaPair = mDict.first(where: { $0.0 == "ut_metadata" }),
           case .integer(let id) = utMetaPair.1 {
            ext.utMetadata = UInt8(id)
        }
    }

    // Parse metadata_size
    if let sizePair = dict.first(where: { $0.0 == "metadata_size" }),
       case .integer(let size) = sizePair.1 {
        ext.metadataSize = Int(size)
    }

    return ext
}

// MARK: - PEX (BEP 11)

/// Build a PEX message (added/dropped peer lists). Returns nil if utPEXID is nil.
public func buildPEXMessage(added: [Peer], dropped: [Peer], utPEXID: UInt8?) -> PeerMessage? {
    guard let utPEXID, !added.isEmpty || !dropped.isEmpty else { return nil }
    let addedBlob = Data(added.flatMap { encodeCompactPeer($0) })
    let droppedBlob = Data(dropped.flatMap { encodeCompactPeer($0) })
    let dict: BencodeValue = .dict([
        ("added", .string(addedBlob)),
        ("dropped", .string(droppedBlob)),
    ])
    return .extended(id: utPEXID, data: BencodeEncoder.encode(dict))
}

/// Parse a PEX message. added.f and dropped.f are separate bencode keys — ignored.
public func parsePEXMessage(from data: Data) -> (added: [Peer], dropped: [Peer])? {
    guard let (value, _) = try? BencodeDecoder.decode(data),
          case .dict(let dict) = value else { return nil }
    let added: [Peer] = {
        guard let p = dict.first(where: { $0.0 == "added" }),
              case .string(let blob) = p.1 else { return [] }
        return parseCompactPeers(blob)
    }()
    let dropped: [Peer] = {
        guard let p = dict.first(where: { $0.0 == "dropped" }),
              case .string(let blob) = p.1 else { return [] }
        return parseCompactPeers(blob)
    }()
    return (added, dropped)
}
