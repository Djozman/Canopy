//  TorrentStorage.swift
//  Canopy — Native Swift Engine
//
//  Maps the torrent's linear byte space (BEP 3 treats a multi-file torrent as
//  the concatenation of its files, in order) onto real files on disk, and
//  reads/writes byte ranges that may straddle file boundaries.

import Foundation

final class TorrentStorage {
    private let files: [TorrentFileEntry]  // each has absolute `offset` + `length`
    private let totalLength: Int64
    private var handles: [FileHandle]

    /// Creates the directory tree under `downloadDirectory`, preallocates each
    /// file to its full length, and opens it for read/write.
    /// `entry.path` already includes the torrent name as its first component.
    init(metainfo: TorrentMetainfo, downloadDirectory: URL) throws {
        self.files = metainfo.files
        self.totalLength = metainfo.totalLength

        let fm = FileManager.default
        var opened: [FileHandle] = []
        opened.reserveCapacity(files.count)
        for entry in files {
            let fileURL = downloadDirectory.appendingPathComponent(entry.path)
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forUpdating: fileURL)
            try handle.truncate(atOffset: UInt64(entry.length))  // sparse preallocation
            opened.append(handle)
        }
        self.handles = opened
    }

    /// Write `data` starting at absolute torrent offset, splitting across files.
    func write(at offset: Int64, data: Data) throws {
        let end = offset + Int64(data.count)
        for (idx, file) in files.enumerated() {
            let fileStart = file.offset
            let fileEnd = file.offset + file.length
            guard end > fileStart, offset < fileEnd else { continue }  // no overlap

            let segStart = max(offset, fileStart)
            let segEnd = min(end, fileEnd)
            let inFileOffset = UInt64(segStart - fileStart)
            let chunk = data.subdata(in: Int(segStart - offset)..<Int(segEnd - offset))

            let handle = handles[idx]
            try handle.seek(toOffset: inFileOffset)
            try handle.write(contentsOf: chunk)
        }
    }

    /// Read `length` bytes starting at an absolute torrent offset (used to
    /// re-verify already-on-disk pieces on resume).
    func read(at offset: Int64, length: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(length)
        let end = offset + Int64(length)
        for (idx, file) in files.enumerated() {
            let fileStart = file.offset
            let fileEnd = file.offset + file.length
            guard end > fileStart, offset < fileEnd else { continue }

            let segStart = max(offset, fileStart)
            let segEnd = min(end, fileEnd)
            let handle = handles[idx]
            try handle.seek(toOffset: UInt64(segStart - fileStart))
            if let part = try handle.read(upToCount: Int(segEnd - segStart)) {
                out.append(part)
            }
        }
        return out
    }

    func flush() { handles.forEach { try? $0.synchronize() } }

    func close() {
        handles.forEach { try? $0.close() }
        handles = []
    }
}
