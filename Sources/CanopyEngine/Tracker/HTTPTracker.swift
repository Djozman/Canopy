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
        request.setValue("Canopy/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackerError.noResponse
        }

        if httpResponse.statusCode >= 400 {
            throw TrackerError.httpError(httpResponse.statusCode)
        }

        return try parseResponse(data)
    }

    /// Announce to all tracker URLs in order until one succeeds.
    /// - Parameter urls: Tracker URLs in priority order.
    /// Each URL is retried up to 3 times with exponential backoff for transient errors.
    ///
    /// NOTE: This flattens BEP 12 tiered `announce-list` into a single sequence.
    /// A proper implementation would shuffle URLs within each tier, try them
    /// sequentially until one succeeds (promoting it), and only move to the
    /// next tier if the entire current tier fails. Private trackers depend on
    /// this behavior. The flat fallback is correct for public trackers.
    public static func announceWithFailover(
        to urls: [String],
        with params: TrackerAnnounce
    ) async throws -> TrackerResponse {
        guard !urls.isEmpty else { throw TrackerError.noResponse }

        var lastError: Error = TrackerError.noResponse

        for url in urls {
            do {
                return try await announceWithRetry(to: url, with: params, attempts: 3)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Announce to a single URL with retry logic for transient failures.
    private static func announceWithRetry(to url: String, with params: TrackerAnnounce,
                                          attempts: Int) async throws -> TrackerResponse {
        var lastError: Error = TrackerError.noResponse
        for attempt in 0..<attempts {
            do {
                return try await announce(to: url, with: params)
            } catch let error as TrackerError {
                lastError = error
                // Don't retry on client errors (4xx) or parse failures
                if case .httpError(let code) = error, (400...499).contains(code) {
                    throw error
                }
                if case .invalidURL = error { throw error }
            } catch let error as URLError {
                lastError = error
                // Only retry on transient network errors
                switch error.code {
                case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                     .dnsLookupFailed, .cannotFindHost:
                    break  // retryable
                default:
                    throw error
                }
            } catch {
                throw error
            }
            if attempt < attempts - 1 {
                let delay = Double(1 << attempt)  // 1s, 2s, 4s
                try? await Task.sleep(for: .seconds(delay))
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

    /// Parse peers from both compact (6-byte IPv4, 18-byte IPv6) and non-compact formats.
    static func parsePeers(from dict: [(String, BencodeValue)]) throws -> [Peer] {
        var peers: [Peer] = []

        // Try compact IPv4 format first (preferred)
        if let p = dict.first(where: { $0.0 == "peers" }),
           case .string(let compactData) = p.1 {
            peers.append(contentsOf: parseCompactPeers(compactData))
        }

        // Try compact IPv6 format (BEP 7)
        if let p = dict.first(where: { $0.0 == "peers6" }),
           case .string(let compactData) = p.1 {
            peers.append(contentsOf: parseCompactPeers6(compactData))
        }

        // Try non-compact (list of dicts)
        if let p = dict.first(where: { $0.0 == "peers" }),
           case .list(let peerList) = p.1 {
            peers.append(contentsOf: try parsePlainPeers(peerList))
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
