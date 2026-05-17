import Foundation

public struct Peer: Equatable {
    public let ip: String
    public let port: UInt16

    public init(ip: String, port: UInt16) {
        self.ip = ip
        self.port = port
    }
}

public enum TrackerEvent: String {
    case started
    case stopped
    case completed
    // No `.empty` case — use nil for periodic re-announce (event param omitted)
}

public struct TrackerAnnounce {
    public let infoHash: Data
    public let peerID: Data
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let event: TrackerEvent?  // nil = periodic re-announce (no event param)
    public let trackerID: String?     // echoed back from tracker response

    public init(
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64,
        event: TrackerEvent? = nil,
        trackerID: String? = nil
    ) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.event = event
        self.trackerID = trackerID
    }

    /// Per-torrent stable random key for tracker announces (NAT traversal).
    private func key() -> Data {
        // SHA1(peerID + infoHash) truncated to 4 bytes — stable across restarts
        let hash = SHA1.hash(peerID + infoHash)
        return hash.prefix(4)
    }

    /// Build the URL-encoded query string for an HTTP tracker announce.
    public func queryString() -> String {
        func percentEncode(_ data: Data) -> String {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            var result = ""
            for byte in data {
                if allowed.contains(UnicodeScalar(byte)) {
                    result.append(Character(UnicodeScalar(byte)))
                } else {
                    result.append(String(format: "%%%02X", byte))
                }
            }
            return result
        }

        let params: [(String, String)] = [
            ("info_hash", percentEncode(infoHash)),
            ("peer_id", percentEncode(peerID)),
            ("port", "\(port)"),
            ("uploaded", "\(uploaded)"),
            ("downloaded", "\(downloaded)"),
            ("left", "\(left)"),
            ("compact", "1"),
            ("numwant", event == .stopped ? "0" : "200"),
            ("event", event?.rawValue ?? ""),
            ("key", percentEncode(key())),
            ("supportcrypto", "1"),
            ("no_peer_id", "1"),
        ] + (trackerID.map { [("trackerid", $0)] } ?? [])

        return params
            .filter { !$0.1.isEmpty }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }
}
