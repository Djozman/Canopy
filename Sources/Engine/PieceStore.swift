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

        try Self.createLayout(meta: meta, dir: saveDir)

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

    // Pre-allocate file layout on disk
    private static func createLayout(meta: Metainfo, dir: URL) throws {
        let fm = FileManager.default
        if meta.isSingleFile {
            let url = dir.appendingPathComponent(meta.name)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
                let fh = try FileHandle(forWritingTo: url)
                fh.seekToEndOfFile()
                let end = fh.offsetInFile
                if end < UInt64(meta.totalSize) {
                    fh.seek(toFileOffset: UInt64(meta.totalSize) - 1)
                    fh.write(Data([0]))
                }
                try fh.close()
            }
        } else {
            let torrentDir = dir.appendingPathComponent(meta.name)
            try fm.createDirectory(at: torrentDir, withIntermediateDirectories: true)
            for file in meta.files {
                let url = file.path.dropLast().reduce(torrentDir) { $0.appendingPathComponent($1) }
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let fileURL = torrentDir.appendingPathComponent(file.name)
                if !fm.fileExists(atPath: fileURL.path) {
                    fm.createFile(atPath: fileURL.path, contents: nil)
                    if file.length > 0 {
                        let fh = try FileHandle(forWritingTo: fileURL)
                        fh.seek(toFileOffset: UInt64(file.length) - 1)
                        fh.write(Data([0]))
                        try fh.close()
                    }
                }
            }
        }
    }

    // Receive a block from a peer
    func receiveBlock(piece: Int, offset: Int, data: Data) throws {
        guard !isClosed else { return }
        guard piece >= 0 && piece < meta.pieces.count, !bitfield[piece] else { return }
        pendingBlocks[piece, default: [:]][offset] = data
        try assembleIfComplete(piece: piece)
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
        
        return result.count == length ? result : nil
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

    private func assembleIfComplete(piece: Int) throws {
        let len = pieceLength(for: piece)
        let blocks = pendingBlocks[piece] ?? [:]
        var assembled = Data(capacity: len)
        var off = 0
        while off < len {
            guard let block = blocks[off] else { return }  // not ready yet
            assembled.append(block)
            off += Self.blockSize
        }
        // Verify SHA1
        let hash = Insecure.SHA1.hash(data: assembled)
        guard Data(hash) == meta.pieces[piece] else {
            pendingBlocks[piece] = nil  // bad data, discard and re-request
            return
        }
        try write(piece: piece, data: assembled)
        bitfield[piece] = true
        pendingBlocks[piece] = nil
        saveState()
    }

    private func write(piece: Int, data: Data) throws {
        let globalOffset = Int64(piece) * Int64(meta.pieceLength)
        var written = 0

        for file in meta.files {
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
