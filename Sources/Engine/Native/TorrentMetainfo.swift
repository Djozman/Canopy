// TorrentMetainfo.swift — BEP 3 .torrent parsing + SHA-1 info-hash (v1).

import CryptoKit
import Foundation

public struct TorrentFileEntry: Equatable {
    public let path: String  // "/" separated, includes the torrent name as first component
    public let length: Int64
    public let offset: Int64  // absolute byte offset in the concatenated torrent
}

public struct TorrentMetainfo {
    public let name: String
    public let infoHash: Data  // 20-byte SHA-1
    public let infoHashHex: String
    public let pieceLength: Int64
    public let pieceHashes: [Data]  // each exactly 20 bytes
    public let totalLength: Int64
    public let files: [TorrentFileEntry]
    public let isPrivate: Bool
    public let announce: String?
    public let announceList: [[String]]  // BEP 12 tiers
    public let creationDate: Date?
    public let comment: String?
    public let createdBy: String?

    public var pieceCount: Int { pieceHashes.count }
    public var isSingleFile: Bool { files.count == 1 }

    public enum ParseError: Error, CustomStringConvertible {
        case notADictionary, missingInfo
        case missingField(String)
        case badPieces
        case lengthAndFilesConflict  // BEP 3: must have length XOR files
        case emptyPath  // BEP 3: zero-length path list is an error
        public var description: String {
            switch self {
            case .notADictionary: return "root is not a bencoded dictionary"
            case .missingInfo: return "missing or invalid 'info' dictionary"
            case .missingField(let f): return "missing/invalid field: \(f)"
            case .badPieces: return "'pieces' missing or not a multiple of 20 bytes"
            case .lengthAndFilesConflict:
                return "'info' must contain exactly one of 'length' or 'files'"
            case .emptyPath: return "a file entry has an empty 'path' list"
            }
        }
    }

    public init(contentsOf url: URL) throws { try self.init(data: try Data(contentsOf: url)) }

    public init(data: Data) throws {
        let parser = BencodeParser(data)
        guard case .dict(let top) = try parser.parseRoot() else { throw ParseError.notADictionary }
        guard let infoBytes = parser.infoData, let info = top["info"]?.dictValue else {
            throw ParseError.missingInfo
        }

        // Info-hash: SHA-1 of the raw info-dict bytes, exactly as found on disk.
        infoHash = Data(Insecure.SHA1.hash(data: infoBytes))
        infoHashHex = infoHash.map { String(format: "%02x", $0) }.joined()

        guard let nm = info["name"]?.stringValue, !nm.isEmpty else {
            throw ParseError.missingField("name")
        }
        name = nm
        guard let pl = info["piece length"]?.intValue, pl > 0 else {
            throw ParseError.missingField("piece length")
        }
        pieceLength = pl
        guard let pieces = info["pieces"]?.dataValue, !pieces.isEmpty, pieces.count % 20 == 0 else {
            throw ParseError.badPieces
        }
        var hashes: [Data] = []
        hashes.reserveCapacity(pieces.count / 20)
        var p = 0
        while p < pieces.count {
            hashes.append(pieces.subdata(in: p..<(p + 20)))
            p += 20
        }
        pieceHashes = hashes
        isPrivate = (info["private"]?.intValue ?? 0) == 1

        // length XOR files — exactly one must be present.
        let hasLength = info["length"] != nil
        let hasFiles = info["files"] != nil
        guard hasLength != hasFiles else { throw ParseError.lengthAndFilesConflict }

        var entries: [TorrentFileEntry] = []
        var running: Int64 = 0
        if hasLength {
            guard let length = info["length"]?.intValue, length >= 0 else {
                throw ParseError.missingField("length")
            }
            entries.append(TorrentFileEntry(path: name, length: length, offset: 0))
            running = length
        } else {
            guard let filesList = info["files"]?.listValue else {
                throw ParseError.missingField("files")
            }
            for f in filesList {
                guard let fl = f["length"]?.intValue, fl >= 0 else {
                    throw ParseError.missingField("files[].length")
                }
                guard let comps = f["path"]?.listValue, !comps.isEmpty else {
                    throw ParseError.emptyPath
                }
                let parts = comps.compactMap { $0.stringValue }
                guard parts.count == comps.count else {
                    throw ParseError.missingField("files[].path component")
                }
                entries.append(
                    TorrentFileEntry(
                        path: ([name] + parts).joined(separator: "/"), length: fl, offset: running))
                running += fl
            }
        }
        files = entries
        totalLength = running

        announce = top["announce"]?.stringValue
        announceList =
            top["announce-list"]?.listValue?.compactMap {
                $0.listValue?.compactMap { $0.stringValue }
            } ?? []
        creationDate = top["creation date"]?.intValue.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        comment = top["comment"]?.stringValue
        createdBy = top["created by"]?.stringValue
    }

    /// Length of a given piece (the last piece is usually shorter).
    public func lengthOfPiece(_ index: Int) -> Int64 {
        guard index >= 0, index < pieceCount else { return 0 }
        return index < pieceCount - 1
            ? pieceLength : totalLength - pieceLength * Int64(pieceCount - 1)
    }
}
