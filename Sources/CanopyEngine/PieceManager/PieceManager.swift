import Foundation

/// Maximum number of in-flight block requests per peer.
public let maxPipelineDepth = 5

/// Standard block size for requests (16 KB).
public let blockSize = 16384

/// Tracks download state for a single piece.
public actor PieceManager {
    public let pieceCount: Int
    public let pieceLength: Int64
    public let totalSize: Int64
    public let expectedHashes: [Data]  // 20-byte SHA1 per piece

    private var bitfield: Bitfield
    private var pendingBlocks: Set<BlockRequest> = []
    private var downloadedBlocks: [Int: [Int: Data]] = [:]  // piece → (blockBegin → data)

    public init(pieceCount: Int, pieceLength: Int64, totalSize: Int64, expectedHashes: [Data]) {
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.totalSize = totalSize
        self.expectedHashes = expectedHashes
        self.bitfield = Bitfield(size: pieceCount)
    }

    /// Mark a piece as owned (from our own bitfield or a peer's bitfield).
    public func markHave(piece: Int) { bitfield.set(piece) }
    public func hasPiece(_ piece: Int) -> Bool { bitfield.isSet(piece) }

    /// Get the next needed piece (rarest-first selection happens at a higher level).
    /// Get the next needed piece, optionally excluding pieces already assigned to other peers
    /// and restricted to pieces available from a specific peer. Empty availableIn = unknown, assume all.
    public func nextNeededPiece(excluding: Set<Int> = [], availableIn: Set<Int> = []) -> Int? {
        for i in 0..<pieceCount where !bitfield.isSet(i) && !excluding.contains(i) {
            if availableIn.isEmpty || availableIn.contains(i) { return i }
        }
        return nil
    }

    /// Progress 0–1.
    public var progress: Double {
        guard pieceCount > 0 else { return 0 }
        return Double(bitfield.count) / Double(pieceCount)
    }

    /// Whether all pieces are downloaded.
    public var isComplete: Bool { bitfield.count == pieceCount }

    /// Generate the next batch of block requests for a given piece.
    public func nextBlockRequests(for piece: Int, count: Int = maxPipelineDepth) -> [BlockRequest] {
        let actualSize: Int = (piece == pieceCount - 1)
            ? Int(totalSize - (Int64(piece) * pieceLength))
            : Int(pieceLength)
        let blockCount = (actualSize + blockSize - 1) / blockSize

        var requests: [BlockRequest] = []
        let pieceBlocks = downloadedBlocks[piece] ?? [:]
        for blk in 0..<blockCount {
            let begin = blk * blockSize
            let length = min(blockSize, actualSize - begin)
            let req = BlockRequest(piece: piece, begin: begin, length: length)
            if !pieceBlocks.keys.contains(begin) && !pendingBlocks.contains(req) {
                requests.append(req)
                pendingBlocks.insert(req)
                if requests.count >= count { break }
            }
        }
        return requests
    }

    /// Cancel all pending block requests for a given piece (e.g. peer disconnected).
    public func cancelPending(for piece: Int) {
        pendingBlocks = pendingBlocks.filter { $0.piece != piece }
    }

    /// Store a downloaded block.
    public func storeBlock(piece: Int, begin: Int, data: Data) {
        downloadedBlocks[piece, default: [:]][begin] = data
        pendingBlocks.remove(BlockRequest(piece: piece, begin: begin, length: data.count))
    }

    /// Try to assemble and verify a complete piece. Returns verified data, or nil if incomplete/wrong.
    public func tryAssemble(piece: Int) -> Data? {
        let actualSize: Int = (piece == pieceCount - 1)
            ? Int(totalSize - (Int64(piece) * pieceLength))
            : Int(pieceLength)
        let blockCount = (actualSize + blockSize - 1) / blockSize

        let pieceBlocks = downloadedBlocks[piece] ?? [:]
        var assembled = Data(capacity: actualSize)
        for blk in 0..<blockCount {
            let begin = blk * blockSize
            guard let data = pieceBlocks[begin] else { return nil }
            assembled.append(data)
        }

        // SHA1 verify
        let hash = SHA1.hash(assembled)
        guard hash == expectedHashes[piece] else {
            // Hash mismatch — discard all blocks for this piece, will re-request
            for blk in 0..<blockCount {
                let begin = blk * blockSize
                downloadedBlocks[piece]?.removeValue(forKey: begin)
                pendingBlocks.remove(BlockRequest(piece: piece, begin: begin, length: min(blockSize, actualSize - begin)))
            }
            return nil
        }

        // Success — mark as owned and free block memory
        bitfield.set(piece)
        downloadedBlocks.removeValue(forKey: piece)
        return assembled
    }
}

public struct BlockRequest: Hashable {
    public let piece: Int
    public let begin: Int
    public let length: Int
}

// MARK: - Bitfield

struct Bitfield {
    private var bits: [UInt8]
    private(set) var count: Int

    init(size: Int) {
        self.bits = Array(repeating: 0, count: (size + 7) / 8)
        self.count = 0
    }

    mutating func set(_ index: Int) {
        let byte = index / 8
        let bit = index % 8
        if (bits[byte] & (1 << (7 - bit))) == 0 {
            bits[byte] |= (1 << (7 - bit))
            count += 1
        }
    }

    func isSet(_ index: Int) -> Bool {
        let byte = index / 8
        let bit = index % 8
        return (bits[byte] & (1 << (7 - bit))) != 0
    }
}
