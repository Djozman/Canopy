//  PeerConnection.swift
//  Canopy — Native Swift Engine
//
//  A single outbound TCP connection to a peer, speaking BEP 3:
//  handshake, then a never-ending stream of length-prefixed messages.
//  Transport is TCP via Network.framework.

import Foundation
import Network

actor PeerConnection {
    private(set) var amChoking = true
    private(set) var amInterested = false
    private(set) var peerChoking = true
    private(set) var peerInterested = false
    private(set) var remotePeerID: [UInt8]?

    private let infoHash: [UInt8]
    private let myPeerID: [UInt8]
    private let connection: NWConnection
    private var started = false
    private let maxMessageLength: UInt32 = 1 << 20

    private static let queue = DispatchQueue(
        label: "canopy.native.peer", qos: .userInitiated, attributes: .concurrent)

    init(host: String, port: UInt16, infoHash: [UInt8], myPeerID: [UInt8]) {
        precondition(infoHash.count == 20 && myPeerID.count == 20)
        self.infoHash = infoHash
        self.myPeerID = myPeerID
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        self.connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: params)
    }

    @discardableResult
    func connectAndHandshake(expectedPeerID: [UInt8]? = nil) async throws -> [UInt8] {
        try await startIfNeeded()
        let outgoing = PeerHandshake(infoHash: infoHash, peerID: myPeerID)
        try await sendRaw(outgoing.encode())
        let raw = try await receiveExactly(PeerHandshake.wireLength)
        guard let their = PeerHandshake(decoding: raw) else { throw PeerWireError.handshakeFailed }
        guard their.infoHash == infoHash else { throw PeerWireError.infoHashMismatch }
        if let expected = expectedPeerID, their.peerID != expected {
            throw PeerWireError.peerIDMismatch
        }
        remotePeerID = their.peerID
        return their.peerID
    }

    func receiveMessage() async throws -> PeerMessage {
        let prefix = try await receiveExactly(4)
        let length = prefix.readUInt32BE(at: 0)
        guard length <= maxMessageLength else { throw PeerWireError.messageTooLarge(length) }
        let body = length == 0 ? Data() : try await receiveExactly(Int(length))
        let message = try PeerMessage.decode(body: body)
        switch message {
        case .choke: peerChoking = true
        case .unchoke: peerChoking = false
        case .interested: peerInterested = true
        case .notInterested: peerInterested = false
        default: break
        }
        return message
    }

    func send(_ message: PeerMessage) async throws {
        switch message {
        case .choke: amChoking = true
        case .unchoke: amChoking = false
        case .interested: amInterested = true
        case .notInterested: amInterested = false
        default: break
        }
        try await sendRaw(message.encode())
    }

    func sendKeepAlive() async throws { try await sendRaw(PeerMessage.keepAlive.encode()) }
    func close() { connection.cancel() }

    private func startIfNeeded() async throws {
        guard !started else { return }
        started = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = self.connection
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let e):
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: e)
                case .cancelled:
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: PeerWireError.connectionClosed)
                default: break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let e = error { cont.resume(throwing: e) } else { cont.resume() }
                })
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                data, _, isComplete, error in
                if let e = error {
                    cont.resume(throwing: e)
                } else if let d = data, d.count == count {
                    cont.resume(returning: d)
                } else {
                    cont.resume(throwing: PeerWireError.connectionClosed)
                }
            }
        }
    }
}
