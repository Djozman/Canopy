import Foundation
import Network

/// BEP 15 — UDP tracker protocol.
/// Per-announce UDP socket, connection ID cached for 2 minutes.
public struct UDPTracker {
    private let url: String
    private let host: String
    private let port: UInt16

    private static var connectionIDCache: [String: (id: UInt64, expiry: Date)] = [:]

    public init(url: String) throws {
        self.url = url
        guard let parsed = URL(string: url),
              let host = parsed.host,
              let port = parsed.port else {
            throw TrackerError.invalidURL
        }
        self.host = host
        self.port = UInt16(port)
    }

    public func announce(with announce: TrackerAnnounce) async throws -> TrackerResponse {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port), using: .udp)
        conn.start(queue: .global())
        defer { conn.cancel() }

        // Get or fetch connection ID
        let cid = try await getConnectionID(on: conn)

        // Build announce request
        let txID = UInt32.random(in: 0...UInt32.max)
        let request = encodeAnnounce(cid: cid, txID: txID, announce: announce)
        try await conn.send(content: request)

        // Receive response with retries
        let response: TrackerResponse? = try await withRetries(maxRetries: 4) {
            let data = try await withTimeout(seconds: 5) {
                try await conn.receive(minimumIncompleteLength: 1, maximumLength: 4096)
            }
            return try decodeResponse(data: data, expectedTxID: txID)
        }
        guard let response = response else {
            throw TrackerError.noResponse
        }
        return response
    }

    // MARK: - Connection ID

    private func getConnectionID(on conn: NWConnection) async throws -> UInt64 {
        // Check cache
        let key = cacheKey
        if let entry = Self.connectionIDCache[key], Date() < entry.expiry {
            return entry.id
        }
        // Handshake
        let txID = UInt32.random(in: 0...UInt32.max)
        let connectReq = encodeConnect(txID: txID)
        try await conn.send(content: connectReq)

        var attempt = 0
        while attempt < 4 {
            let data: Data
            do {
                data = try await withTimeout(seconds: 5) {
                    try await conn.receive(minimumIncompleteLength: 1, maximumLength: 16)
                }
            } catch {
                attempt += 1
                continue
            }
            if data.count < 16 { attempt += 1; continue }
            // Verify it's a connect response
            let action = readUInt32(data, at: 0)
            guard action == 0 else { attempt += 1; continue }
            let respTxID = readUInt32(data, at: 4)
            guard respTxID == txID else { attempt += 1; continue }
            let cid = readUInt64(data, at: 8)
            // Cache for 2 minutes
            Self.connectionIDCache[key] = (cid, Date().addingTimeInterval(120))
            return cid
        }
        throw TrackerError.noResponse
    }

    private var cacheKey: String { "\(host):\(port)" }

    // MARK: - Wire encoding

    private func encodeConnect(txID: UInt32) -> Data {
        var data = Data(capacity: 16)
        data.append(writeUInt64(0x41727101980))  // magic connection ID
        data.append(writeUInt32(0))               // action = connect
        data.append(writeUInt32(txID))
        return data
    }

    private func encodeAnnounce(cid: UInt64, txID: UInt32, announce: TrackerAnnounce) -> Data {
        var data = Data(capacity: 98)
        data.append(writeUInt64(cid))
        data.append(writeUInt32(1))               // action = announce
        data.append(writeUInt32(txID))
        data.append(announce.infoHash)
        data.append(announce.peerID)
        data.append(writeInt64(announce.downloaded))
        data.append(writeInt64(announce.left))
        data.append(writeInt64(announce.uploaded))
        let event: UInt32 = {
            switch announce.event {
            case .completed: return 1
            case .started:   return 2
            case .stopped:   return 3
            case nil:        return 0
            }
        }()
        data.append(writeUInt32(event))
        data.append(writeUInt32(0))               // ip = 0 (use sender's)
        data.append(writeUInt32(UInt32.random(in: 0...UInt32.max))) // key
        data.append(writeInt32(-1))               // num_want = -1
        data.append(writeUInt16(announce.port))
        return data
    }

    // MARK: - Response decoding

    private func decodeResponse(data: Data, expectedTxID: UInt32) throws -> TrackerResponse? {
        guard data.count >= 8 else { return nil }
        let action = readUInt32(data, at: 0)
        let txID = readUInt32(data, at: 4)
        guard txID == expectedTxID else { return nil }  // stale response

        switch action {
        case 1:  // announce response
            guard data.count >= 20 else { return nil }
            let interval = Int(readUInt32(data, at: 8))
            let leechers = Int(readUInt32(data, at: 12))
            let seeders = Int(readUInt32(data, at: 16))
            let peerData = data.count > 20 ? data.subdata(in: 20..<data.count) : Data()
            let peers = HTTPTracker.parseCompactPeers(peerData)
            return TrackerResponse(
                interval: interval,
                complete: seeders,
                incomplete: leechers,
                peers: peers
            )
        case 3:  // error
            let message = data.count > 8 ? String(data: data.subdata(in: 8..<data.count), encoding: .utf8) ?? "unknown error" : "unknown error"
            return TrackerResponse(failureReason: message)
        default:
            return nil  // unknown, retry
        }
    }

    // MARK: - Big-endian helpers

    private func writeUInt64(_ v: UInt64) -> Data {
        var val = v.bigEndian
        return Data(bytes: &val, count: 8)
    }
    private func writeUInt32(_ v: UInt32) -> Data {
        var val = v.bigEndian
        return Data(bytes: &val, count: 4)
    }
    private func writeUInt16(_ v: UInt16) -> Data {
        var val = v.bigEndian
        return Data(bytes: &val, count: 2)
    }
    private func writeInt64(_ v: Int64) -> Data {
        var val = UInt64(bitPattern: v).bigEndian
        return Data(bytes: &val, count: 8)
    }
    private func writeInt32(_ v: Int32) -> Data {
        var val = UInt32(bitPattern: v).bigEndian
        return Data(bytes: &val, count: 4)
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let b = Array(data.subdata(in: offset..<min(offset + 8, data.count)))
        var result: UInt64 = 0
        for byte in b.prefix(8) { result = (result << 8) | UInt64(byte) }
        return result
    }
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b = Array(data.subdata(in: offset..<min(offset + 4, data.count)))
        var result: UInt32 = 0
        for byte in b.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }
}

// MARK: - Retry helper

private func withRetries<T>(maxRetries: Int, op: () async throws -> T?) async throws -> T? {
    for i in 0..<maxRetries {
        if let result = try? await op() {
            return result
        }
        let delay = UInt64(min(15 * (1 << i), 300))
        try? await Task.sleep(for: .seconds(delay))
    }
    return nil
}

private func withTimeout<T>(seconds: TimeInterval, op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}

// MARK: - NWConnection async helpers

private extension NWConnection {
    func send(content: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.send(content: content, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed({ error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume() }
            }))
        }
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: TrackerError.noResponse) }
                else { cont.resume(throwing: TrackerError.noResponse) }
            }
        }
    }
}
