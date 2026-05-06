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
    case empty
}

public struct TrackerAnnounce {
    public let infoHash: Data      // 20 bytes, raw
    public let peerID: Data        // 20 bytes
    public let port: UInt16
    public let uploaded: Int64
    public let downloaded: Int64
    public let left: Int64
    public let event: TrackerEvent
    public let compact: Bool

    public init(
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64,
        event: TrackerEvent = .started,
        compact: Bool = true
    ) {
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.uploaded = uploaded
        self.downloaded = downloaded
        self.left = left
        self.event = event
        self.compact = compact
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
            ("compact", compact ? "1" : "0"),
            ("event", event == .empty ? "" : event.rawValue),
        ]

        return params
            .filter { !$0.1.isEmpty }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }
}
