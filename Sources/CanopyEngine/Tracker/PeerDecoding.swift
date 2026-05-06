import Foundation

/// Parse compact peer format: 6 bytes per peer (4 IP + 2 port, network byte order).
public func parseCompactPeers(_ data: Data) -> [Peer] {
    guard data.count % 6 == 0 else { return [] }
    let bytes = Array(data)
    var peers: [Peer] = []
    var offset = 0
    while offset + 6 <= bytes.count {
        let ip = "\(bytes[offset]).\(bytes[offset+1]).\(bytes[offset+2]).\(bytes[offset+3])"
        let port = (UInt16(bytes[offset+4]) << 8) | UInt16(bytes[offset+5])
        peers.append(Peer(ip: ip, port: port))
        offset += 6
    }
    return peers
}

/// Encode a single peer in compact format: 4 IP + 2 port, network byte order.
public func encodeCompactPeer(_ peer: Peer) -> Data {
    let parts = peer.ip.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return Data() }
    var data = Data([parts[0], parts[1], parts[2], parts[3]])
    var port = peer.port.bigEndian
    data.append(Data(bytes: &port, count: 2))
    return data
}
