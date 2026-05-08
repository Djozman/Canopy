import Foundation

public enum TorrentParseError: Error {
    case fileNotFound(String)
    case invalidBencode
    case missingField(String)
    case invalidFormat(String)
}

public struct TorrentParser {

    public static func parse(path: String) throws -> TorrentFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw TorrentParseError.fileNotFound(path)
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> TorrentFile {
        let (value, _) = try BencodeDecoder.decode(data)
        guard case .dict(let root) = value else {
            throw TorrentParseError.invalidBencode
        }

        let announceStr: String? = {
            guard let a = root.first(where: { $0.0 == "announce" }),
                  case .string(let d) = a.1 else { return nil }
            return String(data: d, encoding: .utf8)
        }()

        let announceList: [[String]]? = {
            guard let al = root.first(where: { $0.0 == "announce-list" }),
                  case .list(let tiers) = al.1 else { return nil }
            return tiers.compactMap { tier -> [String]? in
                guard case .list(let urls) = tier else { return nil }
                return urls.compactMap { url -> String? in
                    guard case .string(let d) = url else { return nil }
                    return String(data: d, encoding: .utf8)
                }
            }
        }()

        guard let infoPair = root.first(where: { $0.0 == "info" }),
              case .dict(let infoDict) = infoPair.1 else {
            throw TorrentParseError.missingField("info")
        }

        guard let namePair = infoDict.first(where: { $0.0 == "name" }),
              case .string(let nameData) = namePair.1,
              let name = String(data: nameData, encoding: .utf8) else {
            throw TorrentParseError.missingField("name")
        }

        guard let plPair = infoDict.first(where: { $0.0 == "piece length" }),
              case .integer(let pieceLength) = plPair.1 else {
            throw TorrentParseError.missingField("piece length")
        }

        guard let piecesPair = infoDict.first(where: { $0.0 == "pieces" }),
              case .string(let piecesData) = piecesPair.1 else {
            throw TorrentParseError.missingField("pieces")
        }

        guard piecesData.count % 20 == 0, !piecesData.isEmpty else {
            throw TorrentParseError.invalidFormat("pieces length must be a multiple of 20 bytes")
        }
        let pieces: [Data] = stride(from: 0, to: piecesData.count, by: 20).map {
            piecesData.subdata(in: $0..<min($0 + 20, piecesData.count))
        }
        let isPrivate: Bool = {
            guard let priv = infoDict.first(where: { $0.0 == "private" }),
                  case .integer(let v) = priv.1 else { return false }
            return v == 1
        }()

        let files: [TorrentFile.FileEntry]
        if let lengthPair = infoDict.first(where: { $0.0 == "length" }),
           case .integer(let length) = lengthPair.1 {
            files = [TorrentFile.FileEntry(path: name, size: length)]
        } else if let filesPair = infoDict.first(where: { $0.0 == "files" }),
                  case .list(let fileList) = filesPair.1 {
            // BEP 3: multi-file torrents store files under a directory named `name`
            files = try fileList.map { entry in
                guard case .dict(let fd) = entry else {
                    throw TorrentParseError.invalidFormat("files entry not a dict")
                }
                guard let len = fd.first(where: { $0.0 == "length" }),
                      case .integer(let size) = len.1 else {
                    throw TorrentParseError.missingField("files[].length")
                }
                guard let pathEl = fd.first(where: { $0.0 == "path" }),
                      case .list(let comps) = pathEl.1 else {
                    throw TorrentParseError.missingField("files[].path")
                }
                let relPath = comps.compactMap { comp -> String? in
                    guard case .string(let d) = comp else { return nil }
                    return String(data: d, encoding: .utf8)
                }.joined(separator: "/")
                guard !relPath.isEmpty else {
                    throw TorrentParseError.invalidFormat("empty file path")
                }
                return TorrentFile.FileEntry(path: name + "/" + relPath, size: size)
            }
        } else {
            throw TorrentParseError.missingField("length or files")
        }

        let totalSize = files.reduce(0) { $0 + $1.size }

        // Compute info hash from raw byte range
        let infoHash: Data
        if let infoRange = infoRange(in: data) {
            infoHash = SHA1.hash(data[infoRange])
        } else {
            // Fallback: re-encode the info dict (less reliable but works)
            let encoded = BencodeEncoder.encode(.dict(infoDict.map { ($0.0, $0.1) }))
            infoHash = SHA1.hash(encoded)
        }

        // Raw info dict for ut_metadata serving
        let rawInfo: Data? = {
            if let r = infoRange(in: data) { return data[r] }
            return nil
        }()

        return TorrentFile(
            announce: announceStr,
            announceList: announceList,
            name: name,
            pieceLength: pieceLength,
            pieces: pieces,
            files: files,
            infoHash: infoHash,
            totalSize: totalSize,
            isPrivate: isPrivate,
            rawInfoDict: rawInfo
        )
    }

    /// Parse an already-verified info dict (from magnet metadata download).
    /// rawBytes is the bencoded info dict; caller has already verified SHA1(rawBytes) == infoHash.
    public static func parse(infoDict rawBytes: Data) throws -> TorrentFile {
        let (value, _) = try BencodeDecoder.decode(rawBytes)
        guard case .dict(let infoDict) = value else {
            throw TorrentParseError.invalidBencode
        }

        guard let namePair = infoDict.first(where: { $0.0 == "name" }),
              case .string(let nameData) = namePair.1,
              let name = String(data: nameData, encoding: .utf8) else {
            throw TorrentParseError.missingField("name")
        }

        guard let plPair = infoDict.first(where: { $0.0 == "piece length" }),
              case .integer(let pieceLength) = plPair.1 else {
            throw TorrentParseError.missingField("piece length")
        }

        guard let piecesPair = infoDict.first(where: { $0.0 == "pieces" }),
              case .string(let piecesData) = piecesPair.1 else {
            throw TorrentParseError.missingField("pieces")
        }
        guard piecesData.count % 20 == 0, !piecesData.isEmpty else {
            throw TorrentParseError.invalidFormat("pieces length must be a multiple of 20 bytes")
        }
        let pieces: [Data] = stride(from: 0, to: piecesData.count, by: 20).map {
            piecesData.subdata(in: $0..<min($0 + 20, piecesData.count))
        }

        let isPrivate: Bool = {
            guard let priv = infoDict.first(where: { $0.0 == "private" }),
                  case .integer(let v) = priv.1 else { return false }
            return v == 1
        }()

        let files: [TorrentFile.FileEntry]
        if let lengthPair = infoDict.first(where: { $0.0 == "length" }),
           case .integer(let length) = lengthPair.1 {
            files = [TorrentFile.FileEntry(path: name, size: length)]
        } else if let filesPair = infoDict.first(where: { $0.0 == "files" }),
                   case .list(let fileList) = filesPair.1 {
            files = try fileList.map { entry in
                guard case .dict(let fd) = entry else {
                    throw TorrentParseError.invalidFormat("files entry not a dict")
                }
                guard let len = fd.first(where: { $0.0 == "length" }),
                      case .integer(let size) = len.1 else {
                    throw TorrentParseError.missingField("files[].length")
                }
                guard let pathEl = fd.first(where: { $0.0 == "path" }),
                      case .list(let comps) = pathEl.1 else {
                    throw TorrentParseError.missingField("files[].path")
                }
                let path = comps.compactMap { comp -> String? in
                    guard case .string(let d) = comp else { return nil }
                    return String(data: d, encoding: .utf8)
                }.joined(separator: "/")
                guard !path.isEmpty else {
                    throw TorrentParseError.invalidFormat("empty file path")
                }
                return TorrentFile.FileEntry(path: path, size: size)
            }
        } else {
            throw TorrentParseError.missingField("length or files")
        }

        let totalSize = files.reduce(0) { $0 + $1.size }
        let infoHash = SHA1.hash(rawBytes)

        return TorrentFile(
            announce: nil,
            announceList: nil,
            name: name,
            pieceLength: pieceLength,
            pieces: pieces,
            files: files,
            infoHash: infoHash,
            totalSize: totalSize,
            isPrivate: isPrivate,
            rawInfoDict: rawBytes
        )
    }

    /// Find the byte range of the "info" dictionary within the raw .torrent data.
    /// Returns nil if the range can't be determined (use re-encode fallback).
    private static func infoRange(in data: Data) -> Range<Int>? {
        var index = data.startIndex
        guard index < data.endIndex, data[index] == UInt8(ascii: "d") else { return nil }

        func skipValue(from i: inout Data.Index) -> Bool {
            guard i < data.endIndex else { return false }
            switch data[i] {
            case UInt8(ascii: "i"):
                i = data.index(after: i)
                while i < data.endIndex, data[i] != UInt8(ascii: "e") {
                    i = data.index(after: i)
                }
                guard i < data.endIndex else { return false }
                i = data.index(after: i)
            case UInt8(ascii: "l"):
                i = data.index(after: i)
                while i < data.endIndex, data[i] != UInt8(ascii: "e") {
                    guard skipValue(from: &i) else { return false }
                }
                guard i < data.endIndex else { return false }
                i = data.index(after: i)
            case UInt8(ascii: "d"):
                i = data.index(after: i)
                while i < data.endIndex, data[i] != UInt8(ascii: "e") {
                    guard skipValue(from: &i) else { return false }
                    guard skipValue(from: &i) else { return false }
                }
                guard i < data.endIndex else { return false }
                i = data.index(after: i)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let start = i
                while i < data.endIndex, data[i] != UInt8(ascii: ":") {
                    i = data.index(after: i)
                }
                guard i < data.endIndex else { return false }
                guard let len = Int(String(data: data[start..<i], encoding: .ascii) ?? "") else { return false }
                i = data.index(after: i)
                guard let newI = data.index(i, offsetBy: len, limitedBy: data.endIndex) else { return false }
                i = newI
            default:
                return false
            }
            return true
        }

        // Skip opening 'd'
        index = data.index(after: index)

        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            // Read key
            let keyStart = index
            while index < data.endIndex, data[index] != UInt8(ascii: ":") {
                index = data.index(after: index)
            }
            guard index < data.endIndex else { return nil }
            guard let keyLen = Int(String(data: data[keyStart..<index], encoding: .ascii) ?? "") else { return nil }
            index = data.index(after: index)
            guard let keyEnd = data.index(index, offsetBy: keyLen, limitedBy: data.endIndex) else { return nil }
            let key = String(data: data[index..<keyEnd], encoding: .ascii)
            index = keyEnd

            let valueStart = index
            guard skipValue(from: &index) else { return nil }

            if key == "info" {
                return valueStart..<index
            }
        }
        return nil
    }
}
