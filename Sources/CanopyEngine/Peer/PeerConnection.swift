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
    public let peer: Peer
    private let infoHash: Data
    private let localPeerID: Data
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
    var peerExtensions: PeerExtensions?  // internal — read/written by DownloadCoordinator

    func setExtensions(_ ext: PeerExtensions) { self.peerExtensions = ext }

    public init(peer: Peer, infoHash: Data, localPeerID: Data) {
        self.peer = peer
        self.infoHash = infoHash
        self.localPeerID = localPeerID
    }

    /// Connect, perform handshake, return message stream.
    public func connect() async throws -> AsyncStream<PeerMessage> {
        let host = NWEndpoint.Host(peer.ip)
        let port = NWEndpoint.Port(integerLiteral: peer.port)
        let conn = NWConnection(host: host, port: port, using: .tcp)

        // Wait for connection or failure — only resume once
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let err): cont.resume(throwing: err)
                case .cancelled: cont.resume(throwing: PeerConnectionError.disconnected)
                default: return
                }
                conn.stateUpdateHandler = nil // Clear after terminal state
            }
            conn.start(queue: .global())
        }

        return try await handshake(on: conn)
    }

    /// Accept an already-established inbound connection, perform handshake, return stream.
    /// Inbound handshake order: receive theirs first, verify, then send ours.
    public func accept(connection conn: NWConnection) async throws -> AsyncStream<PeerMessage> {
        // Receive their handshake first
        var hsBuf = Data()
        while hsBuf.count < 68 {
            let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 68 - hsBuf.count)
            hsBuf.append(chunk)
        }
        guard let h = Handshake.decode(from: hsBuf) else {
            conn.cancel()
            print("[Peer] ❌ Invalid inbound handshake from \(peer)")
            throw PeerConnectionError.handshakeFailed("Invalid handshake")
        }
        guard h.infoHash == infoHash else {
            conn.cancel()
            print("[Peer] ❌ Info hash mismatch from inbound \(peer): got \(h.infoHash.hexString.prefix(16))")
            throw PeerConnectionError.handshakeFailed("Info hash mismatch")
        }
        self.peerReservedBytes = h.extensions
        // Now send our handshake
        let hs = Handshake(infoHash: infoHash, peerID: localPeerID, extensions: [0,0,0,0,0,0x10,0,0])
        try await conn.send(content: hs.encode())

        connection = conn
        handshakeDone = true
        return try await startMessageStream(on: conn)
    }

    private func handshake(on conn: NWConnection) async throws -> AsyncStream<PeerMessage> {
        let handshake = Handshake(infoHash: infoHash, peerID: localPeerID, extensions: [0,0,0,0,0,0x10,0,0])
        try await conn.send(content: handshake.encode())

        var hsBuf = Data()
        while hsBuf.count < 68 {
            let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 68 - hsBuf.count)
            hsBuf.append(chunk)
        }
        guard let h = Handshake.decode(from: hsBuf) else {
            conn.cancel()
            print("[Peer] ❌ Invalid handshake from \(peer)")
            throw PeerConnectionError.handshakeFailed("Invalid handshake")
        }
        guard h.infoHash == infoHash else {
            conn.cancel()
            print("[Peer] ❌ Info hash mismatch from \(peer): got \(h.infoHash.hexString.prefix(16))")
            throw PeerConnectionError.handshakeFailed("Info hash mismatch")
        }

        self.peerReservedBytes = h.extensions
        connection = conn
        handshakeDone = true

        return try await startMessageStream(on: conn)
    }

    private func startMessageStream(on conn: NWConnection) async throws -> AsyncStream<PeerMessage> {
        var messageContinuation: AsyncStream<PeerMessage>.Continuation?
        let stream = AsyncStream<PeerMessage> { cont in
            messageContinuation = cont
        }

        let cont = messageContinuation  // capture as let — no data race
        receiveTask = Task {
            var buf = Data()
            while !Task.isCancelled {
                guard let chunk = try? await conn.receive(minimumIncompleteLength: 1, maximumLength: 16384),
                      !chunk.isEmpty else { break }
                buf.append(chunk)
                while let msg = PeerMessage.decode(from: &buf) {
                    if case .choke = msg { await setChoked(true) }
                    if case .unchoke = msg { await setChoked(false) }
                    if case .interested = msg { await setInterested(true) }
                    if case .notInterested = msg { await setInterested(false) }
                    cont?.yield(msg)
                    if Task.isCancelled { break }
                }
            }
            cont?.finish()
        }

        return stream
    }

    private func setChoked(_ v: Bool) { isChoked = v }
    private func setInterested(_ v: Bool) { isPeerInterested = v }

    public func send(_ message: PeerMessage) async throws {
        guard let conn = connection else { throw PeerConnectionError.disconnected }
        try await conn.send(content: message.encode())
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
    }
}
