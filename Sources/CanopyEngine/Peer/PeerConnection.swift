import Foundation
import Network

public enum PeerConnectionError: Error {
    case connectionFailed
    case handshakeFailed(String)
    case timeout
    case disconnected
}

/// Single TCP connection to a peer, manages handshake + message stream.
public actor PeerConnection {
    public nonisolated let peer: Peer
    private let infoHash: Data
    private let localPeerID: Data
    private let encryption: EngineSettings.EncryptionMode
    private var stream: PeerStream?
    private var connection: NWConnection?
    private var handshakeDone = false
    private var receiveTask: Task<Void, Never>?

    /// Whether the peer has choked us.
    public private(set) var isChoked = true
    /// Whether the peer is interested in us.
    public private(set) var isPeerInterested = false
    /// The peer's reserved bytes from the handshake (for BEP 10 bit 20 check).
    public private(set) var peerReservedBytes: [UInt8] = []
    /// Parsed extension handshake from this peer (nil until received).
    var peerExtensions: PeerExtensions?

    func setExtensions(_ ext: PeerExtensions) { self.peerExtensions = ext }

    public init(peer: Peer, infoHash: Data, localPeerID: Data,
                encryption: EngineSettings.EncryptionMode = .preferred) {
        self.peer = peer
        self.infoHash = infoHash
        self.localPeerID = localPeerID
        self.encryption = encryption
    }

    // MARK: - Connect (outbound)

    public func connect() async throws -> AsyncStream<PeerMessage> {
        // Wrap the entire connect+handshake flow in a hard timeout. Without this,
        // a peer that accepts TCP but then stalls during the BT handshake byte
        // exchange can hold a connection slot indefinitely.
        try await withTimeout(seconds: 10) {
            try await self.doConnect()
        }
    }

    private func doConnect() async throws -> AsyncStream<PeerMessage> {
        if encryption == .required {
            let conn = try await openTCP()
            connection = conn
            let s = try await MSEHandshake.outbound(conn: conn, infoHash: infoHash)
            Log.peer.info("MSE encrypted session with \(self.peer.ip):\(self.peer.port)")
            stream = s
            return try await handshake(with: s)
        }

        if encryption == .preferred {
            // Try plaintext first — the vast majority of peers don't speak MSE.
            // Sending an MSE handshake to a plaintext peer causes them to close
            // the connection, wasting a full connect+handshake cycle. Plaintext-or-MSE
            // peers will respond correctly to a standard BT handshake.
            let conn = try await openTCP()
            connection = conn
            let s = PlainStream(conn)
            stream = s
            do {
                return try await handshake(with: s)
            } catch {
                conn.cancel()
            }

            // Plaintext failed — try MSE on a new connection for the minority
            // of peers that require encryption.
            let mseConn = try await openTCP()
            do {
                let es = try await MSEHandshake.outbound(conn: mseConn, infoHash: infoHash)
                Log.peer.info("MSE encrypted session with \(self.peer.ip):\(self.peer.port)")
                connection = mseConn
                stream = es
                return try await handshake(with: es)
            } catch {
                mseConn.cancel()
                throw error
            }
        }

        // .disabled: plaintext only
        let conn = try await openTCP()
        connection = conn
        let s = PlainStream(conn)
        stream = s
        return try await handshake(with: s)
    }

    private func openTCP() async throws -> NWConnection {
        let host = NWEndpoint.Host(peer.ip)
        let port = NWEndpoint.Port(integerLiteral: peer.port)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let conn = NWConnection(host: host, port: port, using: params)

        try await withTaskCancellationHandler {
            try await withTimeout(seconds: 5) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let resumed = AtomicFlag()
                    conn.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if resumed.testAndSet() { cont.resume() }
                        case .failed(let err):
                            if resumed.testAndSet() { cont.resume(throwing: err) }
                        case .cancelled:
                            if resumed.testAndSet() { cont.resume(throwing: PeerConnectionError.disconnected) }
                        default: return
                        }
                        conn.stateUpdateHandler = nil
                    }
                    conn.start(queue: .global())
                }
            }
        } onCancel: {
            conn.cancel()
        }

        return conn
    }

    // MARK: - Accept (inbound)

    public func accept(connection conn: NWConnection,
                       knownInfoHashes: Set<Data>) async throws -> AsyncStream<PeerMessage> {
        // Peek at first byte to detect MSE vs plaintext BT.
        // BT handshake starts with protocol length 19 (0x13).
        // MSE starts with a DH public key (random, highly unlikely to be 0x13).
        let firstByte = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 1)

        let s: PeerStream
        let iaBytes: Data?
        let isPlaintext = firstByte.first == 19

        if isPlaintext {
            if encryption == .required {
                conn.cancel()
                throw PeerConnectionError.handshakeFailed("Encryption required but peer sent plaintext")
            }
            s = PlainStream(conn)
            iaBytes = nil
            // Feed first byte into plaintext BT handshake
            return try await plaintextInboundHandshake(stream: s, firstByte: firstByte)
        } else {
            // MSE
            let (es, matchedIH, ia) = try await MSEHandshake.inbound(
                conn: conn, knownInfoHashes: knownInfoHashes, initialBytes: firstByte)
            guard matchedIH == infoHash else {
                es.cancel()
                throw PeerConnectionError.handshakeFailed("MSE info_hash mismatch")
            }
            s = es
            iaBytes = ia
            Log.peer.info("MSE encrypted inbound from \(self.peer.ip):\(self.peer.port)")
        }

        connection = conn
        stream = s
        return try await handshake(with: s, initialBytes: iaBytes)
    }

    // MARK: - BT handshakes

    private func handshake(with stream: PeerStream, initialBytes: Data? = nil) async throws -> AsyncStream<PeerMessage> {
        // Outbound: send ours first, then receive theirs
        let hs = Handshake(infoHash: infoHash, peerID: localPeerID, extensions: [0,0,0,0,0,0x10,0,0x04])
        try await stream.send(hs.encode())

        var hsBuf = initialBytes ?? Data()
        while hsBuf.count < 68 {
            let chunk = try await stream.receive(minimumIncompleteLength: 1, maximumLength: 68 - hsBuf.count)
            hsBuf.append(chunk)
        }
        // If initial bytes contain data beyond 68 bytes (from MSE vcMarker scan), trim
        // to just the BT handshake. The handshake is always 68 bytes.
        let handshakeBytes = hsBuf.prefix(68)
        guard let h = Handshake.decode(from: Data(handshakeBytes)) else {
            stream.cancel()
            throw PeerConnectionError.handshakeFailed("Invalid handshake")
        }
        guard h.infoHash == infoHash else {
            stream.cancel()
            throw PeerConnectionError.handshakeFailed("Info hash mismatch: got \(h.infoHash.hexString.prefix(16))")
        }

        self.peerReservedBytes = h.extensions
        handshakeDone = true
        return try await startMessageStream(on: stream)
    }

    /// Inbound plaintext BT handshake when we already have the first byte.
    private func plaintextInboundHandshake(stream: PeerStream,
                                           firstByte: Data) async throws -> AsyncStream<PeerMessage> {
        var hsBuf = firstByte
        while hsBuf.count < 68 {
            let chunk = try await stream.receive(minimumIncompleteLength: 1,
                                                  maximumLength: 68 - hsBuf.count)
            hsBuf.append(chunk)
        }
        guard let h = Handshake.decode(from: hsBuf) else {
            stream.cancel()
            throw PeerConnectionError.handshakeFailed("Invalid inbound handshake")
        }
        guard h.infoHash == infoHash else {
            stream.cancel()
            throw PeerConnectionError.handshakeFailed("Info hash mismatch from inbound: got \(h.infoHash.hexString.prefix(16))")
        }
        self.peerReservedBytes = h.extensions

        let hs = Handshake(infoHash: infoHash, peerID: localPeerID, extensions: [0,0,0,0,0,0x10,0,0x04])
        try await stream.send(hs.encode())

        handshakeDone = true
        return try await startMessageStream(on: stream)
    }

    // MARK: - Message stream

    private func startMessageStream(on stream: PeerStream) async throws -> AsyncStream<PeerMessage> {
        var messageContinuation: AsyncStream<PeerMessage>.Continuation?
        let msgStream = AsyncStream<PeerMessage> { cont in
            messageContinuation = cont
        }

        let cont = messageContinuation
        receiveTask = Task { [stream] in
            var buf = [UInt8]()
            var readOffset = 0
            while !Task.isCancelled {
                guard let chunk = try? await stream.receive(minimumIncompleteLength: 1,
                                                             maximumLength: 131072),
                      !chunk.isEmpty else { break }
                buf.append(contentsOf: chunk)
                while let msg = PeerMessage.decode(from: buf, readOffset: &readOffset) {
                    if case .choke = msg { setChoked(true) }
                    if case .unchoke = msg { setChoked(false) }
                    if case .interested = msg { setInterested(true) }
                    if case .notInterested = msg { setInterested(false) }
                    cont?.yield(msg)
                    if Task.isCancelled { break }
                }
                if readOffset > 65536 {
                    buf = Array(buf[readOffset...])
                    readOffset = 0
                }
            }
            cont?.finish()
        }

        return msgStream
    }

    // MARK: - Send / Disconnect

    public func send(_ message: PeerMessage) async throws {
        guard let s = stream else { throw PeerConnectionError.disconnected }
        try await s.send(message.encode())
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        stream?.cancel()
        stream = nil
        connection = nil
    }

    private func setChoked(_ v: Bool) { isChoked = v }
    private func setInterested(_ v: Bool) { isPeerInterested = v }
}

/// One-shot flag for guarding single-resume of CheckedContinuation.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
