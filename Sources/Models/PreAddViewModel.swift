// PreAddViewModel.swift

import Combine
import Foundation

public enum RenameValidationError: Equatable, LocalizedError {
    case empty
    case illegalCharacter(Character)
    case duplicateSibling

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Name cannot be empty."
        case .illegalCharacter(let c):
            return "Name contains an illegal character: “\(c)”"
        case .duplicateSibling:
            return "A file or folder with this name already exists in this folder."
        }
    }
}

@MainActor
public final class PreAddViewModel: ObservableObject {
    @Published public var pending: PendingTorrent

    // Flat-to-tree conversion. Rebuilt when pending.files changes.
    @Published public private(set) var tree: [FileNode] = []
    @Published public var errorMessage: String?
    @Published public var renameErrorMessage: String?

    // A synthetic root node whose checkState aggregates the whole tree.
    // Not displayed — used only for the select-all header checkbox.
    public private(set) var treeRoot: FileNode?

    public init(pending: PendingTorrent) {
        self.pending = pending
        rebuildTree()
    }

    /// True when the torrent is a single-file torrent (no wrapping folder).
    public var isSingleFile: Bool {
        pending.files.count <= 1
    }

    /// The current display name of the root folder (first top-level folder).
    public var treeRootName: String {
        tree.first(where: { $0.isFolder })?.name ?? pending.name
    }

    /// Renames the torrent's root folder (the single top-level folder that
    /// wraps a multi-file torrent). No-op for single-file torrents.
    /// PRE-INSTALL ONLY — see `rename(node:to:)`.
    @discardableResult
    public func renameRootFolder(to newName: String) -> RenameValidationError? {
        guard !isSingleFile, let root = tree.first(where: { $0.isFolder }) else {
            return nil
        }
        return rename(node: root, to: newName)
    }

    // MARK: - Tree building
    //
    // PendingFile.path is a relative path like
    //   "Show.S01/Episode01.mkv"
    //   "Show.S01/Episode02.mkv"
    //   "extras/bonus.mp4"
    //   "readme.txt"
    //
    // We split on "/" and build a folder tree, then attach each leaf
    // to its FileNode so priority syncs back to pending.files.

    public func rebuildTree() {
        let root = buildTree(from: pending.files)
        treeRoot = root
        tree = root.children ?? []
    }

    private func buildTree(from files: [PendingFile]) -> FileNode {
        let root = FileNode(name: "__root__", children: [])

        for file in files {
            let components = file.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)

            guard !components.isEmpty else { continue }

            var current = root
            // Walk / create folder nodes for all but the last component
            for folderName in components.dropLast() {
                if let existing = current.children?.first(where: { $0.name == folderName && $0.isFolder }) {
                    current = existing
                } else {
                    let folder = FileNode(name: folderName, children: [])
                    current.children?.append(folder)
                    current.size += file.size   // will be corrected below
                    current = folder
                }
            }

            // Leaf file node
            let leaf = FileNode(
                name:      components.last!,
                size:      file.size,
                fileIndex: file.id,
                priority:  file.priority
            )
            current.children?.append(leaf)
        }

        // Recompute folder sizes bottom-up
        recomputeSizes(root)
        return root
    }

    @discardableResult
    private func recomputeSizes(_ node: FileNode) -> Int64 {
        guard node.isFolder, let children = node.children else { return node.size }
        let total = children.reduce(0) { $0 + recomputeSizes($1) }
        node.size = total
        return total
    }

    // MARK: - Rename (validation + path cascade)

    /// Validates a proposed new name for a node within its containing folder.
    /// Rejects empty names and names containing the illegal filename
    /// characters `/`, `\`, `:`, and control characters.
    /// - Parameter parent: the node's containing folder; used to check for
    ///   sibling collisions. Passing nil skips the sibling check.
    public func validateRename(_ newName: String, in parent: FileNode?) -> RenameValidationError? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        // Reject '/', '\\', ':' and other characters illegal in macOS filenames.
        let illegal = CharacterSet(charactersIn: "/\\:\u{0}")
            .union(.controlCharacters)
        if let first = trimmed.unicodeScalars.first(where: { illegal.contains($0) }) {
            return .illegalCharacter(Character(first))
        }
        return nil
    }

    /// Renames a node (folder or file) to a new name. Validates first and, on
    /// success, updates the node name and cascades path changes into
    /// `pending.files`. Returns nil on success, or a validation error.
    ///
    /// PRE-INSTALL ONLY: this mutator is reachable solely through the
    /// pre-install review flow and MUST NOT be called on torrents already
    /// downloading or seeding (constitution VI design intent).
    /// - Returns: `RenameValidationError?` — nil on success.
    @discardableResult
    public func rename(node: FileNode, to newName: String) -> RenameValidationError? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = validateRename(trimmed, in: nil) { return error }

        // Sibling collision: node collides with a sibling of the same type
        // (file vs file, folder vs folder) in its containing folder.
        if let parent = parentNode(of: node),
           parent.children?.contains(where: {
               $0 !== node && $0.name == trimmed && $0.isFolder == node.isFolder
           }) == true {
            return .duplicateSibling
        }

        node.name = trimmed
        syncFilePathsFromTree()
        return nil
    }

    /// Computes the file-index → new-relative-path map from the current tree.
    /// Paths are rebuilt from each leaf's ancestor names, so folder renames
    /// cascade automatically. Rebuilds the tree state, then writes every leaf
    /// path back into `pending.files`.
    ///
    /// This is the canonical ViewModel-side resolver. On confirm, the engine
    /// reads the (already-synced) `pending.files` paths rather than calling
    /// this again, so a caller (e.g. the sheet) should invoke it once before
    /// handing `pending` to the engine.
    public func buildRenamedFiles() -> [Int: String] {
        syncFilePathsFromTree()
        var map: [Int: String] = [:]
        for f in pending.files { map[f.id] = f.path }
        return map
    }

    /// Rebuilds each leaf's relative path from its ancestor names and writes
    /// them back into `pending.files` keyed by stable file index.
    private func syncFilePathsFromTree() {
        guard let root = treeRoot else { return }
        var paths: [Int: String] = [:]
        collectLeafPaths(root, prefix: "", into: &paths)
        for i in pending.files.indices {
            if let p = paths[pending.files[i].id] {
                pending.files[i].path = p
            }
        }
    }

    private func collectLeafPaths(_ node: FileNode, prefix: String, into map: inout [Int: String]) {
        if let idx = node.fileIndex {
            map[idx] = prefix
            return
        }
        guard let children = node.children else { return }
        for child in children {
            let newPrefix = prefix.isEmpty ? child.name : prefix + "/" + child.name
            collectLeafPaths(child, prefix: newPrefix, into: &map)
        }
    }

    /// Returns the containing folder node for a given node, or nil for the
    /// root. Used to validate sibling collisions during rename.
    private func parentNode(of node: FileNode) -> FileNode? {
        guard let root = treeRoot else { return nil }
        var queue: [FileNode] = [root]
        while let current = queue.popLast() {
            guard let children = current.children else { continue }
            if children.contains(where: { $0 === node }) { return current }
            queue.append(contentsOf: children)
        }
        return nil
    }

    // MARK: - Priority sync (tree → flat)
    //
    // After any node.priority change, walk the tree and copy leaf priorities
    // back into pending.files so onConfirm sends correct data to libtorrent.

    public func syncFilePriorities() {
        guard let root = treeRoot else { return }
        var map: [Int: FilePriority] = [:]
        collectLeafPriorities(root, into: &map)
        for i in pending.files.indices {
            if let p = map[pending.files[i].id] {
                pending.files[i].priority = p
            }
        }
    }

    private func collectLeafPriorities(_ node: FileNode, into map: inout [Int: FilePriority]) {
        if let idx = node.fileIndex {
            map[idx] = node.priority
            return
        }
        node.children?.forEach { collectLeafPriorities($0, into: &map) }
    }

    // MARK: - Folder checkbox
    //
    // Setting a folder’s priority recursively sets all leaf descendants.

    public func setFolderPriority(node: FileNode, priority: FilePriority) {
        setAllLeaves(node, priority: priority)
        syncFilePriorities()
    }

    private func setAllLeaves(_ node: FileNode, priority: FilePriority) {
        if node.fileIndex != nil {
            node.priority = priority
            return
        }
        node.children?.forEach { setAllLeaves($0, priority: priority) }
    }

    // MARK: - Select all toggle

    public func toggleAll() {
        let current = treeRoot?.checkState ?? .on
        let newPrio: FilePriority = current == .on ? .dontDownload : .normal
        if let root = treeRoot { setAllLeaves(root, priority: newPrio) }
        syncFilePriorities()
    }

    // MARK: - Sort (re-sorts root children)

    public func sort(by order: FileSortOrder) {
        guard let root = treeRoot else { return }
        sortChildren(of: root, order: order)
        tree = root.children ?? []
    }

    private func sortChildren(of node: FileNode, order: FileSortOrder) {
        guard var children = node.children else { return }
        switch order {
        case .nameAsc:  children.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDesc: children.sort { $0.name.localizedCompare($1.name) == .orderedDescending }
        case .sizeAsc:  children.sort { $0.size < $1.size }
        case .sizeDesc: children.sort { $0.size > $1.size }
        case .progressAsc: children.sort { $0.progress < $1.progress }
        case .progressDesc: children.sort { $0.progress > $1.progress }
        case .priorityAsc: children.sort { $0.priority.rawValue < $1.priority.rawValue }
        case .priorityDesc: children.sort { $0.priority.rawValue > $1.priority.rawValue }
        }
        node.children = children
        children.forEach { sortChildren(of: $0, order: order) }
    }
}
