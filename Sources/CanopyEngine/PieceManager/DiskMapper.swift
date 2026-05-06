import Foundation

/// Maps (pieceIndex, blockOffset) → (fileIndex, fileOffset, length) for multi-file torrents.
public struct DiskMapper {
    private let files: [TorrentFile.FileEntry]
    private let pieceLength: Int64

    /// Precomputed: running offset of each file in the torrent.
    private let fileOffsets: [Int64]

    public init(files: [TorrentFile.FileEntry], pieceLength: Int64) {
        self.files = files
        self.pieceLength = pieceLength
        var offset: Int64 = 0
        self.fileOffsets = files.map { f in
            let o = offset
            offset += f.size
            return o
        }
    }

    /// Map a block within a piece to file segments. Returns an array because
    /// a single block can span multiple files when it crosses a file boundary.
    public func map(piece: Int, blockBegin: Int, blockLength: Int) -> [(fileIndex: Int, fileOffset: Int64, length: Int)] {
        var result: [(Int, Int64, Int)] = []
        var remaining: Int64 = Int64(blockLength)
        var absoluteOffset = Int64(piece) * pieceLength + Int64(blockBegin)

        while remaining > 0 {
            guard let fileIdx = fileIndex(for: absoluteOffset) else { break }
            let fileStart = fileOffsets[fileIdx]
            let fileEnd = fileStart + files[fileIdx].size
            let fileOffset = absoluteOffset - fileStart
            let remainingInFile = fileEnd - absoluteOffset
            let chunk = min(remaining, remainingInFile)
            result.append((fileIdx, fileOffset, Int(chunk)))
            absoluteOffset += chunk
            remaining -= chunk
        }
        return result
    }

    /// Return file handles for all files, created/opened at the given root path.
    /// Preserves the torrent's directory structure.
    public func openFiles(at rootPath: String) throws -> [FileHandle] {
        let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let fm = FileManager.default
        return try files.map { entry in
            let filePath = root + entry.path
            let dir = (filePath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: filePath) {
                fm.createFile(atPath: filePath, contents: nil)
            }
            guard let fh = FileHandle(forUpdatingAtPath: filePath) else {
                throw NSError(domain: "DiskMapper", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot open \(filePath)"])
            }
            return fh
        }
    }

    /// Binary search for the file containing an absolute byte offset. Returns the index
    /// of the file whose range covers the offset, or nil if out of bounds.
    private func fileIndex(for offset: Int64) -> Int? {
        guard !fileOffsets.isEmpty else { return nil }
        var lo = 0
        var hi = fileOffsets.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if fileOffsets[mid] <= offset {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let idx = hi
        guard idx >= 0, idx < files.count else { return nil }
        let fileEnd = fileOffsets[idx] + files[idx].size
        return offset < fileEnd ? idx : nil
    }
}
