// HTTPTracker.swift — HTTP(S) tracker announce (BEP 3) with compact peers (BEP 23).
// Supports both compact (6-byte) and legacy list-of-dicts peer formats.

import Foundation

public struct Peer: Equatable, Hashable {
    public let ip: String
    public let port: UInt16
    public var endpoint: String { "\(ip):\(port)" }
}

public enum TrackerEvent: String { case started, stopped, completed }

public struct TrackerResponse {
    public let interval: Int
    public let minInterval: Int?
    public let seeders: Int?  // "complete"
    public let leechers: Int?  // "incomplete"
    public let peers: [Peer]
}

public enum TrackerError: Error, CustomStringConvertible {
    case unsupportedScheme(String)  // only http/https here; udp is BEP 15 (later)
    case http(Int)
    case failure(String)  // tracker "failure reason"
    case invalidResponse(String)
    public var description: String {
        switch self {
        case .unsupportedScheme(let s):
            return "unsupported tracker scheme '\(s)' (HTTP client only)"
        case .http(let c): return "tracker HTTP status \(c)"
        case .failure(let m): return "tracker failure: \(m)"
        case .invalidResponse(let m): return "invalid tracker response: \(m)"
        }
    }
}

public struct HTTPTrackerClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func announce(
        announceURL: String,
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        uploaded: Int64 = 0,
        downloaded: Int64 = 0,
        left: Int64,
        event: TrackerEvent? = nil,
        numWant: Int = 50,
        compact: Bool = true
    ) async throws -> TrackerResponse {
        guard let base = URL(string: announceURL),
            let scheme = base.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw TrackerError.unsupportedScheme(URL(string: announceURL)?.scheme ?? "?")
        }

        // Build the query manually: info_hash/peer_id are raw bytes that must be
        // percent-encoded byte-by-byte (URLComponents would mangle them).
        var pairs: [String] = []
        func add(_ k: String, _ v: String) { pairs.append("\(k)=\(v)") }
        add("info_hash", Self.percentEncode(infoHash))
        add("peer_id", Self.percentEncode(peerID))
        add("port", String(port))
        add("uploaded", String(uploaded))
        add("downloaded", String(downloaded))
        add("left", String(left))
        add("compact", compact ? "1" : "0")
        add("numwant", String(numWant))
        if let event { add("event", event.rawValue) }

        let sep = (base.query?.isEmpty == false) ? "&" : "?"
        guard let url = URL(string: announceURL + sep + pairs.joined(separator: "&")) else {
            throw TrackerError.invalidResponse("could not build announce URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Canopy/2.5.2", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TrackerError.http(http.statusCode)
        }
        return try Self.parse(data)
    }

    // MARK: - Response parsing

    static func parse(_ data: Data) throws -> TrackerResponse {
        guard case .dict(let dict) = try BencodeParser.decode(data) else {
            throw TrackerError.invalidResponse("not a bencoded dictionary")
        }
        if let reason = dict["failure reason"]?.stringValue { throw TrackerError.failure(reason) }

        let interval = Int(dict["interval"]?.intValue ?? 0)
        let minInterval = dict["min interval"]?.intValue.map(Int.init)
        let seeders = dict["complete"]?.intValue.map(Int.init)
        let leechers = dict["incomplete"]?.intValue.map(Int.init)

        var peers: [Peer] = []
        switch dict["peers"] {
        case .bytes(let packed):  // BEP 23 compact form
            peers = parseCompactPeers(packed)
        case .list(let list):  // BEP 3 legacy form
            for e in list {
                guard let ip = e["ip"]?.stringValue,
                    let p = e["port"]?.intValue, (1...65535).contains(p)
                else { continue }
                peers.append(Peer(ip: ip, port: UInt16(p)))
            }
        default:
            break
        }
        return TrackerResponse(
            interval: interval, minInterval: minInterval,
            seeders: seeders, leechers: leechers, peers: peers)
    }

    /// BEP 23: 6 bytes per peer — 4-byte IPv4 + 2-byte port, network byte order.
    static func parseCompactPeers(_ data: Data) -> [Peer] {
        let b = [UInt8](data)
        var peers: [Peer] = []
        var i = 0
        while i + 6 <= b.count {
            let ip = "\(b[i]).\(b[i+1]).\(b[i+2]).\(b[i+3])"
            let port = (UInt16(b[i + 4]) << 8) | UInt16(b[i + 5])
            peers.append(Peer(ip: ip, port: port))
            i += 6
        }
        return peers
    }

    /// Tracker convention: percent-encode every byte except A-Za-z0-9 and -_.~
    static func percentEncode(_ data: Data) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
        var out = ""
        out.reserveCapacity(data.count * 3)
        for byte in data {
            if safe.contains(byte) {
                out.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
