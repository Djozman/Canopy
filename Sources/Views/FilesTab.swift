// FilesTab.swift — compact live file inspector

import Combine
import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: FileTreeViewModel
    @State private var expanded = false
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
                    withAnimation(.easeInOut(duration: 0.16)) {
                        vm.setAllExpanded(expanded)
                    }
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
                            FileInspectorRow(node: node, depth: 0, vm: vm)
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
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 14)

                if node.isFolder {
                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            node.isExpanded.toggle()
                        }
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
                        Text(node.name)
                            .font(.caption.weight(node.isFolder ? .medium : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(formatBytes(node.size))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
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
            .background(hovering ? Color.primary.opacity(0.045) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) {
                guard node.isFolder else { return }
                withAnimation(.easeInOut(duration: 0.14)) { node.isExpanded.toggle() }
            }

            Divider().opacity(0.35)

            if node.isFolder, node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileInspectorRow(node: child, depth: depth + 1, vm: vm)
                }
            }
        }
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
