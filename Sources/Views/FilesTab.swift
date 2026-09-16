// FilesTab.swift — compact live file inspector

import AppKit
import Combine
import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: FileTreeViewModel
    @State private var expanded = false
    @State private var selectedNodeIDs: Set<UUID> = []
    @State private var renamingNodeID: UUID?
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(leafCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    sortItem("Name", ascending: .nameAsc, descending: .nameDesc)
                    sortItem("Size", ascending: .sizeAsc, descending: .sizeDesc)
                    sortItem("Progress", ascending: .progressAsc, descending: .progressDesc)
                    sortItem("Priority", ascending: .priorityAsc, descending: .priorityDesc)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button {
                    expanded.toggle()
                    vm.setAllExpanded(expanded)
                } label: {
                    Image(systemName: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Collapse all folders" : "Expand all folders")
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(CanopyPalette.surface)
            Divider()
            if vm.roots.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for file metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.roots) { node in
                            FileInspectorRow(
                                node: node,
                                depth: 0,
                                vm: vm,
                                selectedNodeIDs: $selectedNodeIDs,
                                renamingNodeID: $renamingNodeID
                            )
                        }
                    }
                }
            }
        }
        .onReceive(refreshTimer) { _ in vm.refresh() }
    }

    @ViewBuilder
    private func sortItem(
        _ label: String,
        ascending: FileSortOrder,
        descending: FileSortOrder
    ) -> some View {
        Button {
            vm.setSort(vm.sortOrder == ascending ? descending : ascending)
        } label: {
            if vm.sortOrder == ascending {
                Label("\(label) — Ascending", systemImage: "checkmark")
            } else if vm.sortOrder == descending {
                Label("\(label) — Descending", systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private var leafCount: Int {
        func count(_ nodes: [FileNode]) -> Int {
            nodes.reduce(0) { partial, node in
                partial + (node.children.map(count) ?? 1)
            }
        }
        return count(vm.roots)
    }
}

private struct FileInspectorRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    let vm: FileTreeViewModel
    @Binding var selectedNodeIDs: Set<UUID>
    @Binding var renamingNodeID: UUID?
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { selectedNodeIDs.contains(node.id) }
    private var isRenaming: Bool { renamingNodeID == node.id }

    var body: some View {
        // Single-line row — like qBittorrent's QTreeView with uniform row heights
        HStack(spacing: 6) {
            // Indentation
            Color.clear.frame(width: CGFloat(depth) * 16)

            // Expand/collapse chevron
            if node.isFolder {
                Button {
                    node.isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 20)
            }

            // Checkbox
            NativeCheckbox(state: node.checkState) {
                vm.toggleCheck(node)
            }

            // File/folder icon
            Image(systemName: node.isFolder ? "folder.fill" : fileIcon(node.name))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(node.isFolder ? CanopyPalette.warning : Color.secondary)
                .frame(width: 14)

            // Name (with inline rename)
            if isRenaming {
                TextField("Name", text: Binding(
                    get: { node.name },
                    set: { node.name = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
            } else {
                Text(node.name)
                    .font(.caption.weight(node.isFolder ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Progress bar (compact, fixed width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(progressColor)
                    .frame(width: 60 * node.progress)
            }
            .frame(width: 60, height: 4)

            // Progress percentage
            Text(String(format: "%.0f%%", node.progress * 100))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            // Size
            Text(formatBytes(node.size))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            // Priority (files only)
            if !node.isFolder {
                priorityMenu
            } else {
                Color.clear.frame(width: 50)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) { handleSelect() }
        .onTapGesture(count: 2) {
            if node.isFolder {
                node.isExpanded.toggle()
            } else {
                if let url = vm.fileURL(for: node) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .contextMenu {
            if !node.isFolder, node.fileIndex != nil {
                Button("Open") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Open in Finder") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Divider()
                Button("Rename") {
                    selectedNodeIDs = [node.id]
                    renamingNodeID = node.id
                    renameFocused = true
                }
            } else if node.isFolder {
                Button("Open in Finder") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Rename") {
                    selectedNodeIDs = [node.id]
                    renamingNodeID = node.id
                    renameFocused = true
                }
            }
        }
        Divider().opacity(0.3)
        if node.isFolder, node.isExpanded, let children = node.children {
            ForEach(children) { child in
                FileInspectorRow(
                    node: child,
                    depth: depth + 1,
                    vm: vm,
                    selectedNodeIDs: $selectedNodeIDs,
                    renamingNodeID: $renamingNodeID
                )
            }
        }
    }

    private func handleSelect() {
        if isRenaming {
            commitRename()
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            if selectedNodeIDs.contains(node.id) {
                selectedNodeIDs.remove(node.id)
            } else {
                selectedNodeIDs.insert(node.id)
            }
        } else {
            selectedNodeIDs = [node.id]
        }
    }

    private var rowBackground: Color {
        if isRenaming { return Color.accentColor.opacity(0.15) }
        if isSelected { return Color.accentColor.opacity(0.20) }
        return Color.clear
    }

    private func commitRename() {
        let newName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && renamingNodeID != nil {
            vm.renameFile(newName, on: node)
        }
        renamingNodeID = nil
        renameFocused = false
    }

    private func cancelRename() {
        renamingNodeID = nil
        renameFocused = false
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(FilePriority.allCases, id: \.self) { priority in
                Button {
                    vm.setPriority(priority, on: node)
                } label: {
                    if priority == node.priority {
                        Label(priority.label, systemImage: "checkmark")
                    } else {
                        Text(priority.label)
                    }
                }
            }
        } label: {
            Text(node.priority.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 50)
    }

    private var progressColor: Color {
        if node.progress >= 1 { return CanopyPalette.positive }
        if node.progress > 0 { return CanopyPalette.download }
        return Color.secondary.opacity(0.45)
    }
}
