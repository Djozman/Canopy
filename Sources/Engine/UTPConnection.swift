import Foundation
import Network

// BEP 29 — uTP (Micro Transport Protocol) over UDP with BitTorrent wire protocol on top.
// Optimizations vs baseline:
//  • LEDBAT cwnd congestion control (target 25ms queuing delay)
//  • Send queue drains on every ACK as window opens
//  • Out-of-order receive buffering (oobBuffer) — no data dropped on reorder
//  • RFC 6298 SRTT/RTTVAR → accurate RTO instead of fixed 1 s
//  • Triple duplicate-ACK fast retransmit + cwnd halving
//  • Nagle coalescing: small BT frames batched into MTU-sized datagrams (5 ms flush)
//  • 1 MiB advertised receive window (was 64 KiB)
//  • Retransmit poll tightened to 200 ms (was 500 ms)
actor UTPConnection: @preconcurrency AnyPeer {

    // MARK: - AnyPeer identity
    let host: String
    let port: UInt16

    // MARK: - AnyPeer BT state
    private(set) var peerChoking: Bool = true
    private(set) var peerInterested: Bool = false
    private(set) var amChoking: Bool = true
    private(set) var bitfield: [Bool] = []
    private(set) var downloadSpeed: Int64 = 0
    private(set) var uploadSpeed: Int64 = 0
    private(set) var lastBlockReceivedTime: Date = .now
    private(set) var lastMessageReceivedTime: Date = .now
    var isClosed: Bool { utpState == .closed }

    weak var delegate: PeerDelegate?
    func setDelegateInternal(_ d: PeerDelegate) { delegate = d }

    // MARK: - uTP state machine
    private enum UTPState { case idle, synSent, connected, closing, closed }
    private var utpState: UTPState = .idle
    
    var state: PeerConnection.PeerState {
        switch utpState {
        case .idle, .synSent: return .connecting
        case .connected:     return .active
        case .closing, .closed: return .closed
        }
    }

    // BEP 29 §2.2 — connection IDs
    private let connIdRecv: UInt16
    private let connIdSend: UInt16

    // Sequence / ACK numbers (wrapping uint16)
    private var seqNr: UInt16 = 1
    private var ackNr: UInt16 = 0   // highest in-order seq received from remote

    // MARK: - Reliability

    private struct InFlight { let data: Data; let sentAt: Date; var retries: Int }
    private var inFlight: [UInt16: InFlight] = [:]
    private var inFlightBytes: Int = 0          // total bytes outstanding
    private var retransmitTask: Task<Void, Never>?

    // RFC 6298 RTT estimator
    private var srtt: Double = 0        // smoothed RTT (seconds); 0 = not yet measured
    private var rttvar: Double = 0.75   // RTT variance
    private var rto: TimeInterval = 1.0

    // Duplicate ACK tracking for fast retransmit
    private var lastAckedSeq: UInt16 = 0
    private var dupAckCount: Int = 0

    // MARK: - Congestion / flow control (LEDBAT)

    private static let targetDelay: UInt32 = 25_000     // 25 ms in µs
    private static let maxPayload      = 1_350           // MTU-safe payload bytes
    private static let minCwnd         = maxPayload      // floor

    private var cwnd: Int = 4 * maxPayload              // congestion window (bytes)
    private var remoteWindow: UInt32 = 65_536           // remote's advertised window
    private var baseDelay: UInt32 = .max                // minimum observed one-way delay
    private var windowSize: UInt32 = 1_048_576          // our advertised recv window (1 MiB)

    // Send queue: data waiting for the congestion window to open
    private var sendQueue = Data()

    // MARK: - Out-of-order receive buffer
    private var oobBuffer: [UInt16: Data] = [:]

    // MARK: - Nagle coalescing
    private var nagleBuffer = Data()
    private var nagleTask: Task<Void, Never>?

    // MARK: - BitTorrent layer
    private var wireBuffer = Data()
    private var btHandshakeDone = false
    private var extPEX: UInt8?
    private(set) var extMetadata: UInt8?
    private(set) var lastHandshakeReceivedTime: Date = .distantPast

    // Speed accumulators (raw UDP payload bytes)
    private var dlAccum: Int64 = 0
    private var ulAccum: Int64 = 0
    private var lastSpeedSample: Date = .now

    // MARK: - Identity / config
    private(set) var infoHash: Data
    private(set) var peerId: Data
    private(set) var totalPieces: Int
    private(set) var isPrivate: Bool
    private static let localPEXId: UInt8 = 1
    private static let localMetadataId: UInt8 = 2

    private let connection: NWConnection
    nonisolated(unsafe) var onInboundHandshake: (@Sendable (Data, Bool) async -> Bool)?

    // MARK: - Init

    init(host: String, port: UInt16, infoHash: Data, peerId: Data, totalPieces: Int, isPrivate: Bool) {
        self.host = host
        self.port = port
        self.infoHash = infoHash
        self.peerId = peerId
        self.totalPieces = totalPieces
        self.isPrivate = isPrivate
        self.onInboundHandshake = nil

        let baseId = UInt16.random(in: 1...65534)
        connIdRecv = baseId
        connIdSend = baseId &+ 1

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        connection = NWConnection(to: endpoint, using: .udp)
    }

    init(incomingConnection: NWConnection) {
        self.infoHash = Data()
        self.peerId = Data()
        self.totalPieces = 0
        self.isPrivate = false
        self.onInboundHandshake = nil
        self.connection = incomingConnection
        if case let .hostPort(h, p) = incomingConnection.endpoint {
            self.host = "\(h)"; self.port = p.rawValue
        } else {
            self.host = "unknown"; self.port = 0
        }
        
        let baseId = UInt16.random(in: 1...65534)
        self.connIdRecv = baseId
        self.connIdSend = baseId &+ 1
    }

    func bindInbound(infoHash: Data, peerId: Data, totalPieces: Int, isPrivate: Bool) {
        self.infoHash = infoHash
        self.peerId = peerId
        self.totalPieces = totalPieces
        self.isPrivate = isPrivate
    }

    func acceptInbound(remoteSupportsExt: Bool) async {
        utpState = .connected
        bitfield = Array(repeating: false, count: totalPieces)
        if remoteSupportsExt { sendExtHandshake() }
        sendBTFrame(id: 2, payload: Data()) // INTERESTED
    }

    // MARK: - AnyPeer lifecycle

    func connect() {
        connection.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:             Task { await self?.sendSyn() }
            case .failed, .cancelled: Task { await self?.teardown() }
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        receiveLoop()
    }

    func disconnect() { Task { await teardown() } }

    private func teardown() async {
        guard utpState != .closed else { return }
        utpState = .closed
        retransmitTask?.cancel()
        nagleTask?.cancel()
        connection.cancel()
        await delegate?.peerDidDisconnect(self)
    }

    // MARK: - uTP transport

    private func sendSyn() {
        utpState = .synSent
        seqNr = UInt16.random(in: 1...65535)
        let pkt = makeHeader(type: 4, seq: seqNr, ack: 0, connId: connIdRecv)
        inFlight[seqNr] = InFlight(data: pkt, sentAt: .now, retries: 0)
        inFlightBytes += pkt.count
        seqNr = seqNr &+ 1
        sendRaw(pkt)
        startRetransmit()
    }

    private func sendStateAck() {
        sendRaw(makeHeader(type: 2, seq: seqNr, ack: ackNr, connId: connIdSend))
    }

    // Appends payload to the send queue, then drains as much as the window allows.
    private func sendData(_ payload: Data) {
        guard utpState == .connected else { return }
        sendQueue.append(payload)
        drainSendQueue()
    }

    // Sends ST_DATA packets until the congestion/flow window is exhausted.
    private func drainSendQueue() {
        let window = min(Int(remoteWindow), cwnd)
        while !sendQueue.isEmpty && inFlightBytes < window {
            let available = window - inFlightBytes
            let chunkSize = min(Self.maxPayload, min(sendQueue.count, available))
            guard chunkSize > 0 else { break }
            let chunk = Data(sendQueue.prefix(chunkSize))
            sendQueue = Data(sendQueue.dropFirst(chunkSize))

            let seq = seqNr; seqNr = seqNr &+ 1
            var pkt = makeHeader(type: 0, seq: seq, ack: ackNr, connId: connIdSend)
            pkt.append(contentsOf: chunk)
            inFlight[seq] = InFlight(data: pkt, sentAt: .now, retries: 0)
            inFlightBytes += pkt.count
            sendRaw(pkt)
        }
    }

    private func makeHeader(type: UInt8, seq: UInt16, ack: UInt16, connId: UInt16) -> Data {
        var d = Data(capacity: 20)
        d.append((type << 4) | 1)
        d.append(0)
        d.appendUInt16(connId)
        d.appendUInt32(microTimestamp())
        d.appendUInt32(0)               // timestamp_diff (remote fills this)
        d.appendUInt32(windowSize)
        d.appendUInt16(seq)
        d.appendUInt16(ack)
        return d
    }

    private func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func microTimestamp() -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task {
                guard let self else { return }
                if let data { await self.handlePacket(data) }
                if error == nil { await self.receiveLoop() }
                else            { await self.teardown() }
            }
        }
    }

    private func handlePacket(_ rawData: Data) async {
        guard rawData.count >= 20 else { return }

        let type   = rawData[0] >> 4
        let pktTs  = rawData.readUInt32(at: 4)
        let pktWnd = rawData.readUInt32(at: 12)
        let seq    = rawData.readUInt16(at: 16)
        let ack    = rawData.readUInt16(at: 18)

        remoteWindow = pktWnd
        lastMessageReceivedTime = .now

        // LEDBAT: track minimum one-way delay as baseline
        let nowTs = microTimestamp()
        let delay = nowTs &- pktTs
        baseDelay = (baseDelay == .max) ? delay : min(baseDelay, delay)

        // Process cumulative ACK, collect bytes newly acked
        let ackedBytes = ackInFlight(upTo: ack)

        if ackedBytes > 0 {
            // Forward progress — update congestion window and drain queued sends
            updateLedbat(ackedBytes: ackedBytes, delay: delay)
            lastAckedSeq = ack
            dupAckCount = 0
            drainSendQueue()
        } else {
            // Possible duplicate ACK — count towards fast retransmit
            if ack == lastAckedSeq {
                dupAckCount += 1
                if dupAckCount >= 3 { fastRetransmit(afterAck: ack) }
            } else {
                lastAckedSeq = ack
                dupAckCount = 1
            }
        }

        switch type {
        case 4: // ST_SYN — inbound; outbound-only for v1.1
            break

        case 2: // ST_STATE — ACK to our SYN, or pure ACK
            if utpState == .synSent {
                utpState = .connected
                ackNr = seq
                sendBTHandshake()
            }

        case 0: // ST_DATA — payload packet
            let payload = Data(rawData.dropFirst(20))
            guard !payload.isEmpty else { sendStateAck(); break }
            dlAccum += Int64(payload.count)

            let expected = ackNr &+ 1
            let diff = Int16(bitPattern: seq &- expected)

            if diff == 0 {
                // In-order: deliver immediately, then pull any buffered successors
                ackNr = seq
                wireBuffer.append(payload)
                drainOOB()
                sendStateAck()
                await processBTBuffer()
            } else if diff > 0 {
                // Out-of-order: buffer for later delivery
                oobBuffer[seq] = payload
                sendStateAck()  // duplicate ACK signals the gap to sender
            }
            // diff < 0: duplicate/old packet — ignore

        case 1: // ST_FIN — remote closed gracefully
            ackNr = seq
            sendStateAck()
            await teardown()

        case 3: // ST_RESET — hard abort
            await teardown()

        default: break
        }
    }

    // Deliver buffered out-of-order packets that are now consecutive.
    private func drainOOB() {
        while let payload = oobBuffer.removeValue(forKey: ackNr &+ 1) {
            ackNr = ackNr &+ 1
            wireBuffer.append(payload)
        }
    }

    // MARK: - ACK processing and RTT measurement

    // Removes newly-ACKed in-flight entries; returns bytes freed. Applies Karn's algorithm.
    @discardableResult
    private func ackInFlight(upTo ack: UInt16) -> Int {
        var ackedBytes = 0
        var rttSample: TimeInterval? = nil

        inFlight = inFlight.filter { seq, entry in
            guard Int16(bitPattern: ack &- seq) >= 0 else { return true }
            // Karn: only use first-transmission packets for RTT (no retransmits)
            if entry.retries == 0 {
                rttSample = Date.now.timeIntervalSince(entry.sentAt)
            }
            ackedBytes += entry.data.count
            inFlightBytes -= entry.data.count
            return false
        }

        if let rtt = rttSample { updateRTO(rtt: rtt) }
        return ackedBytes
    }

    // RFC 6298 §2 — update SRTT, RTTVAR, and RTO from a new RTT sample.
    private func updateRTO(rtt: TimeInterval) {
        if srtt == 0 {
            srtt   = rtt
            rttvar = rtt / 2
        } else {
            rttvar = 0.75 * rttvar + 0.25 * abs(srtt - rtt)
            srtt   = 0.875 * srtt + 0.125 * rtt
        }
        rto = max(0.5, min(srtt + 4 * rttvar, 30))
    }

    // MARK: - LEDBAT congestion control (BEP 29 §3.4)

    private func updateLedbat(ackedBytes: Int, delay: UInt32) {
        let queuingDelay = delay > baseDelay ? delay - baseDelay : 0
        let target = Self.targetDelay
        // offTarget > 0 → below target → grow; < 0 → above target → shrink
        let offTarget = Double(target) - Double(queuingDelay)
        let gain = (offTarget / Double(target)) * Double(ackedBytes)
        let mss  = Double(Self.maxPayload)
        cwnd = max(Self.minCwnd, Int(Double(cwnd) + gain * mss / max(Double(cwnd), mss)))
        cwnd = min(cwnd, max(Self.minCwnd, Int(remoteWindow)))
    }

    // MARK: - Fast retransmit (3 duplicate ACKs)

    private func fastRetransmit(afterAck ack: UInt16) {
        let lostSeq = ack &+ 1
        guard let entry = inFlight[lostSeq] else { return }
        inFlight[lostSeq] = InFlight(data: entry.data, sentAt: .now, retries: entry.retries + 1)
        sendRaw(entry.data)
        cwnd = max(Self.minCwnd, cwnd / 2)
        dupAckCount = 0
    }

    // MARK: - Retransmission timer

    private func startRetransmit() {
        retransmitTask?.cancel()
        retransmitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await self?.retransmitTimedOut()
            }
        }
    }

    private func retransmitTimedOut() async {
        guard utpState != .closed else { return }
        let deadline = Date.now.addingTimeInterval(-rto)
        var anyTimedOut = false
        for (seq, entry) in inFlight where entry.sentAt <= deadline {
            if entry.retries >= 4 { await teardown(); return }
            inFlight[seq] = InFlight(data: entry.data, sentAt: .now, retries: entry.retries + 1)
            sendRaw(entry.data)
            anyTimedOut = true
        }
        if anyTimedOut {
            cwnd = max(Self.minCwnd, cwnd / 2)
            rto  = min(rto * 2, 30)
        }
    }

    // MARK: - BitTorrent handshake

    private func sendBTHandshake() {
        var hs = Data(capacity: 68)
        hs.append(19)
        hs.append(contentsOf: "BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] |= 0x10  // BEP 10 extension protocol
        reserved[7] |= 0x01  // DHT
        hs.append(contentsOf: reserved)
        hs.append(infoHash)
        hs.append(peerId)
        sendData(hs)
    }

    // MARK: - BitTorrent message reassembly

    private func processBTBuffer() async {
        if !btHandshakeDone {
            guard wireBuffer.count >= 68 else { return }
            let b = wireBuffer.startIndex
            guard wireBuffer[b] == 19,
                  String(data: wireBuffer[(b+1)..<(b+20)], encoding: .utf8) == "BitTorrent protocol"
            else { await teardown(); return }

            let remoteSupportsExt = (wireBuffer[b+25] & 0x10) != 0
            let remoteInfoHash = wireBuffer[(b+28)..<(b+48)]
            
            if let onInboundHandshake = onInboundHandshake {
                if !self.infoHash.isEmpty && self.infoHash != remoteInfoHash {
                    await teardown(); return
                }
                
                let bound = await onInboundHandshake(Data(remoteInfoHash), remoteSupportsExt)
                if !bound { await teardown(); return }
                
                // Once bound, send our handshake back
                sendBTHandshake()
            } else {
                guard wireBuffer[(b+28)..<(b+48)] == self.infoHash else { await teardown(); return }
            }
            wireBuffer = Data(wireBuffer.dropFirst(68))
            btHandshakeDone = true
            bitfield = Array(repeating: false, count: totalPieces)
            sendExtHandshake()
            sendBTFrame(id: 2, payload: Data())  // INTERESTED
            await delegate?.peerConnected(self, supportsExtensions: remoteSupportsExt)
        }

        while wireBuffer.count >= 4 {
            let len = wireBuffer.readUInt32(at: 0)
            if len == 0 { wireBuffer = Data(wireBuffer.dropFirst(4)); continue }
            guard wireBuffer.count >= 4 + Int(len) else { return }
            let msgId   = wireBuffer[wireBuffer.startIndex + 4]
            let payload = Data(wireBuffer[(wireBuffer.startIndex + 5)..<(wireBuffer.startIndex + 4 + Int(len))])
            wireBuffer  = Data(wireBuffer.dropFirst(4 + Int(len)))
            await handleBTMessage(id: msgId, payload: payload)
        }
    }

    private func handleBTMessage(id: UInt8, payload: Data) async {
        switch id {
        case 0: peerChoking = true
        case 1:
            peerChoking = false
            await delegate?.peerUnchokedUs(self)
        case 2:
            peerInterested = true
            if amChoking { sendUnchoke() }
        case 3: peerInterested = false
        case 4:
            guard payload.count == 4 else { return }
            let idx = Int(payload.readUInt32(at: 0))
            if idx < bitfield.count { bitfield[idx] = true }
            await delegate?.peerSentHave(self)
        case 5:
            for i in 0..<totalPieces where i/8 < payload.count {
                bitfield[i] = (payload[i/8] >> (7 - (i%8))) & 1 == 1
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
            await delegate?.peerSentBlock(self,
                piece:  Int(payload.readUInt32(at: 0)),
                offset: Int(payload.readUInt32(at: 4)),
                data:   Data(payload.dropFirst(8)))
        case 8: break
        case 14: bitfield = Array(repeating: true,  count: totalPieces)
        case 15: bitfield = Array(repeating: false, count: totalPieces)
        case 20:
            guard !payload.isEmpty else { return }
            await handleExtended(extId: payload[0], payload: Data(payload.dropFirst()))
        default: break
        }
    }

    // MARK: - Nagle coalescing

    // Small BT frames accumulate here; flushed when buffer fills an MTU or after 5 ms.
    private func enqueueBT(_ frame: Data) {
        nagleBuffer.append(frame)
        if nagleBuffer.count >= Self.maxPayload {
            flushNagle()
        } else if nagleTask == nil {
            nagleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(5))
                await self?.flushNagle()
            }
        }
    }

    private func flushNagle() {
        nagleTask?.cancel()
        nagleTask = nil
        guard !nagleBuffer.isEmpty else { return }
        let buf = nagleBuffer
        nagleBuffer = Data()
        sendData(buf)
    }

    // MARK: - AnyPeer outbound BT messages

    func sendBitfield(_ bits: [Bool]) {
        guard !bits.isEmpty else { return }
        var payload = Data(count: (bits.count + 7) / 8)
        for (i, has) in bits.enumerated() where has { payload[i/8] |= (0x80 >> (i%8)) }
        sendBTFrame(id: 5, payload: payload)
    }

    func sendHave(piece: Int) {
        var p = Data(); p.appendUInt32(UInt32(piece))
        sendBTFrame(id: 4, payload: p)
    }

    func sendCancel(piece: Int, offset: Int, length: Int) {
        var p = Data()
        p.appendUInt32(UInt32(piece)); p.appendUInt32(UInt32(offset)); p.appendUInt32(UInt32(length))
        sendBTFrame(id: 8, payload: p)
    }

    func requestBlocks(_ requests: [(piece: Int, offset: Int, length: Int)]) {
        // All request messages combined into one sendData call — single window debit
        var combined = Data(capacity: requests.count * 17)
        for r in requests {
            combined.appendUInt32(13); combined.append(6)
            combined.appendUInt32(UInt32(r.piece))
            combined.appendUInt32(UInt32(r.offset))
            combined.appendUInt32(UInt32(r.length))
        }
        sendData(combined)
    }

    func sendPiece(index: Int, begin: Int, block: Data) {
        var p = Data()
        p.appendUInt32(UInt32(index)); p.appendUInt32(UInt32(begin)); p.append(block)
        ulAccum += Int64(block.count)
        sendBTFrame(id: 7, payload: p)
    }

    func sendPEX(added: [(String, UInt16)], dropped: [(String, UInt16)]) {
        guard let extId = extPEX else { return }
        var addedData = Data()
        for (ip, pt) in added.prefix(50) {
            guard let ip4 = parseIPv4(ip) else { continue }
            addedData.append(contentsOf: ip4); addedData.appendUInt16(pt)
        }
        guard !addedData.isEmpty else { return }
        let dict = BValue.dict([
            ("added",   .bytes(addedData)),
            ("added.f", .bytes(Data(repeating: 0, count: addedData.count / 6)))
        ])
        var payload = Data([extId]); payload.append(Bencode.encode(dict))
        sendBTFrame(id: 20, payload: payload)
    }

    func sendUnchoke() { amChoking = false; sendBTFrame(id: 1, payload: Data()) }
    func sendChoke()   { amChoking = true;  sendBTFrame(id: 0, payload: Data()) }

    func sendKeepAliveIfNeeded() {
        guard utpState == .connected,
              Date.now.timeIntervalSince(lastMessageReceivedTime) > 100 else { return }
        flushNagle()
        sendData(Data([0, 0, 0, 0]))
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

    // MARK: - Private helpers

    // BT frames ≥ MTU bypass Nagle to avoid head-of-line delay (piece data).
    private func sendBTFrame(id: UInt8, payload: Data) {
        var frame = Data(capacity: 5 + payload.count)
        frame.appendUInt32(UInt32(1 + payload.count))
        frame.append(id)
        frame.append(payload)
        if frame.count > Self.maxPayload {
            flushNagle()
            sendData(frame)
        } else {
            enqueueBT(frame)
        }
    }

    private func sendExtHandshake() {
        var mDict: [(String, BValue)] = [
            ("ut_metadata", .int(Int(Self.localMetadataId)))
        ]
        if !isPrivate {
            mDict.append(("ut_pex", .int(Int(Self.localPEXId))))
        }
        let dict = BValue.dict([
            ("m", .dict(mDict)),
            ("p",    .int(6881)),
            ("reqq", .int(500)),
            ("v",    .bytes(Data("Canopy/1.0".utf8)))
        ])
        var payload = Data([0]); payload.append(Bencode.encode(dict))
        sendBTFrame(id: 20, payload: payload)
    }

    func requestMetadataPiece(_ piece: Int) {
        guard let extId = extMetadata else { return }
        let dict = BValue.dict([("msg_type", .int(0)), ("piece", .int(piece))])
        var payload = Data([extId]); payload.append(Bencode.encode(dict))
        sendBTFrame(id: 20, payload: payload)
    }

    func sendMetadataPiece(_ piece: Int, totalSize: Int, data: Data) {
        guard let extId = extMetadata else { return }
        let dict = BValue.dict([
            ("msg_type",   .int(1)),
            ("piece",      .int(piece)),
            ("total_size", .int(totalSize))
        ])
        var payload = Data([extId]); payload.append(Bencode.encode(dict)); payload.append(data)
        sendBTFrame(id: 20, payload: payload)
    }

    private func handleExtended(extId: UInt8, payload: Data) async {
        lastHandshakeReceivedTime = .now
        guard let msg = try? Bencode.decode(payload) else { return }
        if extId == 0 {
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
            guard let msgType = msg["msg_type"]?.int else { return }
            let piece     = msg["piece"]?.int ?? 0
            let totalSize = msg["total_size"]?.int ?? 0
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

    private func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }
}
