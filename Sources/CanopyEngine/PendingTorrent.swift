import Foundation

public struct PendingTorrent {
    public enum Source {
        case file(path: String)
        case magnet(uri: String)
    }

    public let source: Source
    public var name: String
    public var totalSize: Int64
    public var savePath: String
    public var files: [PendingFile]

    public var isMagnet: Bool {
        if case .magnet = source { return true }
        return false
    }

    public init(source: Source, name: String, totalSize: Int64,
                savePath: String, files: [PendingFile]) {
        self.source = source
        self.name = name
        self.totalSize = totalSize
        self.savePath = savePath
        self.files = files
    }
}

public struct PendingFile: Identifiable {
    public let id: Int
    public let path: String
    public let size: Int64
    public var priority: FilePriority

    public init(id: Int, path: String, size: Int64, priority: FilePriority = .normal) {
        self.id = id
        self.path = path
        self.size = size
        self.priority = priority
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var directory: String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return dir == "." ? "" : dir
    }
}
