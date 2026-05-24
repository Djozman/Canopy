// FilesTab.swift — recursive file tree with checkboxes and sorting

import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: FileTreeViewModel
    @State private var sortOrder: FileSortOrder = .nameAsc

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortButton("File", asc: .nameAsc, desc: .nameDesc,
                           sortOrder: $sortOrder, onSort: { vm.setSort($0) }, minWidth: 180)
                Divider().frame(height: 20)
                sortButton("Size", asc: .sizeAsc, desc: .sizeDesc,
                           sortOrder: $sortOrder, onSort: { vm.setSort($0) }, minWidth: 80)
                Divider().frame(height: 20)
                Text("Progress").frame(width: 80).font(.caption).foregroundStyle(.secondary)
                Divider().frame(height: 20)
                Text("Priority").frame(width: 70).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.roots) { node in
                        FileNodeRow(node: node, depth: 0, vm: vm)
                    }
                }
            }
        }
    }
}

// MARK: - Recursive Row

private struct FileNodeRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    let vm: FileTreeViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(depth) * 16)

                if node.isFolder {
                    // Large 32×32 tap target so the arrow is easy to hit
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { node.isExpanded.toggle() }
                    } label: {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)   // big tap target
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 32)
                }

                NativeCheckbox(state: node.checkState) {
                    vm.toggleCheck(node)
                }

                Image(systemName: node.isFolder ? "folder.fill" : fileIcon(node.name))
                    .foregroundStyle(node.isFolder ? Color.yellow : Color(nsColor: .secondaryLabelColor))
                    .font(.system(size: 12))

                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(Color(nsColor: .labelColor))

                Text(formatBytes(node.size))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 80, alignment: .trailing)

                ProgressView(value: node.progress)
                    .tint(barColor(node.progress))
                    .frame(width: 80)

                if !node.isFolder {
                    Menu {
                        ForEach(FilePriority.allCases, id: \.self) { p in
                            Button(p.label) { vm.setPriority(p, on: node) }
                        }
                    } label: {
                        Text(node.priority.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 70)
                } else {
                    Spacer().frame(width: 70)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())

            Divider().opacity(0.3)

            if node.isFolder, node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileNodeRow(node: child, depth: depth + 1, vm: vm)
                }
            }
        }
    }

    private func barColor(_ p: Double) -> Color {
        p >= 1 ? .green : p > 0 ? .blue : .secondary
    }
}
