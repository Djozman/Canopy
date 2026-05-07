import Foundation

// MARK: - Types

/// Decoded DHT response from a remote node.
public struct DHTResponse {
    public let nodes: [CompactNode]
    public let values: [Peer]
    public let token: Data?
}

/// Compact node info: 20-byte node ID + 4-byte IP + 2-byte port (26 bytes total, big-endian).
public struct CompactNode {
    public let nodeID: NodeID
    public let ip: String
    public let port: UInt16
}

// MARK: - Transaction ID

/// Encode a monotonic UInt16 counter as a 2-byte big-endian Data for bencode string use.
public func makeTransactionID(_ counter: UInt16) -> Data {
    Data([UInt8(counter >> 8), UInt8(counter & 0xFF)])
}

// MARK: - Compact node encoding (26 bytes)

public func encodeCompactNode(nodeID: NodeID, ip: String, port: UInt16) -> Data {
    let parts = ip.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return Data() }
    var data = Data(capacity: 26)
    data.append(nodeID.bytes)
    data.append(contentsOf: parts)
    data.append(writeUInt16(port))
    return data
}

public func decodeCompactNodes(_ data: Data) -> [CompactNode] {
    guard data.count % 26 == 0 else { return [] }
    let bytes = Array(data)
    var nodes: [CompactNode] = []
    var offset = 0
    while offset + 26 <= bytes.count {
        let nodeID = NodeID(bytes: Data(bytes[offset..<offset+20]))!
        let a = bytes[offset+20]; let b = bytes[offset+21]
        let c = bytes[offset+22]; let d = bytes[offset+23]
        let ip = "\(a).\(b).\(c).\(d)"
        let port = readUInt16(bytes, at: offset + 24)
        nodes.append(CompactNode(nodeID: nodeID, ip: ip, port: port))
        offset += 26
    }
    return nodes
}

// MARK: - Query builders

/// Build a bencoded DHT query message. Returns the raw bytes (no framing).
func buildQuery(txID: Data, queryType: String, args: [(String, BencodeValue)]) -> Data {
    let dict: BencodeValue = .dict([
        ("t", .string(txID)),
        ("y", .string(Data("q".utf8))),
        ("q", .string(Data(queryType.utf8))),
        ("a", .dict(args)),
    ])
    return BencodeEncoder.encode(dict)
}

public func buildPing(txID: Data, ourID: NodeID) -> Data {
    buildQuery(txID: txID, queryType: "ping", args: [
        ("id", .string(ourID.bytes)),
    ])
}

public func buildFindNode(txID: Data, ourID: NodeID, target: NodeID) -> Data {
    buildQuery(txID: txID, queryType: "find_node", args: [
        ("id", .string(ourID.bytes)),
        ("target", .string(target.bytes)),
    ])
}

public func buildGetPeers(txID: Data, ourID: NodeID, infoHash: Data) -> Data {
    buildQuery(txID: txID, queryType: "get_peers", args: [
        ("id", .string(ourID.bytes)),
        ("info_hash", .string(infoHash)),
    ])
}

public func buildAnnouncePeer(txID: Data, ourID: NodeID, infoHash: Data, port: UInt16, token: Data) -> Data {
    buildQuery(txID: txID, queryType: "announce_peer", args: [
        ("id", .string(ourID.bytes)),
        ("info_hash", .string(infoHash)),
        ("port", .integer(Int64(port))),
        ("token", .string(token)),
    ])
}

// MARK: - Response builder (outgoing)

public func buildResponse(txID: Data, ourID: NodeID, args: [(String, BencodeValue)]) -> Data {
    var allArgs = args
    allArgs.append(("id", .string(ourID.bytes)))
    let dict: BencodeValue = .dict([
        ("t", .string(txID)),
        ("y", .string(Data("r".utf8))),
        ("r", .dict(allArgs)),
    ])
    return BencodeEncoder.encode(dict)
}

public func buildError(txID: Data, code: Int, message: String) -> Data {
    let dict: BencodeValue = .dict([
        ("t", .string(txID)),
        ("y", .string(Data("e".utf8))),
        ("e", .list([.integer(Int64(code)), .string(Data(message.utf8))])),
    ])
    return BencodeEncoder.encode(dict)
}

// MARK: - Response parser (incoming)

public enum DHTMessageType {
    case query(t: Data, type: String, args: [String: BencodeValue])
    case response(t: Data, r: [String: BencodeValue], token: Data?)
    case error(t: Data, code: Int, message: String)
}

public func parseDHTMessage(_ data: Data) -> DHTMessageType? {
    guard let (value, _) = try? BencodeDecoder.decode(data),
          case .dict(let dict) = value else { return nil }

    // Read 't' field (transaction ID)
    let t: Data = {
        guard let p = dict.first(where: { $0.0 == "t" }),
              case .string(let d) = p.1 else { return Data() }
        return d
    }()

    // Read 'y' field (type)
    guard let yPair = dict.first(where: { $0.0 == "y" }),
          case .string(let yData) = yPair.1,
          let yStr = String(data: yData, encoding: .utf8) else { return nil }

    switch yStr {
    case "r":
        guard let rPair = dict.first(where: { $0.0 == "r" }),
              case .dict(let rDict) = rPair.1 else { return nil }
        let token: Data? = {
            guard let tp = rDict.first(where: { $0.0 == "token" }),
                  case .string(let d) = tp.1 else { return nil }
            return d
        }()
        return .response(t: t, r: Dictionary(rDict, uniquingKeysWith: { first, _ in first }), token: token)

    case "e":
        guard let ePair = dict.first(where: { $0.0 == "e" }),
              case .list(let eList) = ePair.1, eList.count >= 2,
              case .integer(let code) = eList[0],
              case .string(let msgData) = eList[1],
              let msg = String(data: msgData, encoding: .utf8) else { return nil }
        return .error(t: t, code: Int(code), message: msg)

    case "q":
        guard let qPair = dict.first(where: { $0.0 == "q" }),
              case .string(let qData) = qPair.1,
              let qType = String(data: qData, encoding: .utf8) else { return nil }
        let args: [String: BencodeValue] = {
            guard let aPair = dict.first(where: { $0.0 == "a" }),
                  case .dict(let aDict) = aPair.1 else { return [:] }
            return Dictionary(aDict, uniquingKeysWith: { first, _ in first })
        }()
        return .query(t: t, type: qType, args: args)

    default:
        return nil
    }
}

/// Extract DHTResponse fields from a response 'r' dict.
public func extractResponse(from r: [String: BencodeValue]) -> DHTResponse {
    let nodes: [CompactNode] = {
        guard let p = r.first(where: { $0.0 == "nodes" }),
              case .string(let data) = p.1 else { return [] }
        return decodeCompactNodes(data)
    }()
    let values: [Peer] = {
        guard let p = r.first(where: { $0.0 == "values" }),
              case .string(let data) = p.1 else { return [] }
        return parseCompactPeers(data)
    }()
    let token: Data? = {
        guard let p = r.first(where: { $0.0 == "token" }),
              case .string(let data) = p.1 else { return nil }
        return data
    }()
    return DHTResponse(nodes: nodes, values: values, token: token)
}

/// Helper: read 2-byte big-endian UInt16 from byte array.
private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}
