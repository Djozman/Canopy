import Foundation
import Network
import os

actor UDPTrackerClient {
    private let url: URL
    private var connectionId: UInt64?
    private var connectionTimestamp: Date?
    
    init(url: URL) {
        self.url = url
    }
    
    func announce(infoHash: Data, peerId: Data, port: UInt16, event: String = "") async throws -> [TrackerPeer] {
        guard let host = url.host, let portVal = url.port else { return [] }
        
        let connId = try await getConnectionId(host: host, port: UInt16(portVal))
        
        var packet = Data()
        packet.appendUInt64(connId)
        packet.appendUInt32(1) // Action: Announce
        let txId = UInt32.random(in: 0...UInt32.max)
        packet.appendUInt32(txId)
        packet.append(infoHash)
        packet.append(peerId)
        packet.appendUInt64(0) // Downloaded
        packet.appendUInt64(0) // Left
        packet.appendUInt64(0) // Uploaded
        
        let eventType: UInt32 = {
            switch event {
            case "started": return 2
            case "stopped": return 3
            case "completed": return 1
            default: return 0
            }
        }()
        packet.appendUInt32(eventType)
        packet.appendUInt32(0) // IP (0 = default)
        packet.appendUInt32(0) // Key
        packet.appendInt32(-1) // Num want (-1 = default)
        packet.appendUInt16(port)
        
        let response = try await sendAndReceive(packet, host: host, port: UInt16(portVal))
        
        guard response.count >= 20 else { return [] }
        let respAction = response.readUInt32(at: 0)
        let respTxId = response.readUInt32(at: 4)
        guard respAction == 1 && respTxId == txId else { return [] }
        
        var peers: [TrackerPeer] = []
        var offset = 20
        while offset + 6 <= response.count {
            let ip = "\(response[offset]).\(response[offset+1]).\(response[offset+2]).\(response[offset+3])"
            let p = response.readUInt16(at: offset + 4)
            peers.append(TrackerPeer(ip: ip, port: p))
            offset += 6
        }
        return peers
    }
    
    private func getConnectionId(host: String, port: UInt16) async throws -> UInt64 {
        if let id = connectionId, let ts = connectionTimestamp, Date().timeIntervalSince(ts) < 60 {
            return id
        }
        
        var packet = Data()
        packet.appendUInt64(0x41727101980) // Protocol ID
        packet.appendUInt32(0) // Action: Connect
        let txId = UInt32.random(in: 0...UInt32.max)
        packet.appendUInt32(txId)
        
        let response = try await sendAndReceive(packet, host: host, port: port)
        guard response.count >= 16 else { throw UDPTrackerError.noResponse }
        
        let respAction = response.readUInt32(at: 0)
        let respTxId = response.readUInt32(at: 4)
        guard respAction == 0 && respTxId == txId else { throw UDPTrackerError.noResponse }
        
        let id = response.readUInt64(at: 8)
        self.connectionId = id
        self.connectionTimestamp = Date()
        return id
    }
    
    private func sendAndReceive(_ data: Data, host: String, port: UInt16) async throws -> Data {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .udp)
        
        return try await withCheckedThrowingContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            
            @Sendable func resumeOnce(returning result: Result<Data, Error>) {
                let alreadyResumed = resumed.withLock { isResumed in
                    if isResumed { return true }
                    isResumed = true
                    return false
                }
                if !alreadyResumed {
                    cont.resume(with: result)
                    connection.cancel()
                }
            }

            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: data, completion: .contentProcessed({ error in
                        if let error = error {
                            resumeOnce(returning: .failure(error))
                        }
                    }))
                    
                    connection.receiveMessage { data, _, _, error in
                        if let data = data {
                            resumeOnce(returning: .success(data))
                        } else if let error = error {
                            resumeOnce(returning: .failure(error))
                        } else {
                            resumeOnce(returning: .failure(UDPTrackerError.noResponse))
                        }
                    }
                } else if case .failed(let e) = state {
                    resumeOnce(returning: .failure(e))
                }
            }
            connection.start(queue: .global())
            
            Task {
                try? await Task.sleep(for: .seconds(5))
                resumeOnce(returning: .failure(UDPTrackerError.noResponse))
            }
        }
    }
}

enum UDPTrackerError: Error {
    case noResponse
    case invalidResponse
}
