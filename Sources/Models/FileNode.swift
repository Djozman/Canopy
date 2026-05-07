// FileNode.swift — tree node for the file list

import Foundation
import CanopyEngine

public final class FileNode: Identifiable, ObservableObject {
    public let id = UUID()

    public var name: String
    public var size: Int64
    public var downloaded: Int64
    public var fileIndex: Int?
    public var children: [FileNode]?

    @Published public var priority: FilePriority
    @Published public var isExpanded = false   // collapsed by default

    public var isFolder: Bool { children != nil }

    public var progress: Double {
        size > 0 ? Double(downloaded) / Double(size) : 0
    }

    public var checkState: CheckState {
        guard isFolder, let children else {
            return priority == .dontDownload ? .off : .on
        }
        let states = children.map(\.checkState)
        if states.allSatisfy({ $0 == .on  }) { return .on  }
        if states.allSatisfy({ $0 == .off }) { return .off }
        return .mixed
    }

    init(name: String, size: Int64 = 0, downloaded: Int64 = 0,
         fileIndex: Int? = nil, priority: FilePriority = .normal,
         children: [FileNode]? = nil) {
        self.name       = name
        self.size       = size
        self.downloaded = downloaded
        self.fileIndex  = fileIndex
        self.priority   = priority
        self.children   = children
    }
}

public enum CheckState { case on, mixed, off }
