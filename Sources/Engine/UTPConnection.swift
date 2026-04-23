import Foundation
import Network

/// BEP 29 — uTP (Micro Transport Protocol).
/// UDP-based transport with LEDbat congestion control.
actor UTPConnection {
    enum State { case closed, synSent, connected }
    
    private let connection: NWConnection
    private var state: State = .closed
    private var receiveBuffer = Data()
    
    private var seqNr: UInt16 = UInt16.random(in: 0...65535)
    private var ackNr: UInt16 = 0
    private var connIdSend: UInt16
    private var connIdRecv: UInt16
    
    private var rtt: TimeInterval = 0.5
    private var rttVar: TimeInterval = 0.25
    
    weak var delegate: PeerDelegate?
    
    init(host: String, port: UInt16, infoHash: Data, peerId: Data) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        // uTP uses a random connection ID
        let baseId = UInt16.random(in: 0...65535)
        self.connIdRecv = baseId
        self.connIdSend = baseId + 1
        
        self.connection = NWConnection(to: endpoint, using: .udp)
    }
    
    func connect() {
        connection.stateUpdateHandler = { [weak self] s in
            if case .ready = s {
                Task { await self?.sendSyn() }
            }
        }
        connection.start(queue: .global())
        receiveLoop()
    }
    
    private func sendSyn() async {
        state = .synSent
        let packet = makePacket(type: 4, seq: seqNr, ack: 0, connId: connIdRecv)
        send(packet)
        seqNr = seqNr &+ 1
    }
    
    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task {
                guard let self, let data, error == nil else { return }
                await self.handlePacket(data)
                await self.receiveLoop()
            }
        }
    }
    
    private func handlePacket(_ data: Data) async {
        guard data.count >= 20 else { return }
        let typeVer = data[0]
        let type = typeVer >> 4
        _ = data.readUInt16(at: 2) // connId
        let seq = data.readUInt16(at: 16)
        _ = data.readUInt16(at: 18) // ack
        
        switch type {
        case 2: // ST_STATE (ACK)
            if state == .synSent {
                state = .connected
                // Trigger handshake over uTP
            }
        case 0: // ST_DATA
            ackNr = seq
            _ = data.dropFirst(20) // payload
            // Handle payload...
            sendAck()
        case 1: // ST_FIN
            state = .closed
        case 4: // ST_SYN
            // We don't handle incoming SYN yet in this client
            break
        default: break
        }
    }
    
    private func sendAck() {
        let packet = makePacket(type: 2, seq: seqNr, ack: ackNr, connId: connIdSend)
        send(packet)
    }
    
    private func send(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }
    
    private func makePacket(type: UInt8, seq: UInt16, ack: UInt16, connId: UInt16) -> Data {
        var d = Data()
        d.append((type << 4) | 1) // type + version 1
        d.append(0) // extension
        d.appendUInt16(connId)
        d.appendUInt32(0) // timestamp
        d.appendUInt32(0) // timestamp diff
        d.appendUInt32(1024 * 1024) // window size
        d.appendUInt16(seq)
        d.appendUInt16(ack)
        return d
    }
}
