import Foundation
import Network

protocol PeerStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> Data
    func cancel()
}

final class PlainStream: PeerStream {
    let conn: NWConnection

    init(_ conn: NWConnection) { self.conn = conn }

    func send(_ data: Data) async throws { try await conn.send(content: data) }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> Data {
        try await conn.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength)
    }

    func cancel() { conn.cancel() }
}
