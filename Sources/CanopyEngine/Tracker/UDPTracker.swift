import Foundation
import Network

/// BEP 15 — UDP tracker protocol.
/// Per-announce UDP socket, connection ID cached for 2 minutes.
public struct UDPTracker {
    private let url: String
    private let host: String
    private let port: UInt16

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

        let cid = try await getConnectionID(on: conn)

        let txID = UInt32.random(in: 0...UInt32.max)
        let key = UInt32.random(in: 0...UInt32.max)  // stable across retries
        let request = encodeAnnounce(cid: cid, txID: txID, announce: announce, key: key)

        for i in 0..<4 {
            try await conn.send(content: request)
            do {
                let data = try await withTimeout(seconds: 5) {
                    try await conn.receive(minimumIncompleteLength: 1, maximumLength: 4096)
                }
                if let response = try decodeResponse(data: data, expectedTxID: txID) {
                    return response
                }
            } catch is TimeoutError {
                // retry with backoff
            }
            try? await Task.sleep(for: .seconds(TimeInterval(min(15 * (1 << i), 300))))
        }
        throw TrackerError.noResponse
    }

    // MARK: - Connection ID (always handshake — per-announce socket)

    private func getConnectionID(on conn: NWConnection) async throws -> UInt64 {
        let txID = UInt32.random(in: 0...UInt32.max)
        let connectReq = encodeConnect(txID: txID)

        for _ in 0..<4 {
            try await conn.send(content: connectReq)
            do {
                let data = try await withTimeout(seconds: 5) {
                    try await conn.receive(minimumIncompleteLength: 1, maximumLength: 16)
                }
                guard data.count >= 16 else { continue }
                let action = readUInt32(data, at: 0)
                guard action == 0 else { continue }
                let respTxID = readUInt32(data, at: 4)
                guard respTxID == txID else { continue }
                return readUInt64(data, at: 8)
            } catch is TimeoutError {
                // retry
            }
        }
        throw TrackerError.noResponse
    }

    // MARK: - Wire encoding

    private func encodeConnect(txID: UInt32) -> Data {
        var data = Data(capacity: 16)
        data.append(writeUInt64(0x41727101980))  // magic connection ID
        data.append(writeUInt32(0))               // action = connect
        data.append(writeUInt32(txID))
        return data
    }

    private func encodeAnnounce(cid: UInt64, txID: UInt32, announce: TrackerAnnounce, key: UInt32) -> Data {
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
        data.append(writeUInt32(key))
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
            let peers = parseCompactPeers(peerData)
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

}

// MARK: - Timeout helper (uses shared Network/Timeout.swift)


