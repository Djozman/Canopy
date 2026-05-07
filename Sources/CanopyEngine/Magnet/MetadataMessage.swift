import Foundation

/// BEP 9 — ut_metadata message types.
public enum MetadataMsg: Equatable {
    case request(piece: Int)
    case data(piece: Int, totalSize: Int, payload: Data)
    case reject(piece: Int)
}

/// Build a metadata request message.
public func buildMetadataRequest(piece: Int, extensionID: UInt8) -> PeerMessage {
    let dict: BencodeValue = .dict([
        ("msg_type", .integer(0)),
        ("piece", .integer(Int64(piece))),
    ])
    return .extended(id: extensionID, data: BencodeEncoder.encode(dict))
}

/// Build a metadata data response. The piece payload is appended AFTER the bencoded dict.
public func buildMetadataData(piece: Int, totalSize: Int, data: Data, extensionID: UInt8) -> PeerMessage {
    let dict: BencodeValue = .dict([
        ("msg_type", .integer(1)),
        ("piece", .integer(Int64(piece))),
        ("total_size", .integer(Int64(totalSize))),
    ])
    var encoded = BencodeEncoder.encode(dict)
    encoded.append(data)
    return .extended(id: extensionID, data: encoded)
}

/// Build a metadata reject message.
public func buildMetadataReject(piece: Int, extensionID: UInt8) -> PeerMessage {
    let dict: BencodeValue = .dict([
        ("msg_type", .integer(2)),
        ("piece", .integer(Int64(piece))),
    ])
    return .extended(id: extensionID, data: BencodeEncoder.encode(dict))
}

/// Parse a BEP 9 metadata message. Returns nil if malformed.
/// For data messages, the payload bytes after the bencoded dict are extracted via the range returned by BencodeDecoder.
public func parseMetadataMessage(from raw: Data) -> MetadataMsg? {
    guard let (value, range) = try? BencodeDecoder.decode(raw),
          case .dict(let dict) = value else { return nil }

    guard let typePair = dict.first(where: { $0.0 == "msg_type" }),
          case .integer(let msgType) = typePair.1 else { return nil }

    let piece: Int = {
        guard let p = dict.first(where: { $0.0 == "piece" }),
              case .integer(let v) = p.1 else { return -1 }
        return Int(v)
    }()

    switch msgType {
    case 0:  // request
        guard piece >= 0 else { return nil }
        return .request(piece: piece)
    case 1:  // data
        guard piece >= 0 else { return nil }
        let totalSize: Int = {
            guard let p = dict.first(where: { $0.0 == "total_size" }),
                  case .integer(let v) = p.1 else { return 0 }
            return Int(v)
        }()
        let payload = raw.count > range.upperBound
            ? raw.subdata(in: range.upperBound..<raw.count)
            : Data()
        return .data(piece: piece, totalSize: totalSize, payload: payload)
    case 2:  // reject
        guard piece >= 0 else { return nil }
        return .reject(piece: piece)
    default:
        return nil
    }
}
