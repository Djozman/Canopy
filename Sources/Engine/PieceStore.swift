import Foundation
import CryptoKit

// Manages on-disk file layout and piece verification.
// Block = 16 KiB sub-unit of a piece (standard BitTorrent block size).
actor PieceStore {
    static let blockSize = 16_384  // 16 KiB

    private let meta: Metainfo
    private let saveDir: URL
    private var bitfield: [Bool]           // true = piece complete & verified
    private var pendingBlocks: [Int: [Int: Data]] = [:]  // [pieceIndex: [blockOffset: data]]
    private var fileHandles: [URL: FileHandle] = [:]
    private var fileOffsets: [String: Int64] = [:]  // precomputed cumulative byte offsets
    private var stateURL: URL
    private var isClosed = false
    private var lastSaveTime: Date = .distantPast

    var completedPieces: Int { bitfield.filter { $0 }.count }
    var totalPieces: Int { meta.pieces.count }
    var progress: Double { totalPieces == 0 ? 0 : Double(completedPieces) / Double(totalPieces) }
    var bitfieldCopy: [Bool] { bitfield }
    
    var downloaded: Int64 {
        guard completedPieces > 0 else { return 0 }
        let lastPiece = meta.pieces.count - 1
        let fullCount = bitfield.indices.filter { $0 != lastPiece && bitfield[$0] }.count
        let lastBytes = bitfield[lastPiece] ? pieceLength(for: lastPiece) : 0
        return Int64(fullCount) * Int64(meta.pieceLength) + Int64(lastBytes)
    }

    /// Sum of file lengths the user opted into. This is the meaningful denominator for
    /// download progress when the user has deselected files — "MB downloaded of MB I want"
    /// rather than "MB downloaded of MB the torrent contains".
    var selectedSize: Int64 {
        if skippedFiles.isEmpty { return meta.totalSize }
        var total: Int64 = 0
        for (idx, file) in meta.files.enumerated() where !skippedFiles.contains(idx) {
            total += file.length
        }
        return total
    }

    /// Bytes of *selected* file data that have been verified on disk. Boundary pieces
    /// that overlap multiple files only count their wanted slice — the bits we actually
    /// wrote to disk, not the whole piece.
    var downloadedSelected: Int64 {
        var bytes: Int64 = 0
        for (fileIdx, file) in meta.files.enumerated() where !skippedFiles.contains(fileIdx) {
            bytes += completedBytes(forFileIndex: fileIdx, fileLength: file.length)
        }
        return bytes
    }

    /// Per-file download fraction, [0, 1]. For deselected files this is always 0 because
    /// `write(piece:)` doesn't touch them; the bytes-on-disk for that file remain zero.
    func fileProgress(_ fileIndex: Int) -> Double {
        guard fileIndex < meta.files.count else { return 0 }
        if skippedFiles.contains(fileIndex) { return 0 }
        let file = meta.files[fileIndex]
        guard file.length > 0 else { return 1 }
        return Double(completedBytes(forFileIndex: fileIndex, fileLength: file.length)) / Double(file.length)
    }

    /// Sum of completed-piece bytes that fall *inside* the byte range of the given file.
    /// Walks pieces only within the file's range — O(file_size / piece_size) per call.
    private func completedBytes(forFileIndex fileIndex: Int, fileLength: Int64) -> Int64 {
        let file = meta.files[fileIndex]
        let fileStart = fileOffset(for: file)
        let fileEnd   = fileStart + fileLength
        let pieceLen  = Int64(meta.pieceLength)
        let firstPiece = Int(fileStart / pieceLen)
        let lastPiece  = Int((fileEnd - 1) / pieceLen)
        var bytes: Int64 = 0
        for p in firstPiece...lastPiece {
            guard p < bitfield.count, bitfield[p] else { continue }
            let pieceStart = Int64(p) * pieceLen
            let pieceEnd   = pieceStart + Int64(pieceLength(for: p))
            let overlap = min(pieceEnd, fileEnd) - max(pieceStart, fileStart)
            if overlap > 0 { bytes += overlap }
        }
        return bytes
    }

    init(meta: Metainfo, saveDir: URL, skippedFiles: Set<Int> = []) throws {
        self.meta = meta
        self.saveDir = saveDir
        self.skippedFiles = skippedFiles
        self.bitfield = Array(repeating: false, count: meta.pieces.count)
        self.stateURL = saveDir.appendingPathComponent(".canopy_state_\(meta.infoHash.map { String(format: "%02x", $0) }.joined())")
        
        // Precompute cumulative file offsets once — O(1) lookup in read/write hot paths
        var cum: Int64 = 0
        for file in meta.files {
            fileOffsets[file.path.joined(separator: "/")] = cum
            cum += file.length
        }

        try Self.createLayout(meta: meta, dir: saveDir, skippedFiles: skippedFiles)

        if let data = try? Data(contentsOf: stateURL),
           let savedBitfield = try? JSONDecoder().decode([Bool].self, from: data),
           savedBitfield.count == bitfield.count {
            self.bitfield = savedBitfield
        }
    }
    
    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let savedBitfield = try? JSONDecoder().decode([Bool].self, from: data),
              savedBitfield.count == bitfield.count else {
            return
        }
        self.bitfield = savedBitfield
    }
    
    private func saveState(force: Bool = false) {
        guard !isClosed else { return }
        let now = Date.now
        guard force || now.timeIntervalSince(lastSaveTime) >= 5 else { return }
        lastSaveTime = now
        if let data = try? JSONEncoder().encode(bitfield) {
            try? data.write(to: stateURL)
        }
    }

    // Pre-allocate file layout on disk. Skipped files get neither directory entries nor
    // empty placeholders — the user explicitly opted out, so nothing of theirs appears in
    // the save folder. (A piece that *overlaps* both a wanted file and a skipped file is
    // still downloaded for the wanted part; `write(piece:)` filters out the skipped slice.)
    private static func createLayout(meta: Metainfo, dir: URL, skippedFiles: Set<Int>) throws {
        let fm = FileManager.default
        if meta.isSingleFile {
            // Single-file torrents only have one file — if the user skipped it, there's
            // nothing to download at all.
            guard !skippedFiles.contains(0) else { return }
            let url = dir.appendingPathComponent(meta.name)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
                let fh = try FileHandle(forWritingTo: url)
                Self.preallocate(fileHandle: fh, size: meta.totalSize)
                try fh.close()
            }
        } else {
            let torrentDir = dir.appendingPathComponent(meta.name)
            try fm.createDirectory(at: torrentDir, withIntermediateDirectories: true)
            for (idx, file) in meta.files.enumerated() where !skippedFiles.contains(idx) {
                let url = file.path.dropLast().reduce(torrentDir) { $0.appendingPathComponent($1) }
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let fileURL = torrentDir.appendingPathComponent(file.name)
                if !fm.fileExists(atPath: fileURL.path) {
                    fm.createFile(atPath: fileURL.path, contents: nil)
                    if file.length > 0 {
                        let fh = try FileHandle(forWritingTo: fileURL)
                        Self.preallocate(fileHandle: fh, size: file.length)
                        try fh.close()
                    }
                }
            }
        }
    }

    /// Sets the file's *logical* size only. Physical disk blocks remain unallocated
    /// until we actually write piece data — the file is sparse on APFS, so `du` and
    /// Finder's "size used" reflect bytes downloaded, not bytes reserved.
    /// Tradeoff: slightly higher fragmentation on giant (>50 GB) torrents vs.
    /// `F_PREALLOCATE`, but APFS's copy-on-write extents handle this gracefully.
    private static func preallocate(fileHandle fh: FileHandle, size: Int64) {
        ftruncate(fh.fileDescriptor, off_t(size))
    }

    // Receive a block from a peer
    func receiveBlock(piece: Int, offset: Int, data: Data) async throws {
        guard !isClosed else { return }
        guard piece >= 0 && piece < meta.pieces.count, !bitfield[piece] else { return }
        pendingBlocks[piece, default: [:]][offset] = data
        try await assembleIfComplete(piece: piece)
    }

    /// Pieces currently undergoing async hash verification — skip them in
    /// `assembleIfComplete` so a flood of inbound blocks doesn't kick off duplicate jobs.
    private var verifyingPieces: Set<Int> = []

    // MARK: - Upload read cache (LRU, 64 MiB)
    // Recently-read blocks are kept in RAM keyed by (piece, offset, length). Many peers
    // requesting the same hot blocks (start of a swarm, popular seed) hit RAM instead of
    // round-tripping through disk. Pre-warmed by `assembleIfComplete` on piece complete.
    private var readCache: [UInt64: Data] = [:]
    private var readCacheOrder: [UInt64] = []
    /// 32 MiB. Big enough to absorb hot-block bursts when many peers want our newest
    /// pieces; small enough that the app's resident memory stays modest.
    private let readCacheMaxBytes: Int = 32 * 1_048_576
    private var readCacheBytes: Int = 0

    private func cacheKey(piece: Int, offset: Int, length: Int) -> UInt64 {
        UInt64(piece & 0xFFFFFF) << 40 | UInt64(offset & 0xFFFFFF) << 16 | UInt64(length & 0xFFFF)
    }

    private func cachePut(_ key: UInt64, _ data: Data) {
        if readCache[key] != nil { return }
        readCache[key] = data
        readCacheOrder.append(key)
        readCacheBytes += data.count
        while readCacheBytes > readCacheMaxBytes, let oldKey = readCacheOrder.first {
            readCacheOrder.removeFirst()
            if let evicted = readCache.removeValue(forKey: oldKey) { readCacheBytes -= evicted.count }
        }
    }

    func hasPiece(_ index: Int) -> Bool { bitfield[index] }

    var skippedFiles: Set<Int> = []

    func updateSkippedFiles(_ skipped: Set<Int>) { skippedFiles = skipped }

    func missingPieces() -> [Int] {
        bitfield.indices.filter { !bitfield[$0] }
    }

    // Like missingPieces() but excluding pieces that fall entirely within skipped files.
    func wantedPieces() -> [Int] {
        missingPieces().filter { isWanted(piece: $0) }
    }

    private func isWanted(piece: Int) -> Bool {
        guard !skippedFiles.isEmpty else { return true }
        let pieceStart = Int64(piece) * Int64(meta.pieceLength)
        let pieceEnd   = pieceStart + Int64(pieceLength(for: piece))
        for (idx, file) in meta.files.enumerated() {
            guard !skippedFiles.contains(idx) else { continue }
            let fs = fileOffset(for: file); let fe = fs + file.length
            if fs < pieceEnd && fe > pieceStart { return true }
        }
        return false
    }
    
    func getBitfield() -> [Bool] { bitfield }

    func readBlock(piece: Int, offset: Int, length: Int) throws -> Data? {
        guard piece < meta.pieces.count, bitfield[piece] else { return nil }

        // Cache hit — skip disk entirely.
        let cKey = cacheKey(piece: piece, offset: offset, length: length)
        if let cached = readCache[cKey] { return cached }

        let globalOffset = Int64(piece) * Int64(meta.pieceLength) + Int64(offset)
        var result = Data()
        var remaining = Int64(length)
        var currentOffset = globalOffset

        for file in meta.files {
            let fileStart = fileOffset(for: file)
            let fileEnd = fileStart + file.length

            guard currentOffset < fileEnd && (currentOffset + remaining) > fileStart else { continue }

            let inFileStart = max(currentOffset, fileStart) - fileStart
            let count = min(currentOffset + remaining, fileEnd) - max(currentOffset, fileStart)

            let fileURL = fileURL(for: file)
            let fh = try fileHandle(for: fileURL, writing: false)
            fh.seek(toFileOffset: UInt64(inFileStart))
            result.append(fh.readData(ofLength: Int(count)))

            remaining -= count
            currentOffset += count
            if remaining <= 0 { break }
        }

        guard result.count == length else { return nil }
        cachePut(cKey, result)
        return result
    }

    // Single call that replaces the O(pieces) loop of blocksNeeded() calls in scheduling.
    // Returns up to maxBlocks requests from orderedPieces that this peer has and aren't excluded.
    func blocksToRequest(
        orderedPieces: [Int],
        peerBitfield: [Bool],
        excluding: Set<UInt64>,
        endgame: Bool,
        maxBlocks: Int
    ) -> [(piece: Int, offset: Int, length: Int)] {
        var result: [(Int, Int, Int)] = []
        for piece in orderedPieces {
            guard piece < peerBitfield.count, peerBitfield[piece], !bitfield[piece] else { continue }
            let len = pieceLength(for: piece)
            let existing = pendingBlocks[piece] ?? [:]
            var off = 0
            while off < len {
                if existing[off] == nil {
                    let key = Self.inFlightKey(piece: piece, blockIndex: off / Self.blockSize)
                    if endgame || !excluding.contains(key) {
                        result.append((piece, off, min(Self.blockSize, len - off)))
                        if result.count >= maxBlocks { return result }
                    }
                }
                off += Self.blockSize
            }
        }
        return result
    }

    static func inFlightKey(piece: Int, blockIndex: Int) -> UInt64 {
        (UInt64(piece) << 32) | UInt64(blockIndex)
    }

    // All blocks for a piece regardless of what we have (for sending CANCELs)
    func allBlocksForPiece(piece: Int) -> [(offset: Int, length: Int)] {
        let len = pieceLength(for: piece)
        var result: [(Int, Int)] = []
        var off = 0
        while off < len {
            result.append((off, min(Self.blockSize, len - off)))
            off += Self.blockSize
        }
        return result
    }

    // Blocks needed for a piece: [(offset, length)]
    func blocksNeeded(piece: Int) -> [(offset: Int, length: Int)] {
        let pieceLen = pieceLength(for: piece)
        let existing = pendingBlocks[piece] ?? [:]
        var result: [(Int, Int)] = []
        var off = 0
        while off < pieceLen {
            if existing[off] == nil {
                let len = min(Self.blockSize, pieceLen - off)
                result.append((off, len))
            }
            off += Self.blockSize
        }
        return result
    }

    // MARK: - Reading & Writing

    private func pieceLength(for index: Int) -> Int {
        let last = meta.pieces.count - 1
        if index == last {
            let remainder = Int(meta.totalSize) % meta.pieceLength
            return remainder == 0 ? meta.pieceLength : remainder
        }
        return meta.pieceLength
    }

    private func assembleIfComplete(piece: Int) async throws {
        guard !verifyingPieces.contains(piece) else { return }
        let len = pieceLength(for: piece)
        let blocks = pendingBlocks[piece] ?? [:]
        // Pre-allocate exact piece size and slot blocks via replaceSubrange — avoids
        // the O(n²) growth pattern of repeated Data.append() on large pieces.
        var assembled = Data(count: len)
        var off = 0
        while off < len {
            guard let block = blocks[off] else { return }  // not ready yet
            let blockLen = min(Self.blockSize, len - off)
            assembled.replaceSubrange(off..<(off + blockLen), with: block.prefix(blockLen))
            off += Self.blockSize
        }

        // Move SHA1 off the actor — hashing a multi-MB piece blocks all peer reads
        // and writes for 5–15 ms on M1 otherwise. Detached Task runs userInitiated
        // priority on a background queue.
        verifyingPieces.insert(piece)
        let expected = meta.pieces[piece]
        let assembledCopy = assembled
        let isValid = await Task.detached(priority: .userInitiated) { () -> Bool in
            Data(Insecure.SHA1.hash(data: assembledCopy)) == expected
        }.value
        verifyingPieces.remove(piece)
        guard !isClosed else { return }

        guard isValid else {
            pendingBlocks[piece] = nil  // bad data, discard and re-request
            return
        }
        try write(piece: piece, data: assembled)
        bitfield[piece] = true
        pendingBlocks[piece] = nil

        // Pre-warm the upload cache — peers will request blocks of this piece within
        // seconds of seeing our HAVE, and now they hit RAM instead of seeking disk.
        var bo = 0
        while bo < len {
            let blockLen = min(Self.blockSize, len - bo)
            let key = cacheKey(piece: piece, offset: bo, length: blockLen)
            cachePut(key, Data(assembled[bo..<(bo + blockLen)]))
            bo += Self.blockSize
        }
        saveState()
    }

    private func write(piece: Int, data: Data) throws {
        let globalOffset = Int64(piece) * Int64(meta.pieceLength)
        var written = 0

        for (idx, file) in meta.files.enumerated() {
            // The piece may overlap a skipped file — we still verified its hash, but the
            // user opted out of this file so we skip writes to its slice. (createLayout
            // didn't even create the file on disk, so opening a handle would fail anyway.)
            if skippedFiles.contains(idx) { continue }

            let fileStart = fileOffset(for: file)
            let fileEnd = fileStart + file.length
            let pieceEnd = globalOffset + Int64(data.count)

            guard fileStart < pieceEnd && fileEnd > globalOffset else { continue }

            let inFileStart = max(globalOffset, fileStart) - fileStart
            let inPieceStart = max(globalOffset, fileStart) - globalOffset
            let count = min(pieceEnd, fileEnd) - max(globalOffset, fileStart)

            let fileURL = fileURL(for: file)
            let fh = try fileHandle(for: fileURL)
            fh.seek(toFileOffset: UInt64(inFileStart))
            fh.write(data[Int(inPieceStart)..<Int(inPieceStart + count)])
            written += Int(count)
        }
    }

    private func fileOffset(for file: FileEntry) -> Int64 {
        fileOffsets[file.path.joined(separator: "/")] ?? 0
    }

    private func fileURL(for file: FileEntry) -> URL {
        if meta.isSingleFile {
            return saveDir.appendingPathComponent(file.name)
        }
        return file.path.reduce(saveDir.appendingPathComponent(meta.name)) {
            $0.appendingPathComponent($1)
        }
    }

    private func fileHandle(for url: URL, writing: Bool = true) throws -> FileHandle {
        guard !isClosed else { throw NSError(domain: "PieceStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Store is closed"]) }
        if let fh = fileHandles[url] { return fh }
        let fh = try FileHandle(forUpdating: url)
        fileHandles[url] = fh
        return fh
    }

    func closeAll() {
        saveState(force: true)
        isClosed = true
        fileHandles.values.forEach { try? $0.close() }
        fileHandles.removeAll()
    }
    
    /// Verifies all files on disk against SHA-1 hashes.
    func fullVerification() async {
        for i in 0..<meta.pieces.count {
            if let data = try? readPiece(i),
               Data(Insecure.SHA1.hash(data: data)) == meta.pieces[i] {
                bitfield[i] = true
            } else {
                bitfield[i] = false
            }
        }
        saveState()
    }
    
    private func readPiece(_ index: Int) throws -> Data? {
        let len = pieceLength(for: index)
        let globalOffset = Int64(index) * Int64(meta.pieceLength)
        var result = Data()
        var remaining = Int64(len)
        var currentOffset = globalOffset
        
        for file in meta.files {
            let fileStart = fileOffset(for: file)
            let fileEnd = fileStart + file.length
            guard currentOffset < fileEnd && (currentOffset + remaining) > fileStart else { continue }
            
            let inFileStart = max(currentOffset, fileStart) - fileStart
            let count = min(currentOffset + remaining, fileEnd) - max(currentOffset, fileStart)
            
            let fileURL = fileURL(for: file)
            let fh = try FileHandle(forReadingFrom: fileURL)
            fh.seek(toFileOffset: UInt64(inFileStart))
            result.append(fh.readData(ofLength: Int(count)))
            try fh.close()
            
            remaining -= count
            currentOffset += count
            if remaining <= 0 { break }
        }
        return result.count == len ? result : nil
    }
}
