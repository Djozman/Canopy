import Foundation
import Network

// MARK: - Unified peer protocol (TCP via PeerConnection, uTP via UTPConnection)

protocol AnyPeer: AnyObject, Sendable {
    var host: String { get }
    var port: UInt16 { get }
    // BT state — actor-isolated; callers always await
    var peerChoking: Bool { get async }
    var peerInterested: Bool { get async }
    var amChoking: Bool { get async }
    var bitfield: [Bool] { get async }
    var extMetadata: UInt8? { get async }
    var downloadSpeed: Int64 { get async }
    var uploadSpeed: Int64 { get async }
    var lastBlockReceivedTime: Date { get async }
    var lastMessageReceivedTime: Date { get async }
    var lastHandshakeReceivedTime: Date { get async }
    var state: PeerConnection.PeerState { get async }
    var isClosed: Bool { get async }
    // Lifecycle
    func connect() async
    func disconnect() async
    func setDelegateInternal(_ d: PeerDelegate) async
    func sendKeepAliveIfNeeded() async
    // Outbound BT messages
    func sendBitfield(_ bits: [Bool]) async
    func sendHave(piece: Int) async
    func sendCancel(piece: Int, offset: Int, length: Int) async
    func sendPEX(added: [(String, UInt16)], dropped: [(String, UInt16)]) async
    func requestBlocks(_ requests: [(piece: Int, offset: Int, length: Int)]) async
    func updateStats() async
    func sendPiece(index: Int, begin: Int, block: Data) async
    func sendUnchoke() async
    func sendChoke() async
    func requestMetadataPiece(_ piece: Int) async
    func sendMetadataPiece(_ piece: Int, totalSize: Int, data: Data) async
}

// MARK: - PeerDelegate (transport-agnostic engine callbacks)

protocol PeerDelegate: AnyObject {
    func peerConnected(_ peer: any AnyPeer, supportsExtensions: Bool) async
    func peerDidDisconnect(_ peer: any AnyPeer) async
    func peerUnchokedUs(_ peer: any AnyPeer) async
    func peerSentBitfield(_ peer: any AnyPeer) async
    func peerSentHave(_ peer: any AnyPeer) async
    func peerSentBlock(_ peer: any AnyPeer, piece: Int, offset: Int, data: Data) async
    func peerRequestedBlock(_ peer: any AnyPeer, piece: Int, offset: Int, length: Int) async
    func peerSentPEX(_ peer: any AnyPeer, peers: [(String, UInt16)]) async
    func peerSentMetadata(_ peer: any AnyPeer, piece: Int, totalSize: Int, data: Data) async
    func peerRequestedMetadata(_ peer: any AnyPeer, piece: Int) async
    func peerRejectedMetadata(_ peer: any AnyPeer, piece: Int) async
    func peerSentExtHandshake(_ peer: any AnyPeer, metadataSize: Int) async
}

// MARK: - TCP peer connection

actor PeerConnection: @preconcurrency AnyPeer {
    enum PeerState: String { case connecting, handshaking, active, closed, mseHandshake }

    private let connection: NWConnection
    private(set) var state: PeerState = .connecting
    private var receiveBuffer = Data()

    // Write path state is accessed from two executors simultaneously:
    //   - actor methods called via @preconcurrency AnyPeer run on the *caller's* executor
    //   - NWConnection completion handlers run on their own thread
    // Actor isolation cannot protect these, so we use an explicit lock.
    private let sendLock = NSLock()
    nonisolated(unsafe) private var _writeBuffer = Data()
    nonisolated(unsafe) private var _isSending = false
    nonisolated(unsafe) private var _closed = false

    private(set) var peerChoking = true
    private(set) var peerInterested = false
    private(set) var amChoking = true
    private(set) var bitfield: [Bool] = []
    private var lastPEXSent: Date = .distantPast

    private(set) var downloadSpeed: Int64 = 0
    private(set) var uploadSpeed: Int64 = 0
    private var dlAccum: Int64 = 0
    private var ulAccum: Int64 = 0
    private var lastSpeedSample: Date = .now
    private(set) var lastBlockReceivedTime: Date = .now
    private(set) var lastMessageReceivedTime: Date = .now

    var isClosed: Bool { state == .closed }

    private(set) var lastHandshakeReceivedTime: Date = .distantPast
    private var extPEX: UInt8?
    private(set) var extMetadata: UInt8?
    private var encryption: MSEncryption?

    weak var delegate: PeerDelegate?
    func setDelegateInternal(_ d: PeerDelegate) { delegate = d }

    let host: String
    let port: UInt16
    private let infoHash: Data
    private let peerId: Data
    private let totalPieces: Int
    private let isPrivate: Bool
    private var mseDH: MSEDH?

    private static let localPEXId: UInt8 = 1
    private static let localMetadataId: UInt8 = 2

    init(host: String, port: UInt16, infoHash: Data, peerId: Data, totalPieces: Int, isPrivate: Bool) {
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
        self.isPrivate = isPrivate
    }

    init(incomingConnection: NWConnection, infoHash: Data, peerId: Data, totalPieces: Int, isPrivate: Bool) {
        self.infoHash = infoHash
        self.peerId = peerId
        self.totalPieces = totalPieces
        self.isPrivate = isPrivate
        connection = incomingConnection
        if case let .hostPort(h, p) = incomingConnection.endpoint {
            host = "\(h)"; port = p.rawValue
        } else {
            host = "unknown"; port = 0
        }
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] s in
            Task { await self?.handleStateChange(s) }
        }
        connection.start(queue: .global(qos: .utility))
    }

    func acceptInbound(remoteSupportsExt: Bool) async {
        state = .active
        bitfield = Array(repeating: false, count: totalPieces)
        sendExtensionHandshake()
        sendInterested()
        await delegate?.peerConnected(self, supportsExtensions: remoteSupportsExt)
        receiveLoop()
    }

    func disconnect() {
        sendLock.withLock {
            _closed = true
            _writeBuffer = Data()
            _isSending = false
        }
        connection.cancel()
        state = .closed
    }

    // MARK: - Write coalescing
    // nonisolated so it's safe to call from any executor without an actor hop.

    private func enqueueSend(_ data: Data) {
        let toSend = encryption?.encrypt(data) ?? data
        var shouldFlush = false
        sendLock.withLock {
            guard !_closed else { return }
            _writeBuffer.append(toSend)
            if !_isSending { _isSending = true; shouldFlush = true }
        }
        if shouldFlush { flushWriteBuffer() }
    }

    nonisolated private func flushWriteBuffer() {
        let chunk: Data? = sendLock.withLock {
            guard !_closed, !_writeBuffer.isEmpty else { _isSending = false; return nil }
            let c = _writeBuffer; _writeBuffer = Data(); return c
        }
        guard let chunk else { return }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] _ in
            self?.flushWriteBuffer()
        })
    }

    // MARK: - Outbound messages

    func sendInterested() {
        sendFrame(id: 2, payload: Data())
    }

    func sendUnchoke() {
        amChoking = false
        sendFrame(id: 1, payload: Data())
    }

    func sendChoke() {
        amChoking = true
        sendFrame(id: 0, payload: Data())
    }

    func requestBlocks(_ requests: [(piece: Int, offset: Int, length: Int)]) {
        guard !requests.isEmpty else { return }
        var combined = Data(capacity: requests.count * 17)
        for r in requests {
            var p = Data(capacity: 12)
            p.appendUInt32(UInt32(r.piece))
            p.appendUInt32(UInt32(r.offset))
            p.appendUInt32(UInt32(r.length))
            combined.appendUInt32(13)
            combined.append(6)
            combined.append(p)
        }
        let data = encryption?.encrypt(combined) ?? combined
        enqueueSend(data)
    }

    func sendPiece(index: Int, begin: Int, block: Data) {
        var p = Data()
        p.appendUInt32(UInt32(index))
        p.appendUInt32(UInt32(begin))
        p.append(block)
        ulAccum += Int64(block.count)
        sendFrame(id: 7, payload: p)
    }

    func updateStats() {
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastSpeedSample)
        guard elapsed >= 1 else { return }
        downloadSpeed = Int64(Double(dlAccum) / elapsed)
        uploadSpeed   = Int64(Double(ulAccum) / elapsed)
        dlAccum = 0; ulAccum = 0
        lastSpeedSample = now
    }

    func sendHave(piece: Int) {
        var p = Data(); p.appendUInt32(UInt32(piece))
        sendFrame(id: 4, payload: p)
    }

    func sendCancel(piece: Int, offset: Int, length: Int) {
        var p = Data()
        p.appendUInt32(UInt32(piece)); p.appendUInt32(UInt32(offset)); p.appendUInt32(UInt32(length))
        sendFrame(id: 8, payload: p)
    }

    func sendBitfield(_ bits: [Bool]) {
        guard !bits.isEmpty else { return }
        var payload = Data(count: (bits.count + 7) / 8)
        for (i, has) in bits.enumerated() where has { payload[i / 8] |= (0x80 >> (i % 8)) }
        sendFrame(id: 5, payload: payload)
    }

    func sendPEX(added: [(String, UInt16)], dropped: [(String, UInt16)]) {
        guard let extId = extPEX else { return }
        lastPEXSent = .now

        var addedData = Data()
        for (ip, pt) in added.prefix(50) {
            guard let ip4 = parseIPv4(ip) else { continue }
            addedData.append(contentsOf: ip4); addedData.appendUInt16(pt)
        }

        var droppedData = Data()
        for (ip, pt) in dropped.prefix(50) {
            guard let ip4 = parseIPv4(ip) else { continue }
            droppedData.append(contentsOf: ip4); droppedData.appendUInt16(pt)
        }

        var dictPairs: [(key: String, value: BValue)] = []
        if !addedData.isEmpty {
            dictPairs.append(("added",   .bytes(addedData)))
            dictPairs.append(("added.f", .bytes(Data(repeating: 0x00, count: addedData.count / 6))))
        }
        if !droppedData.isEmpty { dictPairs.append(("dropped", .bytes(droppedData))) }
        guard !dictPairs.isEmpty else { return }

        var payload = Data([extId])
        payload.append(Bencode.encode(BValue.dict(dictPairs)))
        sendFrame(id: 20, payload: payload)
    }

    // MARK: - Connection state

    func sendKeepAliveIfNeeded() {
        guard state == .active,
              Date.now.timeIntervalSince(lastMessageReceivedTime) > 100 else { return }
        // keepalive = 4-byte zero (length = 0)
        enqueueSend(Data([0, 0, 0, 0]))
    }

    private func handleStateChange(_ s: NWConnection.State) async {
        switch s {
        case .ready:
            await performMSEHandshake()
        case .failed, .cancelled:
            state = .closed
        default: break
        }
    }

    private func performMSEHandshake() async {
        // FORCED FALLBACK: Disable MSE for now to debug "0 handshaked" issue
        await self.switchToPlaintext()
        return;
        
        state = .mseHandshake
        let dh = MSEDH()
        self.mseDH = dh
        enqueueSend(dh.publicKeyData)
        
        // Wait for first byte to distinguish between MSE and Plaintext
        connection.receive(minimumIncompleteLength: 1, maximumLength: 96) { [weak self] data, _, _, error in
            Task {
                guard let self = self, let data = data, error == nil else {
                    await self?.disconnect(); return
                }
                
                if data[0] == 19 {
                    // Standard BitTorrent handshake received! Skip MSE.
                    self.receiveBuffer.append(data)
                    await self.switchToPlaintext()
                } else if data.count == 96 {
                    await self.completeMSEHandshake(remotePublicKey: data)
                } else {
                    // Partial data, wait for the rest of the 96 bytes
                    await self.waitForRemainingMSE(current: data)
                }
            }
        }
    }

    private func waitForRemainingMSE(current: Data) async {
        let remaining = 96 - current.count
        connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { [weak self] data, _, _, error in
            Task {
                guard let self = self, let data = data, error == nil else {
                    await self?.disconnect(); return
                }
                var full = current
                full.append(data)
                await self.completeMSEHandshake(remotePublicKey: full)
            }
        }
    }

    private func switchToPlaintext() {
        self.state = .handshaking
        self.sendBTHandshake()
        self.receiveLoop()
    }

    private func completeMSEHandshake(remotePublicKey: Data) async {
        guard let dh = mseDH else { return }
        let secret = dh.computeSharedSecret(remotePublicKeyData: remotePublicKey)
        self.encryption = MSEncryption(sharedSecret: secret, infoHash: infoHash)
        
        state = .handshaking
        sendBTHandshake()
        receiveLoop()
    }

    private func sendBTHandshake() {
        var hs = Data(capacity: 68)
        hs.append(19)
        hs.append(contentsOf: "BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10  // BEP 10
        reserved[7] |= 0x01  // DHT
        reserved[7] |= 0x04  // BEP 6 Fast Extension
        hs.append(contentsOf: reserved)
        hs.append(infoHash)
        hs.append(peerId)
        enqueueSend(hs)
    }

    private func sendExtensionHandshake() {
        var mDict: [(String, BValue)] = [
            ("ut_metadata", .int(Int(Self.localMetadataId)))
        ]
        
        if !isPrivate {
            mDict.append(("ut_pex", .int(Int(Self.localPEXId))))
        }
        
        let dict = BValue.dict([
            ("m", .dict(mDict)),
            ("p", .int(6881)),
            ("reqq", .int(500)),
            ("v", .bytes(Data("Canopy/1.0".utf8)))
        ])
        var payload = Data([0]) // msg ID 0 = handshake
        payload.append(Bencode.encode(dict))
        sendFrame(id: 20, payload: payload)
    }

    func requestMetadataPiece(_ piece: Int) {
        guard let extId = extMetadata else { return }
        let dict = BValue.dict([("msg_type", .int(0)), ("piece", .int(piece))])
        var payload = Data([extId]); payload.append(Bencode.encode(dict))
        sendFrame(id: 20, payload: payload)
    }

    func sendMetadataPiece(_ piece: Int, totalSize: Int, data: Data) {
        guard let extId = extMetadata else { return }
        let dict = BValue.dict([
            ("msg_type",   .int(1)),
            ("piece",      .int(piece)),
            ("total_size", .int(totalSize))
        ])
        var payload = Data([extId]); payload.append(Bencode.encode(dict)); payload.append(data)
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
        dlAccum += Int64(decrypted.count)
        lastMessageReceivedTime = .now
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
        let protocolString = Data("BitTorrent protocol".utf8)
        guard receiveBuffer[b] == 19,
              receiveBuffer[(b+1)..<(b+20)] == protocolString,
              receiveBuffer[(b+28)..<(b+48)] == infoHash
        else { 
            print("[Canopy] Handshake mismatch from \(host). Expected hash: \(infoHash.hexString)")
            disconnect(); return 
        }

        let remoteSupportsExt = (receiveBuffer[b+25] & 0x10) != 0

        receiveBuffer = Data(receiveBuffer.dropFirst(68))
        state = .active
        bitfield = Array(repeating: false, count: totalPieces)

        sendExtensionHandshake()
        sendInterested()
        await delegate?.peerConnected(self, supportsExtensions: remoteSupportsExt)
        await tryParseMessages()
    }

    // MARK: - Message parsing

    private func tryParseMessages() async {
        while receiveBuffer.count >= 4 {
            let len = receiveBuffer.readUInt32(at: 0)
            if len == 0 { receiveBuffer = Data(receiveBuffer.dropFirst(4)); continue }
            guard receiveBuffer.count >= 4 + Int(len) else { return }
            let id      = receiveBuffer[receiveBuffer.startIndex + 4]
            let payload = Data(receiveBuffer[(receiveBuffer.startIndex + 5)..<(receiveBuffer.startIndex + 4 + Int(len))])
            receiveBuffer = Data(receiveBuffer.dropFirst(4 + Int(len)))
            await handleMessage(id: id, payload: payload)
        }
    }

    private func handleMessage(id: UInt8, payload: Data) async {
        switch id {
        case 0:  peerChoking = true
        case 1:
            peerChoking = false
            await delegate?.peerUnchokedUs(self)
        case 2:
            peerInterested = true
            if amChoking { sendUnchoke() }
        case 3:  peerInterested = false
        case 4:
            guard payload.count == 4 else { return }
            let idx = Int(payload.readUInt32(at: 0))
            if idx < bitfield.count { bitfield[idx] = true }
            await delegate?.peerSentHave(self)
        case 5:
            for i in 0..<totalPieces {
                if i / 8 < payload.count {
                    bitfield[i] = (payload[i / 8] >> (7 - (i % 8))) & 1 == 1
                }
            }
            await delegate?.peerSentBitfield(self)
        case 6:
            guard payload.count == 12 else { return }
            await delegate?.peerRequestedBlock(self,
                piece:  Int(payload.readUInt32(at: 0)),
                offset: Int(payload.readUInt32(at: 4)),
                length: Int(payload.readUInt32(at: 8)))
        case 7:
            guard payload.count >= 8 else { return }
            lastBlockReceivedTime = .now
            lastMessageReceivedTime = .now
            await delegate?.peerSentBlock(self,
                piece:  Int(payload.readUInt32(at: 0)),
                offset: Int(payload.readUInt32(at: 4)),
                data:   Data(payload.dropFirst(8)))
        case 8:  break
        case 20:
            guard !payload.isEmpty else { return }
            await handleExtended(extId: payload[0], payload: Data(payload.dropFirst()))
        case 13: break
        case 14: bitfield = Array(repeating: true,  count: totalPieces)
        case 15: bitfield = Array(repeating: false, count: totalPieces)
        case 16: break
        case 17: break
        default: break
        }
    }

    private func handleExtended(extId: UInt8, payload: Data) async {
        guard let msg = try? Bencode.decode(payload) else { return }
        if extId == 0 {
            lastHandshakeReceivedTime = .now
            if let m = msg["m"], case .dict(let pairs) = m {
                for (name, val) in pairs {
                    guard let id = val.int else { continue }
                    switch name {
                    case "ut_pex":      extPEX      = UInt8(id)
                    case "ut_metadata":
                        extMetadata = UInt8(id)
                        requestMetadataPiece(0)
                    default: break
                    }
                }
            }
            if let size = msg["metadata_size"]?.int, size > 0 {
                await delegate?.peerSentExtHandshake(self, metadataSize: size)
            }
        } else if extId == Self.localMetadataId {
            guard let dict = msg.dict else { return }
            let msgType   = dict.first { $0.key == "msg_type"   }?.value.int ?? -1
            let piece     = dict.first { $0.key == "piece"      }?.value.int ?? -1
            let totalSize = dict.first { $0.key == "total_size" }?.value.int ?? 0
            if msgType == 0 {
                await delegate?.peerRequestedMetadata(self, piece: piece)
            } else if msgType == 1 {
                guard let res = try? Bencode.decodeWithOffset(payload) else { return }
                await delegate?.peerSentMetadata(self, piece: piece, totalSize: totalSize,
                                                 data: Data(payload.dropFirst(res.bytesConsumed)))
            } else if msgType == 2 {
                await delegate?.peerRejectedMetadata(self, piece: piece)
            }
        } else if extId == Self.localPEXId {
            var newPeers: [(String, UInt16)] = []
            if let added = msg["added"]?.data {
                var i = 0
                while i + 6 <= added.count {
                    let ip = "\(added[i]).\(added[i+1]).\(added[i+2]).\(added[i+3])"
                    let pt = UInt16(added[i+4]) << 8 | UInt16(added[i+5])
                    newPeers.append((ip, pt))
                    i += 6
                }
            }
            if !newPeers.isEmpty { await delegate?.peerSentPEX(self, peers: newPeers) }
        }
    }

    // MARK: - Helpers

    private func sendFrame(id: UInt8, payload: Data) {
        var frame = Data(capacity: 5 + payload.count)
        frame.appendUInt32(UInt32(1 + payload.count))
        frame.append(id)
        frame.append(payload)
        enqueueSend(encryption?.encrypt(frame) ?? frame)
    }

    private func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}
