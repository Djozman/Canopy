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
                LazyVStack(spacing: 0) {
                    ForEach(vm.roots) { node in
                        FileNodeRow(node: node, depth: 0, vm: vm)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sortCol(_ title: String, min: CGFloat, asc: FileSortOrder, desc: FileSortOrder) -> some View {
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
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) { node.isExpanded.toggle() }
                        }
                } else {
                    Spacer().frame(width: 12)
                }

                TriStateCheckbox(state: node.checkState)
                    .onTapGesture { vm.toggleCheck(node) }

                Image(systemName: node.isFolder ? "folder.fill" : fileIcon(node.name))
                    .foregroundStyle(node.isFolder ? .yellow : .secondary)
                    .font(.system(size: 12))

                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(node.priority == .dontDownload ? Color.secondary : Color.primary)
                    .strikethrough(node.priority == .dontDownload)

                Text(formatBytes(node.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
        if p >= 1.0 { return .green }
        if p > 0    { return .blue  }
        return .secondary
    }
}

// MARK: - Tri-state Checkbox

private struct TriStateCheckbox: View {
    let state: CheckState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                .frame(width: 14, height: 14)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(state == .off ? Color.clear : Color.accentColor.opacity(0.15))
                )
            switch state {
            case .on:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            case .mixed:
                Rectangle().fill(Color.accentColor).frame(width: 8, height: 2)
            case .off:
                EmptyView()
            }
        }
        .frame(width: 14, height: 14)
    }
}

private func fileIcon(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "mkv", "mp4", "avi", "mov", "webm": return "film"
    case "mp3", "flac", "wav", "m4a":        return "music.note"
    case "iso", "img", "dmg":                return "opticaldisc"
    case "zip", "rar", "7z", "tar", "gz":    return "doc.zipper"
    case "txt", "md", "nfo":                 return "doc.text"
    case "jpg", "png", "gif", "webp":        return "photo"
    default:                                  return "doc"
    }
}
