//  PiecePicker.swift
//  Canopy — Native Swift Engine
//
//  Availability tracking, rarest-first piece selection, block-level request
//  bookkeeping, and SHA-1 verification (BEP 3). Blocks are the spec-mandated
//  16 KiB (2^14); the last block of the last piece may be short.
//
//  Not thread-safe on its own — TorrentDownloader (an actor) owns the only
//  instance and serializes all access.

import CryptoKit
import Foundation

/// A single outstanding block request: piece `index`, byte `begin`, `length`.
struct BlockRequest: Equatable {
    let index: UInt32
    let begin: UInt32
    let length: UInt32
}

/// Result of feeding a received block into the manager.
enum BlockResult: Equatable {
    case accepted  // stored, piece still incomplete
    case ignored  // duplicate / unexpected / not in progress
    case pieceComplete(index: Int, data: Data)  // all blocks in; ready to verify
}

/// A piece being assembled from blocks.
private struct PartialPiece {
    let index: Int
    let length: Int
    let blockLength: Int
    let blockCount: Int
    var buffer: Data
    var requested: [Bool]
    var received: [Bool]
    var receivedCount = 0

    init(index: Int, length: Int, blockLength: Int) {
        self.index = index
        self.length = length
        self.blockLength = blockLength
        self.blockCount = (length + blockLength - 1) / blockLength
        self.buffer = Data(count: length)
        self.requested = [Bool](repeating: false, count: blockCount)
        self.received = [Bool](repeating: false, count: blockCount)
    }

    /// Byte length of block `b` (the final block may be truncated).
    func size(of b: Int) -> Int { min(blockLength, length - b * blockLength) }

    /// Next block we haven't requested or received yet.
    func nextUnrequested() -> (block: Int, begin: UInt32, length: UInt32)? {
        for b in 0..<blockCount where !requested[b] && !received[b] {
            return (b, UInt32(b * blockLength), UInt32(size(of: b)))
        }
        return nil
    }

    /// Store an incoming block. Returns true if this completed the piece.
    mutating func store(begin: Int, block: Data) -> Bool {
        guard begin >= 0, begin % blockLength == 0 else { return false }
        let b = begin / blockLength
        guard b < blockCount, block.count == size(of: b), !received[b] else { return false }
        buffer.replaceSubrange(begin..<(begin + block.count), with: block)
        received[b] = true
        requested[b] = true
        receivedCount += 1
        return receivedCount == blockCount
    }
}

final class PieceManager {
    static let blockLength = 1 << 14  // 16 KiB, per BEP 3

    private let metainfo: TorrentMetainfo
    private let pieceCount: Int

    private(set) var have: Bitfield  // pieces we've verified + written
    private var availability: [Int]  // how many connected peers hold each piece
    private var inProgress = Set<Int>()
    private var partials: [Int: PartialPiece] = [:]
    private(set) var completedCount = 0

    init(metainfo: TorrentMetainfo) {
        self.metainfo = metainfo
        self.pieceCount = metainfo.pieceCount
        self.have = Bitfield(pieceCount: metainfo.pieceCount)
        self.availability = [Int](repeating: 0, count: metainfo.pieceCount)
    }

    var isComplete: Bool { completedCount == pieceCount }

    // MARK: Availability

    func addAvailability(_ field: Bitfield) {
        for i in 0..<pieceCount where field.has(i) { availability[i] += 1 }
    }

    func addHave(_ index: Int) {
        guard index >= 0, index < pieceCount else { return }
        availability[index] += 1
    }

    // MARK: Request scheduling

    /// Hand out the next block to request from a peer with the given bitfield.
    /// Prefers finishing pieces already in progress (that this peer has), then
    /// starts a new rarest-first piece. Marks the block as requested.
    func nextRequest(for peerField: Bitfield) -> BlockRequest? {
        // 1) Continue an in-progress piece this peer can serve.
        for idx in inProgress where peerField.has(idx) {
            if var partial = partials[idx], let next = partial.nextUnrequested() {
                partial.requested[next.block] = true
                partials[idx] = partial
                return BlockRequest(index: UInt32(idx), begin: next.begin, length: next.length)
            }
        }
        // 2) Start a fresh rarest-first piece this peer has.
        guard let idx = selectNewPiece(for: peerField) else { return nil }
        var partial = PartialPiece(
            index: idx,
            length: Int(metainfo.lengthOfPiece(idx)),
            blockLength: Self.blockLength)
        guard let next = partial.nextUnrequested() else { return nil }
        partial.requested[next.block] = true
        partials[idx] = partial
        inProgress.insert(idx)
        return BlockRequest(index: UInt32(idx), begin: next.begin, length: next.length)
    }

    /// Rarest-first among pieces we still need and the peer has, random tie-break.
    private func selectNewPiece(for peerField: Bitfield) -> Int? {
        var rarest = Int.max
        var candidates: [Int] = []
        for i in 0..<pieceCount where !have.has(i) && !inProgress.contains(i) && peerField.has(i) {
            let a = availability[i]
            guard a > 0 else { continue }
            if a < rarest {
                rarest = a
                candidates = [i]
            } else if a == rarest {
                candidates.append(i)
            }
        }
        return candidates.randomElement()
    }

    // MARK: Block intake + verification

    func receivedBlock(index: Int, begin: Int, block: Data) -> BlockResult {
        guard var partial = partials[index] else { return .ignored }
        let completed = partial.store(begin: begin, block: block)
        partials[index] = partial
        return completed ? .pieceComplete(index: index, data: partial.buffer) : .accepted
    }

    /// SHA-1 of the assembled piece vs the hash from the metainfo `pieces` list.
    func verify(index: Int, data: Data) -> Bool {
        guard index >= 0, index < metainfo.pieceHashes.count else { return false }
        return Data(Insecure.SHA1.hash(data: data)) == metainfo.pieceHashes[index]
    }

    func markVerified(_ index: Int) {
        guard !have.has(index) else { return }
        have.set(index)
        partials[index] = nil
        inProgress.remove(index)
        completedCount += 1
    }

    /// Throw away a piece (bad hash, or a write failed) so it gets re-downloaded.
    func resetPiece(_ index: Int) {
        partials[index] = nil
        inProgress.remove(index)
    }

    /// Release blocks that were in-flight on a peer that just died, without
    /// discarding any data already stored, so other peers can re-request them.
    func requeue(_ requests: [BlockRequest]) {
        for r in requests {
            let idx = Int(r.index)
            guard var partial = partials[idx] else { continue }
            let b = Int(r.begin) / Self.blockLength
            if b >= 0, b < partial.blockCount, !partial.received[b] {
                partial.requested[b] = false
            }
            partials[idx] = partial
        }
    }
}
