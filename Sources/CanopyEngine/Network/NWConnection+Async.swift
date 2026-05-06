import Foundation
import Network

extension NWConnection {
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
                else if isComplete { cont.resume(throwing: ConnectionError.disconnected) }
                else { cont.resume(throwing: ConnectionError.disconnected) }
            }
        }
    }
}

enum ConnectionError: Error {
    case disconnected
}
