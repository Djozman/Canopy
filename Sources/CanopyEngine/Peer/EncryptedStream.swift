import Foundation
import Network

final class EncryptedStream: PeerStream, @unchecked Sendable {
    let conn: NWConnection
    private let encryptCipher: RC4
    private let decryptCipher: RC4

    init(conn: NWConnection, encryptCipher: RC4, decryptCipher: RC4) {
        self.conn = conn
        self.encryptCipher = encryptCipher
        self.decryptCipher = decryptCipher
    }

    func send(_ data: Data) async throws {
        try await conn.send(content: encryptCipher.process(data))
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> Data {
        let raw = try await conn.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength)
        return decryptCipher.process(raw)
    }

    func cancel() { conn.cancel() }
}
