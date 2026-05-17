import Foundation

/// Collects and assembles 16KB metadata pieces (BEP 9).
/// Verifies SHA1 against the expected info hash.
public actor MetadataDownloader {
    private let infoHash: Data
    private var totalSize: Int? = nil
    private var pieces: [Int: Data] = [:]

    public init(infoHash: Data) {
        self.infoHash = infoHash
    }

    public var pieceCount: Int? {
        guard let totalSize else { return nil }
        return (totalSize + 16383) / 16384
    }

    public var isComplete: Bool {
        guard let count = pieceCount, count > 0 else { return false }
        return pieces.count == count
    }

    public var nextNeededPiece: Int? {
        guard let count = pieceCount else { return nil }
        for i in 0..<count {
            if pieces[i] == nil { return i }
        }
        return nil
    }

    /// Store a received metadata piece.
    public func receivePiece(index: Int, totalSize: Int, data: Data) {
        // First data response establishes totalSize
        if self.totalSize == nil {
            self.totalSize = totalSize
        }
        // Truncate oversized last piece
        guard let count = pieceCount else { return }
        let expectedSize = (index == count - 1)
            ? totalSize - (index * 16384)
            : 16384
        pieces[index] = data.prefix(expectedSize)
    }

    /// Assemble all pieces and verify SHA1 against infoHash.
    /// Returns the raw info dict bytes on success, nil on failure.
    /// On failure, resets all state.
    public func assembleAndVerify() -> Data? {
        guard isComplete, let totalSize, let count = pieceCount else { return nil }
        var assembled = Data(capacity: totalSize)
        for i in 0..<count {
            guard let piece = pieces[i] else { return nil }
            assembled.append(piece)
        }
        let hash = SHA1.hash(assembled)
        guard hash == infoHash else {
            Log.engine.error("❌ SHA1 mismatch — resetting")
            reset()
            return nil
        }
        Log.engine.info("✅ Metadata verified (\(assembled.count) bytes)")
        return assembled
    }

    /// Reset all state (called on SHA1 mismatch).
    public func reset() {
        totalSize = nil
        pieces.removeAll()
    }
}
