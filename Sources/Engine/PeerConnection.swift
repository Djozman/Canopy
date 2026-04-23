import Foundation
import Network

// BitTorrent peer wire protocol + BEP 10 extension protocol.
actor PeerConnection {
    enum State { case connecting, handshaking, active, closed }

    private let connection: NWConnection
    private(set) var state: State = .connecting
    private var receiveBuffer = Data()
    private var outboundBuffer = Data()
    private var isSending = false

    private(set) var peerChoking = true
    private(set) var peerInterested = false
    private(set) var amChoking = true     // we are choking the peer
    private(set) var amInterested = false
    private(set) var bitfield: [Bool] = []
    private var lastPEXSent: Date = .distantPast
    
    private(set) var downloadSpeed: Int64 = 0
    private var bytesDownloaded: Int64 = 0
    private(set) var uploadSpeed: Int64 = 0
    private var bytesUploaded: Int64 = 0
    private(set) var lastBlockReceivedTime: Date = .distantPast
    private(set) var lastMessageReceivedTime: Date = .now
    private var lastMessageSentTime: Date = .now
    private var lastSpeedSample: Date = .now

    // BEP 10 — extension IDs advertised by the remote peer
    private var extPEX: UInt8?      // ut_pex message id on remote
    private var extMetadata: UInt8? // ut_metadata message id on remote
    private var encryption: MSEncryption?

    weak var delegate: PeerDelegate?

    let host: String
    let port: UInt16
    private let infoHash: Data
    private let peerId: Data
    private let totalPieces: Int

    // BEP 10 local extension IDs (what we tell the remote to use)
    private static let localPEXId: UInt8 = 1
    private static let localMetadataId: UInt8 = 2

    init(host: String, port: UInt16, infoHash: Data, peerId: Data, totalPieces: Int) {
        self.host = host
        self.port = port
        self.infoHash = infoHash
        self.peerId = peerId
        self.totalPieces = totalPieces
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    init(incomingConnection: NWConnection, infoHash: Data, peerId: Data, totalPieces: Int) {
        self.connection = incomingConnection
        self.infoHash = infoHash
        self.peerId = peerId
        self.totalPieces = totalPieces
        if case .hostPort(let h, let p) = incomingConnection.endpoint {
            self.host = h.debugDescription
            self.port = p.rawValue
        } else {
            self.host = "unknown"
            self.port = 0
        }
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] s in
            Task { await self?.handleStateChange(s) }
        }
        connection.start(queue: .global(qos: .utility))
    }

    func acceptInbound(remoteSupportsExt: Bool) async {
        self.state = .active
        self.bitfield = Array(repeating: false, count: totalPieces)
        
        connection.stateUpdateHandler = { [weak self] s in
            if case .failed = s { Task { await self?.disconnect() } }
            if case .cancelled = s { Task { await self?.disconnect() } }
        }
        connection.start(queue: .global(qos: .utility))
        
        sendHandshake()
        sendExtensionHandshake()
        sendInterested()
        
        await delegate?.peerConnected(self, supportsExtensions: remoteSupportsExt)
        receiveLoop()
    }

    func disconnect() {
        connection.cancel()
        state = .closed
    }

    // MARK: - Outbound messages

    func sendInterested() {
        amInterested = true
        sendFrame(id: 2, payload: Data())
    }

    func sendUnchoke() {
        amChoking = false
        sendFrame(id: 1, payload: Data()) // unchoke
    }

    func sendChoke() {
        amChoking = true
        sendFrame(id: 0, payload: Data()) // choke
    }

    func requestBlock(piece: Int, offset: Int, length: Int) {
        var p = Data()
        p.appendUInt32(UInt32(piece))
        p.appendUInt32(UInt32(offset))
        p.appendUInt32(UInt32(length))
        sendFrame(id: 6, payload: p)
    }

    // Send multiple request messages in a single write — one actor hop, one TCP send.
    func requestBlocks(_ requests: [(piece: Int, offset: Int, length: Int)]) {
        guard !requests.isEmpty else { return }
        var combined = Data(capacity: requests.count * 17)
        for r in requests {
            var p = Data(capacity: 12)
            p.appendUInt32(UInt32(r.piece))
            p.appendUInt32(UInt32(r.offset))
            p.appendUInt32(UInt32(r.length))
            combined.appendUInt32(13)   // length: 1 (id) + 12 (payload)
            combined.append(6)          // request id
            combined.append(p)
        }
        let data = encryption?.encrypt(combined) ?? combined
        outboundBuffer.append(data)
        drainOutbound()
    }

    func sendPiece(index: Int, begin: Int, block: Data) {
        var p = Data()
        p.appendUInt32(UInt32(index))
        p.appendUInt32(UInt32(begin))
        p.append(block)
        sendFrame(id: 7, payload: p)
    }
    
    func updateStats() {
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastSpeedSample)
        if elapsed >= 1 {
            downloadSpeed = Int64(Double(bytesDownloaded) / elapsed)
            uploadSpeed = Int64(Double(bytesUploaded) / elapsed)
            bytesDownloaded = 0
            bytesUploaded = 0
            lastSpeedSample = now
        }
    }
    
    func recordUploaded(bytes: Int64) {
        bytesUploaded += bytes
    }

    func sendHave(piece: Int) {
        var p = Data()
        p.appendUInt32(UInt32(piece))
        sendFrame(id: 4, payload: p)
    }

    func sendKeepAliveIfNeeded() {
        let now = Date.now
        if now.timeIntervalSince(lastMessageSentTime) >= 60 {
            // Keep-alive is just 4 bytes of zeroes (length 0)
            let keepAlive = Data([0, 0, 0, 0])
            let data = encryption?.encrypt(keepAlive) ?? keepAlive
            outboundBuffer.append(data)
            drainOutbound()
            lastMessageSentTime = now
        }
    }
    
    func sendCancel(piece: Int, offset: Int, length: Int) {
        var p = Data()
        p.appendUInt32(UInt32(piece))
        p.appendUInt32(UInt32(offset))
        p.appendUInt32(UInt32(length))
        sendFrame(id: 8, payload: p)
    }

    func sendBitfield(_ bits: [Bool]) {
        guard !bits.isEmpty else { return }
        var payload = Data(count: (bits.count + 7) / 8)
        for (i, has) in bits.enumerated() where has {
            payload[i / 8] |= (0x80 >> (i % 8))
        }
        sendFrame(id: 5, payload: payload)
    }

    // BEP 11 PEX — send peer list to remote
    func sendPEX(added: [(ip: String, port: UInt16)], dropped: [(ip: String, port: UInt16)] = []) {
        guard let extId = extPEX else { return }
        lastPEXSent = .now
        
        var addedData = Data()
        for peer in added.prefix(50) {
            guard let ip4 = parseIPv4(peer.ip) else { continue }
            addedData.append(contentsOf: ip4)
            addedData.appendUInt16(peer.port)
        }
        
        var droppedData = Data()
        for peer in dropped.prefix(50) {
            guard let ip4 = parseIPv4(peer.ip) else { continue }
            droppedData.append(contentsOf: ip4)
            droppedData.appendUInt16(peer.port)
        }

        var dictPairs: [(key: String, value: BValue)] = []
        if !addedData.isEmpty {
            dictPairs.append(("added", .bytes(addedData)))
            dictPairs.append(("added.f", .bytes(Data(repeating: 0x00, count: addedData.count / 6))))
        }
        if !droppedData.isEmpty {
            dictPairs.append(("dropped", .bytes(droppedData)))
        }
        
        guard !dictPairs.isEmpty else { return }
        
        let dict = BValue.dict(dictPairs)
        var payload = Data([extId])
        payload.append(Bencode.encode(dict))
        sendFrame(id: 20, payload: payload)
    }

    func sendMetadataRequest(piece: Int) {
        guard let extId = extMetadata else { return }
        let dict = BValue.dict([
            ("msg_type", .int(0)),
            ("piece", .int(piece))
        ])
        var payload = Data([extId])
        payload.append(Bencode.encode(dict))
        sendFrame(id: 20, payload: payload)
    }

    func sendMetadataPiece(piece: Int, totalSize: Int, data: Data) {
        guard let extId = extMetadata else { return }
        let dict = BValue.dict([
            ("msg_type", .int(1)),
            ("piece", .int(piece)),
            ("total_size", .int(totalSize))
        ])
        var payload = Data([extId])
        payload.append(Bencode.encode(dict))
        payload.append(data)
        sendFrame(id: 20, payload: payload)
    }

    // MARK: - Connection state

    private func handleStateChange(_ s: NWConnection.State) {
        switch s {
        case .ready:
            state = .handshaking
            sendHandshake()
            receiveLoop()
        case .failed, .cancelled:
            state = .closed
            Task { await delegate?.peerDidDisconnect(self) }
        default: break
        }
    }

    private func sendHandshake() {
        var hs = Data()
        hs.append(19)
        hs.append(contentsOf: "BitTorrent protocol".utf8)
        // Reserved bytes — advertise:
        //   bit 20 from right (byte[5] |= 0x10): BEP 10 extension protocol
        //   bit 0 from right  (byte[7] |= 0x01): DHT
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10  // BEP 10
        reserved[7] |= 0x01  // DHT
        reserved[7] |= 0x04  // BEP 6 Fast Extension
        hs.append(contentsOf: reserved)
        hs.append(infoHash)
        hs.append(peerId)
        
        let data = encryption?.encrypt(hs) ?? hs
        outboundBuffer.append(data)
        drainOutbound()
    }

    // Extension handshake — sent right after main handshake (BEP 10)
    private func sendExtensionHandshake() {
        let dict = BValue.dict([
            ("m", .dict([
                ("ut_pex", .int(Int(Self.localPEXId)))
            ])),
            ("p",    .int(6881)),
            ("reqq", .int(500)),
            ("v",    .bytes(Data("Canopy/1.0".utf8)))
        ])
        var payload = Data([0])  // extended message type 0 = handshake
        payload.append(Bencode.encode(dict))
        sendFrame(id: 20, payload: payload)
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, done, error in
            Task {
                guard let self else { return }
                if let data { await self.received(data) }
                if !done && error == nil { await self.receiveLoop() }
                else { await self.disconnect() }
            }
        }
    }

    private func received(_ data: Data) async {
        let decrypted = encryption?.decrypt(data) ?? data
        bytesDownloaded += Int64(decrypted.count)
        receiveBuffer.append(decrypted)
        switch state {
        case .handshaking: await tryParseHandshake()
        case .active:      await tryParseMessages()
        default: break
        }
    }

    // MARK: - Handshake parsing

    private func tryParseHandshake() async {
        guard receiveBuffer.count >= 68 else { return }
        let b = receiveBuffer.startIndex
        guard receiveBuffer[b] == 19,
              String(data: receiveBuffer[(b+1)..<(b+20)], encoding: .utf8) == "BitTorrent protocol",
              receiveBuffer[(b+28)..<(b+48)] == infoHash
        else { disconnect(); return }

        let remoteSupportsExt  = (receiveBuffer[b+25] & 0x10) != 0
        let remoteSupportsFast = (receiveBuffer[b+27] & 0x04) != 0

        receiveBuffer = Data(receiveBuffer.dropFirst(68))
        state = .active
        bitfield = Array(repeating: false, count: totalPieces)

        sendExtensionHandshake()
        sendInterested()

        // Send our bitfield if we have pieces
        await delegate?.peerConnected(self, supportsExtensions: remoteSupportsExt)
        await tryParseMessages()
    }

    // MARK: - Message parsing

    private func tryParseMessages() async {
        while receiveBuffer.count >= 4 {
            let len = receiveBuffer.readUInt32(at: 0)
            if len == 0 { 
                receiveBuffer = Data(receiveBuffer.dropFirst(4))
                lastMessageReceivedTime = .now
                continue 
            }
            guard receiveBuffer.count >= 4 + Int(len) else { return }
            let id      = receiveBuffer[receiveBuffer.startIndex + 4]
            let payload = Data(receiveBuffer[(receiveBuffer.startIndex + 5)..<(receiveBuffer.startIndex + 4 + Int(len))])
            receiveBuffer = Data(receiveBuffer.dropFirst(4 + Int(len)))
            lastMessageReceivedTime = .now
            await handleMessage(id: id, payload: payload)
        }
    }

    private func handleMessage(id: UInt8, payload: Data) async {
        switch id {
        case 0:  // choke
            peerChoking = true
            await delegate?.peerChokedUs(self)
        case 1:  // unchoke
            peerChoking = false
            await delegate?.peerUnchokedUs(self)
        case 2:  // interested
            peerInterested = true
            // Optimistically unchoke any interested peer
            if amChoking { sendUnchoke() }
        case 3:  // not interested
            peerInterested = false
        case 4:  // have
            guard payload.count == 4 else { return }
            let idx = Int(payload.readUInt32(at: 0))
            if idx < bitfield.count { bitfield[idx] = true }
            await delegate?.peerSentHave(self)
        case 5:  // bitfield
            for i in 0..<totalPieces {
                if i / 8 < payload.count {
                    bitfield[i] = (payload[i / 8] >> (7 - (i % 8))) & 1 == 1
                }
            }
            await delegate?.peerSentBitfield(self)
        case 6:  // request (peer wants a block from us)
            guard payload.count == 12 else { return }
            let index  = Int(payload.readUInt32(at: 0))
            let begin  = Int(payload.readUInt32(at: 4))
            let length = Int(payload.readUInt32(at: 8))
            await delegate?.peerRequestedBlock(self, piece: index, offset: begin, length: length)
        case 7:  // piece
            guard payload.count >= 8 else { return }
            let piece  = Int(payload.readUInt32(at: 0))
            let offset = Int(payload.readUInt32(at: 4))
            let block  = Data(payload.dropFirst(8))
            lastBlockReceivedTime = .now
            await delegate?.peerSentBlock(self, piece: piece, offset: offset, data: block)
        case 8:  // cancel
            guard payload.count == 12 else { return }
            // For now, we just ignore cancel if we already sent the block.
            // But we should stop pending reads if possible.
            break
        case 20: // extended (BEP 10)
            guard !payload.isEmpty else { return }
            await handleExtended(extId: payload[0], payload: Data(payload.dropFirst()))
        case 13: // suggest piece (BEP 6)
            break
        case 14: // have all (BEP 6)
            bitfield = Array(repeating: true, count: totalPieces)
        case 15: // have none (BEP 6)
            bitfield = Array(repeating: false, count: totalPieces)
        case 16: // reject request (BEP 6)
            break
        case 17: // allowed fast (BEP 6)
            break
        default: break
        }
    }

    private func handleExtended(extId: UInt8, payload: Data) async {
        guard let msg = try? Bencode.decode(payload) else { return }
        if extId == 0 {
            // Extension handshake
            if let m = msg["m"], case .dict(let pairs) = m {
                for (name, val) in pairs {
                    guard let id = val.int else { continue }
                    switch name {
                    case "ut_pex": extPEX = UInt8(id)
                    case "ut_metadata": extMetadata = UInt8(id)
                    default: break
                    }
                }
            }
        } else if extId == Self.localMetadataId {
            // BEP 9 Metadata message
            guard let dict = msg.dict else { return }
            let msgType = dict.first { $0.key == "msg_type" }?.value.int ?? -1
            let piece = dict.first { $0.key == "piece" }?.value.int ?? -1
            
            if msgType == 0 { // Request
                await delegate?.peerRequestedMetadata(self, piece: piece)
            } else if msgType == 1 { // Data
                let totalSize = dict.first { $0.key == "total_size" }?.value.int ?? 0
                // The data follows the bencoded dictionary.
                // We need to find the end of the dictionary in the payload.
                // For now, assume the dictionary is small and just drop the encoded size.
                let encoded = Bencode.encode(msg)
                let data = payload.dropFirst(encoded.count)
                await delegate?.peerSentMetadata(self, piece: piece, totalSize: totalSize, data: data)
            }
        } else if extId == Self.localPEXId {
            // PEX message — extract added peers
            var newPeers: [(String, UInt16)] = []
            if let added = msg["added"]?.data {
                var i = 0
                while i + 6 <= added.count {
                    let ip = "\(added[i]).\(added[i+1]).\(added[i+2]).\(added[i+3])"
                    let port = UInt16(added[i+4]) << 8 | UInt16(added[i+5])
                    newPeers.append((ip, port))
                    i += 6
                }
            }
            if !newPeers.isEmpty {
                await delegate?.peerSentPEX(self, peers: newPeers)
            }
        }
    }

    // MARK: - Helpers

    private func sendFrame(id: UInt8, payload: Data) {
        let len = UInt32(1 + payload.count)
        var frame = Data()
        frame.appendUInt32(len)
        frame.append(id)
        frame.append(payload)
        
        let data = encryption?.encrypt(frame) ?? frame
        outboundBuffer.append(data)
        drainOutbound()
        lastMessageSentTime = .now
    }

    private func drainOutbound() {
        guard !isSending, !outboundBuffer.isEmpty else { return }
        isSending = true
        
        let chunk = outboundBuffer.prefix(65536)
        outboundBuffer.removeFirst(chunk.count)
        
        connection.send(content: Data(chunk), completion: .contentProcessed({ [weak self] error in
            Task {
                guard let self else { return }
                await self.didSendChunk(error: error)
            }
        }))
    }

    private func didSendChunk(error: NWError?) {
        isSending = false
        if error == nil {
            drainOutbound()
        } else {
            disconnect()
        }
    }

    private func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}

// MARK: - Delegate

protocol PeerDelegate: AnyObject {
    func peerConnected(_ peer: PeerConnection, supportsExtensions: Bool) async
    func peerDidDisconnect(_ peer: PeerConnection) async
    func peerChokedUs(_ peer: PeerConnection) async
    func peerUnchokedUs(_ peer: PeerConnection) async
    func peerSentBitfield(_ peer: PeerConnection) async
    func peerSentHave(_ peer: PeerConnection) async
    func peerSentBlock(_ peer: PeerConnection, piece: Int, offset: Int, data: Data) async
    func peerRequestedBlock(_ peer: PeerConnection, piece: Int, offset: Int, length: Int) async
    func peerSentPEX(_ peer: PeerConnection, peers: [(String, UInt16)]) async
    func peerSentMetadata(_ peer: PeerConnection, piece: Int, totalSize: Int, data: Data) async
    func peerRequestedMetadata(_ peer: PeerConnection, piece: Int) async
}

// MARK: - Data helpers

