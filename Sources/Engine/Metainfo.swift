import Foundation
import CryptoKit

struct FileEntry {
    let path: [String]
    let length: Int64

    var name: String { path.joined(separator: "/") }
}

struct Metainfo {
    let name: String
    let infoHash: Data        // 20-byte SHA1
    let pieceLength: Int
    let pieces: [Data]        // array of 20-byte SHA1 hashes
    let files: [FileEntry]
    let announceList: [[String]]
    let totalSize: Int64

    var isSingleFile: Bool { files.count == 1 && files[0].path.count == 1 }

    static func parse(_ data: Data) throws -> Metainfo {
        let root = try Bencode.decode(data)
        guard let info = root["info"],
              let name = info["name"]?.string,
              let pieceLenVal = info["piece length"]?.int,
              let piecesData = info["pieces"]?.data
        else { throw MetainfoError.missingField }

        // Build piece hashes
        guard piecesData.count % 20 == 0 else { throw MetainfoError.invalidPieces }
        let pieces = stride(from: 0, to: piecesData.count, by: 20).map {
            piecesData[$0..<($0 + 20)]
        }

        // Files
        let files: [FileEntry]
        if let fileList = info["files"]?.list {
            files = try fileList.map { f in
                guard let len = f["length"]?.int,
                      let pathList = f["path"]?.list
                else { throw MetainfoError.missingField }
                let parts = pathList.compactMap(\.string)
                return FileEntry(path: parts, length: Int64(len))
            }
        } else if let len = info["length"]?.int {
            files = [FileEntry(path: [name], length: Int64(len))]
        } else {
            throw MetainfoError.missingField
        }

        let totalSize = files.reduce(0) { $0 + $1.length }

        // Info hash (SHA1 of raw info bytes)
        guard let infoBytes = Bencode.infoBytes(data) else { throw MetainfoError.missingField }
        let hash = Insecure.SHA1.hash(data: infoBytes)
        let infoHash = Data(hash)

        // Announce list
        var announceList: [[String]] = []
        if let tiers = root["announce-list"]?.list {
            announceList = tiers.compactMap { tier in
                tier.list?.compactMap(\.string)
            }
        }
        if let single = root["announce"]?.string, announceList.isEmpty {
            announceList = [[single]]
        }

        return Metainfo(
            name: name,
            infoHash: infoHash,
            pieceLength: pieceLenVal,
            pieces: pieces.map { Data($0) },
            files: files,
            announceList: announceList,
            totalSize: totalSize
        )
    }
    
    // Synthesized init will be used

    // Construct Metainfo from raw BEP 9 info-dict bytes (already SHA1-verified by caller).
    static func fromInfoDict(_ infoBytes: Data, infoHash: Data, trackers: [[String]]) throws -> Metainfo {
        let info = try Bencode.decode(infoBytes)
        guard let name       = info["name"]?       .string,
              let pieceLenVal = info["piece length"]?.int,
              let piecesData  = info["pieces"]?     .data
        else { throw MetainfoError.missingField }

        guard piecesData.count % 20 == 0 else { throw MetainfoError.invalidPieces }
        let pieces = stride(from: 0, to: piecesData.count, by: 20).map { Data(piecesData[$0..<($0+20)]) }

        let files: [FileEntry]
        if let fileList = info["files"]?.list {
            files = try fileList.map { f in
                guard let len = f["length"]?.int, let pathList = f["path"]?.list else { throw MetainfoError.missingField }
                return FileEntry(path: pathList.compactMap(\.string), length: Int64(len))
            }
        } else if let len = info["length"]?.int {
            files = [FileEntry(path: [name], length: Int64(len))]
        } else { throw MetainfoError.missingField }

        return Metainfo(
            name: name, infoHash: infoHash,
            pieceLength: pieceLenVal, pieces: pieces,
            files: files, announceList: trackers,
            totalSize: files.reduce(0) { $0 + $1.length }
        )
    }

    static func forMagnet(infoHash: Data, name: String = "Unknown", trackers: [String] = []) -> Metainfo {
        return Metainfo(
            name: name,
            infoHash: infoHash,
            pieceLength: 0,
            pieces: [],
            files: [],
            announceList: trackers.isEmpty ? [] : [trackers],
            totalSize: 0
        )
    }
}

struct Magnet {
    let infoHash: Data
    let name: String?
    let trackers: [String]
    
    static func parse(_ uri: String) -> Magnet? {
        guard uri.hasPrefix("magnet:?") else { return nil }
        let params = uri.dropFirst(8).split(separator: "&")
        var hash: Data?
        var name: String?
        var trackers: [String] = []
        
        for param in params {
            let parts = param.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = String(parts[1]).replacingOccurrences(of: "%20", with: " ")
            
            if key == "xt" && val.hasPrefix("urn:btih:") {
                let hex = val.dropFirst(9)
                hash = Data(hex: String(hex))
            } else if key == "dn" {
                name = val
            } else if key == "tr" {
                trackers.append(val)
            }
        }
        
        guard let h = hash else { return nil }
        return Magnet(infoHash: h, name: name, trackers: trackers)
    }
}

extension Data {
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        for i in 0..<len {
            let j = hex.index(hex.startIndex, offsetBy: i * 2)
            let k = hex.index(j, offsetBy: 2)
            guard let byte = UInt8(hex[j..<k], radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }
}

enum MetainfoError: LocalizedError {
    case missingField, invalidPieces
    var errorDescription: String? {
        switch self {
        case .missingField: "Torrent file is missing required fields"
        case .invalidPieces: "Piece hash data is malformed"
        }
    }
}
