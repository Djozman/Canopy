import Foundation
import Network
import os

struct TrackerPeer {
    let ip: String
    let port: UInt16
}

struct TrackerResponse {
    let interval: Int
    let peers: [TrackerPeer]
}

struct TrackerScrape {
    let complete: Int
    let incomplete: Int
    let downloaded: Int
    /// Higher score = more useful tracker. Heavy weight on seeders.
    var quality: Int { complete * 2 + incomplete }
}

enum HTTPTrackerError: LocalizedError {
    case badURL, noResponse, trackerFailure(String)
    var errorDescription: String? {
        switch self {
        case .badURL: "Invalid tracker URL"
        case .noResponse: "No response from tracker"
        case .trackerFailure(let msg): "Tracker error: \(msg)"
        }
    }
}

final class TrackerClient {
    func announce(
        trackerURL: String,
        infoHash: Data,
        peerId: Data,
        port: UInt16,
        uploaded: Int64,
        downloaded: Int64,
        left: Int64,
        event: String? = nil
    ) async throws -> TrackerResponse {
        var qs = "info_hash=\(infoHash.urlEncoded)"
            + "&peer_id=\(peerId.urlEncoded)"
            + "&port=\(port)"
            + "&uploaded=\(uploaded)"
            + "&downloaded=\(downloaded)"
            + "&left=\(left)"
            + "&compact=1"
        if let event { qs += "&event=\(event)" }

        let separator = trackerURL.contains("?") ? "&" : "?"
        let fullURL = trackerURL + separator + qs
        guard let url = URL(string: fullURL) else { throw HTTPTrackerError.badURL }

        // Use NWConnection for raw HTTP so ATS doesn't apply.
        // ATS only governs URLSession/CFNetwork, not Network.framework.
        let body = try await rawHTTPGet(url)
        return try parseResponse(body)
    }

    /// BEP 48 — scrape returns swarm stats without joining the swarm. Used to rank
    /// trackers before the announce so the most-populated tracker is contacted first.
    func scrape(trackerURL: String, infoHash: Data) async throws -> TrackerScrape? {
        guard let scrapeURL = Self.scrapeURL(from: trackerURL) else { return nil }
        let qs = "info_hash=\(infoHash.urlEncoded)"
        let separator = scrapeURL.contains("?") ? "&" : "?"
        guard let url = URL(string: scrapeURL + separator + qs) else { return nil }
        let body = try await rawHTTPGet(url)
        let decoded = try Bencode.decode(body)
        guard let files = decoded["files"]?.dict, let entry = files.first?.value else {
            return nil
        }
        return TrackerScrape(
            complete:   entry["complete"]?.int   ?? 0,
            incomplete: entry["incomplete"]?.int ?? 0,
            downloaded: entry["downloaded"]?.int ?? 0)
    }

    /// Convention: replace the trailing `/announce` with `/scrape`.
    static func scrapeURL(from announceURL: String) -> String? {
        guard let range = announceURL.range(of: "/announce") else { return nil }
        return announceURL.replacingCharacters(in: range, with: "/scrape")
    }

    // MARK: - Raw HTTP via NWConnection (ATS-exempt)

    private func rawHTTPGet(_ url: URL) async throws -> Data {
        guard let host = url.host else { throw HTTPTrackerError.badURL }
        let isHTTPS = url.scheme == "https"
        let port = UInt16(url.port ?? (isHTTPS ? 443 : 80))
        let pathAndQuery = (url.path.isEmpty ? "/" : url.path)
            + (url.query.map { "?\($0)" } ?? "")
        let request = "GET \(pathAndQuery) HTTP/1.0\r\nHost: \(host)\r\nAccept: */*\r\nConnection: close\r\n\r\n"

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params: NWParameters = isHTTPS ? .tls : .tcp
        let conn = NWConnection(to: endpoint, using: params)

        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            let resumed = OSAllocatedUnfairLock(initialState: false)

            func finish(_ result: Result<Data, Error>) {
                let alreadyResumed = resumed.withLock { isResumed in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                if alreadyResumed { return }
                conn.cancel()
                continuation.resume(with: result)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(request.utf8), completion: .idempotent)
                    func recv() {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                            if let d = data { buffer.append(d) }
                            if let e = error { finish(.failure(e)); return }
                            if done {
                                // Strip HTTP response headers
                                let sep = Data("\r\n\r\n".utf8)
                                if let r = buffer.range(of: sep) {
                                    finish(.success(Data(buffer[r.upperBound...])))
                                } else {
                                    finish(.success(buffer))
                                }
                            } else { recv() }
                        }
                    }
                    recv()
                case .failed(let e): finish(.failure(e))
                case .cancelled:
                    let alreadyResumed = resumed.withLock { $0 }
                    if !alreadyResumed { finish(.failure(HTTPTrackerError.noResponse)) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
        }
    }

    // MARK: - Response parsing

    private func parseResponse(_ data: Data) throws -> TrackerResponse {
        let decoded = try Bencode.decode(data)

        if let failure = decoded["failure reason"]?.string {
            throw HTTPTrackerError.trackerFailure(failure)
        }

        let interval = decoded["interval"]?.int ?? 1800
        var peers: [TrackerPeer] = []

        if let compact = decoded["peers"]?.data {
            var i = 0
            while i + 6 <= compact.count {
                let ip = "\(compact[i]).\(compact[i+1]).\(compact[i+2]).\(compact[i+3])"
                let port = UInt16(compact[i+4]) << 8 | UInt16(compact[i+5])
                peers.append(TrackerPeer(ip: ip, port: port))
                i += 6
            }
        } else if let peerList = decoded["peers"]?.list {
            peers = peerList.compactMap { p in
                guard let ip = p["ip"]?.string, let port = p["port"]?.int else { return nil }
                return TrackerPeer(ip: ip, port: UInt16(port))
            }
        }

        // BEP 7 — compact IPv6 peers (18 bytes per peer: 16-byte addr + 2-byte port)
        if let compact6 = decoded["peers6"]?.data {
            var i = 0
            while i + 18 <= compact6.count {
                let addrBytes = compact6[(compact6.startIndex + i)..<(compact6.startIndex + i + 16)]
                let port = UInt16(compact6[compact6.startIndex + i + 16]) << 8
                         | UInt16(compact6[compact6.startIndex + i + 17])
                peers.append(TrackerPeer(ip: Self.formatIPv6(Data(addrBytes)), port: port))
                i += 18
            }
        }

        return TrackerResponse(interval: interval, peers: peers)
    }

    /// Format 16 raw bytes into a canonical IPv6 string. NWConnection accepts both
    /// IPv4 and IPv6 host strings, so the rest of the code path is unchanged.
    static func formatIPv6(_ bytes: Data) -> String {
        guard bytes.count == 16 else { return "" }
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) {
            let v = UInt16(bytes[bytes.startIndex + i]) << 8
                  | UInt16(bytes[bytes.startIndex + i + 1])
            groups.append(String(format: "%x", v))
        }
        return groups.joined(separator: ":")
    }
}

private extension Data {
    var urlEncoded: String {
        map { byte in
            let c = Character(UnicodeScalar(byte))
            if c.isLetter || c.isNumber || "-_.~".contains(c) { return String(c) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
