#!/usr/bin/env python3
"""
Canopy UI Polish — divider, file rows, instant expand, inline rename, selection
Run from: /Users/amm/Canopy-main
"""
import os

BASE = os.path.dirname(os.path.abspath(__file__))

def read(p):
    with open(os.path.join(BASE, p)) as f:
        return f.read()

def write(p, c):
    with open(os.path.join(BASE, p), 'w') as f:
        f.write(c)
    print(f"  ✅ {p}")

print("\n🔧 Canopy UI Polish\n")

# ══════════════════════════════════════════════════════════════════════
# 1. ContentView.swift — remove visible divider line, use invisible drag bar
# ══════════════════════════════════════════════════════════════════════
c = read('Sources/Views/ContentView.swift')

# Make divider invisible (no gray line)
c = c.replace(
    "layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor",
    "layer?.backgroundColor = NSColor.clear.cgColor"
)
# Increase drag hit area
c = c.replace(
    "let hitRect = NSRect(x: 0, y: -4.5, width: bounds.width, height: 10)",
    "let hitRect = NSRect(x: 0, y: -5, width: bounds.width, height: 11)"
)

write('Sources/Views/ContentView.swift', c)

# ══════════════════════════════════════════════════════════════════════
# 2. FilesTab.swift — full rewrite: instant expand, selection, inline rename
# ══════════════════════════════════════════════════════════════════════
write('Sources/Views/FilesTab.swift', r'''// FilesTab.swift — compact live file inspector

import AppKit
import Combine
import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: FileTreeViewModel
    @State private var expanded = false
    @State private var selectedNodeID: UUID?
    @State private var renamingNodeID: UUID?
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
            .frame(height: 34)
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
                                selectedNodeID: $selectedNodeID,
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
    @Binding var selectedNodeID: UUID?
    @Binding var renamingNodeID: UUID?
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { selectedNodeID == node.id }
    private var isRenaming: Bool { renamingNodeID == node.id }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 18)
            if node.isFolder {
                Button {
                    node.isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 22, height: 28)
            }
            NativeCheckbox(state: node.checkState) {
                vm.toggleCheck(node)
            }
            Image(systemName: node.isFolder ? "folder.fill" : fileIcon(node.name))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(node.isFolder ? CanopyPalette.warning : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isRenaming {
                        TextField("Name", text: Binding(
                            get: { node.name },
                            set: { node.name = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(.caption.weight(node.isFolder ? .medium : .regular))
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
                    if !isRenaming {
                        Text(formatBytes(node.size))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 7) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule()
                                .fill(progressColor)
                                .frame(width: geometry.size.width * node.progress)
                        }
                    }
                    .frame(height: 5)
                    Text(String(format: "%.1f%%", node.progress * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 39, alignment: .trailing)
                    if !node.isFolder {
                        priorityMenu
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            selectedNodeID = node.id
            if isRenaming { commitRename() }
        }
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
                    selectedNodeID = node.id
                    renamingNodeID = node.id
                    renameFocused = true
                }
            } else if node.isFolder {
                Button("Open in Finder") {
                    if let url = vm.fileURL(for: node) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        Divider().opacity(0.35)
        if node.isFolder, node.isExpanded, let children = node.children {
            ForEach(children) { child in
                FileInspectorRow(
                    node: child,
                    depth: depth + 1,
                    vm: vm,
                    selectedNodeID: $selectedNodeID,
                    renamingNodeID: $renamingNodeID
                )
            }
        }
    }

    private var rowBackground: Color {
        if isRenaming { return Color.accentColor.opacity(0.12) }
        if isSelected { return Color.accentColor.opacity(0.18) }
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
    }

    private var progressColor: Color {
        if node.progress >= 1 { return CanopyPalette.positive }
        if node.progress > 0 { return CanopyPalette.download }
        return Color.secondary.opacity(0.45)
    }
}
''')

print("\n📋 Changes:")
print("  1. Divider: invisible (no gray line), 11px drag hit area")
print("  2. Expand/collapse: instant (no withAnimation)")
print("  3. Indentation: 18px per depth (like Finder list view)")
print("  4. Selection: click to select, accent blue highlight")
print("  5. Inline rename: text field replaces name in-place")
print("  6. Double-click file: opens it directly")
print("\nBuild with: swift build")
