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
    private var buffer = Data()
    private var handshakeDone = false
    private var receiveTask: Task<Void, Never>?

    /// The peer's bitfield (nil until received).
    public private(set) var bitfield: Data?
    /// Whether the peer has choked us.
    public private(set) var isChoked = true
    /// Whether the peer is interested in us.
    public private(set) var isPeerInterested = false

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

        // Perform handshake — buffer across potential TCP fragmentation
        let handshake = Handshake(infoHash: infoHash, peerID: localPeerID, extensions: [0,0,0,0,0,0x10,0,0])
        try await conn.send(content: handshake.encode())

        var hsBuf = Data()
        while hsBuf.count < 68 {
            let chunk = try await conn.receive(minimumIncompleteLength: 1, maximumLength: 68 - hsBuf.count)
            hsBuf.append(chunk)
        }
        guard let h = Handshake.decode(from: hsBuf) else {
            conn.cancel()
            throw PeerConnectionError.handshakeFailed("Invalid handshake")
        }
        guard h.infoHash == infoHash else {
            conn.cancel()
            throw PeerConnectionError.handshakeFailed("Info hash mismatch")
        }

        connection = conn
        handshakeDone = true

        var messageContinuation: AsyncStream<PeerMessage>.Continuation?
        let stream = AsyncStream<PeerMessage> { cont in
            messageContinuation = cont
        }

        receiveTask = Task {
            var buf = Data()
            while !Task.isCancelled {
                guard let chunk = try? await conn.receive(minimumIncompleteLength: 1, maximumLength: 16384),
                      !chunk.isEmpty else { break }
                buf.append(chunk)
                while let msg = PeerMessage.decode(from: &buf) {
                    if case .bitfield(let bf) = msg { await setBitfield(bf) }
                    if case .choke = msg { await setChoked(true) }
                    if case .unchoke = msg { await setChoked(false) }
                    if case .interested = msg { await setInterested(true) }
                    if case .notInterested = msg { await setInterested(false) }
                    messageContinuation?.yield(msg)
                }
            }
            messageContinuation?.finish()
        }

        return stream
    }

    private func setBitfield(_ bf: Data) { bitfield = bf }
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

// MARK: - NWConnection send/receive helpers

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
                else if isComplete { cont.resume(throwing: PeerConnectionError.disconnected) }
                else { cont.resume(throwing: PeerConnectionError.disconnected) }
            }
        }
    }
}
