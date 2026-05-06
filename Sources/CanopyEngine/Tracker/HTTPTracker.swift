import Foundation

public enum TrackerError: Error {
    case invalidURL
    case httpError(Int)
    case noResponse
    case parseError(String)
}

/// Stateless HTTP tracker client. Announce, parse compact peer list, handle errors.
public struct HTTPTracker {

    /// Announce to a single tracker URL. Returns parsed response or throws.
    /// - Parameters:
    ///   - url: The full announce URL (without query params).
    ///   - announce: The announce parameters to encode.
    public static func announce(to url: String, with announce: TrackerAnnounce) async throws -> TrackerResponse {
        let fullURL: String
        if url.contains("?") {
            fullURL = "\(url)&\(announce.queryString())"
        } else {
            fullURL = "\(url)?\(announce.queryString())"
        }

        guard let requestURL = URL(string: fullURL) else {
            throw TrackerError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackerError.noResponse
        }

        if httpResponse.statusCode >= 400 {
            throw TrackerError.httpError(httpResponse.statusCode)
        }

        return try parseResponse(data)
    }

    /// Announce to all tracker URLs in order until one succeeds (tier failover).
    /// - Parameter urls: Tiered tracker URLs (flat list, already ordered by tier).
    public static func announceWithFailover(
        to urls: [String],
        with params: TrackerAnnounce
    ) async throws -> TrackerResponse {
        guard !urls.isEmpty else { throw TrackerError.noResponse }

        var lastError: Error = TrackerError.noResponse

        for url in urls {
            do {
                return try await announce(to: url, with: params)
            } catch {
                lastError = error
                // Try next tracker in the tier list
            }
        }

        throw lastError
    }

    // MARK: - Response parsing

    static func parseResponse(_ data: Data) throws -> TrackerResponse {
        let (value, _) = try BencodeDecoder.decode(data)
        guard case .dict(let dict) = value else {
            throw TrackerError.parseError("Expected bencode dictionary")
        }

        // Check for failure reason
        let failureReason: String? = {
            guard let p = dict.first(where: { $0.0 == "failure reason" }),
                  case .string(let d) = p.1 else { return nil }
            return String(data: d, encoding: .utf8)
        }()

        let warningMessage: String? = {
            guard let p = dict.first(where: { $0.0 == "warning message" }),
                  case .string(let d) = p.1 else { return nil }
            return String(data: d, encoding: .utf8)
        }()

        let interval: Int = {
            guard let p = dict.first(where: { $0.0 == "interval" }),
                  case .integer(let i) = p.1 else { return 1800 }
            return Int(i)
        }()

        let minInterval: Int? = {
            guard let p = dict.first(where: { $0.0 == "min interval" }),
                  case .integer(let i) = p.1 else { return nil }
            return Int(i)
        }()

        let trackerID: String? = {
            guard let p = dict.first(where: { $0.0 == "tracker id" }),
                  case .string(let d) = p.1 else { return nil }
            return String(data: d, encoding: .utf8)
        }()

        let complete: Int? = {
            guard let p = dict.first(where: { $0.0 == "complete" }),
                  case .integer(let i) = p.1 else { return nil }
            return Int(i)
        }()

        let incomplete: Int? = {
            guard let p = dict.first(where: { $0.0 == "incomplete" }),
                  case .integer(let i) = p.1 else { return nil }
            return Int(i)
        }()

        let peers: [Peer] = try parsePeers(from: dict)

        return TrackerResponse(
            failureReason: failureReason,
            warningMessage: warningMessage,
            interval: interval,
            minInterval: minInterval,
            trackerID: trackerID,
            complete: complete,
            incomplete: incomplete,
            peers: peers
        )
    }

    // MARK: - Peer list parsing

    /// Parse peers from both compact (6-byte) and non-compact (list-of-dicts) formats.
    static func parsePeers(from dict: [(String, BencodeValue)]) throws -> [Peer] {
        // Try compact format first (preferred)
        if let p = dict.first(where: { $0.0 == "peers" }),
           case .string(let compactData) = p.1 {
            return parseCompactPeers(compactData)
        }

        // Try non-compact (list of dicts)
        if let p = dict.first(where: { $0.0 == "peers" }),
           case .list(let peerList) = p.1 {
            return try parsePlainPeers(peerList)
        }

        return []
    }

    /// Parse compact peer format: 6 bytes per peer (4 IP + 2 port, network byte order).
    static func parseCompactPeers(_ data: Data) -> [Peer] {
        guard data.count % 6 == 0 else { return [] }
        var peers: [Peer] = []
        var offset = 0
        while offset + 6 <= data.count {
            let ipBytes = data[offset..<offset+4]
            let ip = ipBytes.map { String($0) }.joined(separator: ".")
            let portBytes = data[offset+4..<offset+6]
            let port = (UInt16(portBytes[0]) << 8) | UInt16(portBytes[1])
            peers.append(Peer(ip: ip, port: port))
            offset += 6
        }
        return peers
    }

    /// Parse non-compact peer list (list of dicts with "ip" and "port" keys).
    static func parsePlainPeers(_ list: [BencodeValue]) throws -> [Peer] {
        var peers: [Peer] = []
        for entry in list {
            guard case .dict(let pd) = entry else { continue }
            guard let ipP = pd.first(where: { $0.0 == "ip" }),
                  case .string(let ipData) = ipP.1,
                  let ip = String(data: ipData, encoding: .utf8) else { continue }
            guard let portP = pd.first(where: { $0.0 == "port" }),
                  case .integer(let port) = portP.1 else { continue }
            peers.append(Peer(ip: ip, port: UInt16(port)))
        }
        return peers
    }
}
