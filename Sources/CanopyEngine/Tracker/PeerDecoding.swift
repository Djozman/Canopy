import Foundation

/// Parse compact peer format (IPv4): 6 bytes per peer (4 IP + 2 port, network byte order).
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

/// Parse compact peer format (IPv6, BEP 7): 18 bytes per peer (16 IP + 2 port, network byte order).
public func parseCompactPeers6(_ data: Data) -> [Peer] {
    guard data.count % 18 == 0 else { return [] }
    let bytes = Array(data)
    var peers: [Peer] = []
    var offset = 0
    while offset + 18 <= bytes.count {
        let groups = stride(from: offset, to: offset + 16, by: 2).map { i in
            String(format: "%x", (UInt16(bytes[i]) << 8) | UInt16(bytes[i+1]))
        }
        guard let ip = IPv6.compressed(groups) else { offset += 18; continue }
        let port = (UInt16(bytes[offset+16]) << 8) | UInt16(bytes[offset+17])
        peers.append(Peer(ip: ip, port: port))
        offset += 18
    }
    return peers
}

/// Simple IPv6 address formatter — compresses longest run of zero groups.
private enum IPv6 {
    static func compressed(_ groups: [String]) -> String? {
        guard groups.count == 8 else { return nil }
        var longestStart = -1, longestLen = 0
        var currentStart = -1, currentLen = 0
        for (i, g) in groups.enumerated() {
            if g == "0" {
                if currentStart < 0 { currentStart = i }
                currentLen += 1
            } else {
                if currentLen > longestLen { longestStart = currentStart; longestLen = currentLen }
                currentStart = -1; currentLen = 0
            }
        }
        if currentLen > longestLen { longestStart = currentStart; longestLen = currentLen }
        if longestLen > 1 {
            let before = groups[0..<longestStart]
            let after = groups[(longestStart + longestLen)...]
            let parts = before + [""] + after
            return parts.joined(separator: ":")
        }
        return groups.joined(separator: ":")
    }
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
