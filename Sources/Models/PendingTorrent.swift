// PendingTorrent.swift — holds parsed file info pre-add

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
}

public struct PendingFile: Identifiable {
    public let id: Int
    public let path: String
    public let size: Int64
    public var priority: FilePriority = .normal

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var directory: String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return dir == "." ? "" : dir
    }
}
