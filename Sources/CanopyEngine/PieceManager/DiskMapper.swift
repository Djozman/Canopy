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

    /// Given a piece index and a byte offset within that piece, return the
    /// file index, offset within that file, and how many bytes to write
    /// (clamped to the file boundary).
    public func map(piece: Int, blockBegin: Int) -> (fileIndex: Int, fileOffset: Int64, length: Int) {
        let absoluteOffset = Int64(piece) * pieceLength + Int64(blockBegin)
        guard let fileIdx = fileOffsets.lastIndex(where: { $0 <= absoluteOffset }) else {
            return (0, absoluteOffset, min(Int(pieceLength) - blockBegin, Int(files[0].size)))
        }
        let fileStart = fileOffsets[fileIdx]
        let fileEnd = fileStart + files[fileIdx].size
        let fileOffset = absoluteOffset - fileStart
        let remainingInFile = fileEnd - absoluteOffset
        let remainingInBlock = Int(pieceLength) - blockBegin
        let length = min(Int(remainingInFile), remainingInBlock)
        return (fileIdx, fileOffset, length)
    }

    /// Return file handles for all files, created/opened at the given path prefix.
    public func openFiles(at rootPath: String) throws -> [FileHandle] {
        let root = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        return try files.map { entry in
            let filePath = root + entry.path.replacingOccurrences(of: "/", with: "-")
            if !fm.fileExists(atPath: filePath) {
                fm.createFile(atPath: filePath, contents: nil)
            }
            guard let fh = FileHandle(forWritingAtPath: filePath) else {
                throw NSError(domain: "DiskMapper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(filePath)"])
            }
            fh.seekToEndOfFile()
            return fh
        }
    }
}
