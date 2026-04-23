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
    private var stateURL: URL

    var completedPieces: Int { bitfield.filter { $0 }.count }
    var totalPieces: Int { meta.pieces.count }
    var progress: Double { totalPieces == 0 ? 0 : Double(completedPieces) / Double(totalPieces) }
    var downloaded: Int64 { Int64(completedPieces) * Int64(meta.pieceLength) }

    init(meta: Metainfo, saveDir: URL) throws {
        self.meta = meta
        self.saveDir = saveDir
        self.bitfield = Array(repeating: false, count: meta.pieces.count)
        self.stateURL = saveDir.appendingPathComponent(".canopy_state_\(meta.infoHash.map { String(format: "%02x", $0) }.joined())")
        
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
    
    private func saveState() {
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
        guard piece < meta.pieces.count, !bitfield[piece] else { return }
        pendingBlocks[piece, default: [:]][offset] = data
        try assembleIfComplete(piece: piece)
    }

    func hasPiece(_ index: Int) -> Bool { bitfield[index] }

    func missingPieces() -> [Int] {
        bitfield.indices.filter { !bitfield[$0] }
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
        excluding: Set<String>,
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
                    let key = "\(piece):\(off)"
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

    // MARK: - Private

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
        var offset: Int64 = 0
        for f in meta.files {
            if f.path == file.path { break }
            offset += f.length
        }
        return offset
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
        if let fh = fileHandles[url] { return fh }
        let fh = writing ? try FileHandle(forWritingTo: url) : try FileHandle(forReadingFrom: url)
        fileHandles[url] = fh
        return fh
    }

    func closeAll() {
        saveState()
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
