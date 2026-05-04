// FilesTab.swift — recursive file tree with checkboxes and sorting

import SwiftUI

struct FilesTab: View {
    @ObservedObject var vm: FileTreeViewModel
    @State private var sortOrder: FileSortOrder = .nameAsc

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortCol("File",     min: 180, asc: .nameAsc, desc: .nameDesc)
                Divider().frame(height: 20)
                sortCol("Size",     min: 80,  asc: .sizeAsc, desc: .sizeDesc)
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

    @ViewBuilder
    private func sortCol(_ title: String, min: CGFloat,
                         asc: FileSortOrder, desc: FileSortOrder) -> some View {
        Button {
            sortOrder = (sortOrder == asc) ? desc : asc
            vm.setSort(sortOrder)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if sortOrder == asc {
                    Image(systemName: "chevron.up").font(.system(size: 8))
                } else if sortOrder == desc {
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }
            .frame(minWidth: min, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
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

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mkv","mp4","avi","mov","webm": return "film"
        case "mp3","flac","wav","m4a":       return "music.note"
        case "iso","img","dmg":              return "opticaldisc"
        case "zip","rar","7z","tar","gz":   return "doc.zipper"
        case "txt","md","nfo":              return "doc.text"
        case "jpg","png","gif","webp":      return "photo"
        default:                              return "doc"
        }
    }
}

// MARK: - TriStateCheckbox alias (kept for backward compat)
struct TriStateCheckbox: View {
    let state: CheckState
    var action: () -> Void = {}
    var body: some View { NativeCheckbox(state: state, action: action) }
}

// MARK: - NativeCheckbox
struct NativeCheckbox: NSViewRepresentable {
    let state: CheckState
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let btn = NSButton(checkboxWithTitle: "", target: context.coordinator,
                           action: #selector(Coordinator.tapped))
        btn.allowsMixedState = true
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentHuggingPriority(.required, for: .vertical)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        context.coordinator.action = action
        btn.state = state == .on ? .on : state == .off ? .off : .mixed
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}
