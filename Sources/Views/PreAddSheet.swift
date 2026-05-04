// PreAddSheet.swift — file selection before adding torrent

import SwiftUI

// MARK: - Sheet

struct PreAddSheet: View {
    @ObservedObject var model: PreAddViewModel
    let onConfirm: (PendingTorrent) -> Void
    let onCancel: () -> Void

    @State private var sortOrder: FileSortOrder = .nameAsc

    private var pending: PendingTorrent { model.pending }

    // Root nodes of the folder tree
    private var rootNodes: [FileNode] { model.tree }

    private var allState: CheckState { model.treeRoot?.checkState ?? .on }

    private var selectedSize: Int64 {
        model.pending.files
            .filter { $0.priority != .dontDownload }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.name)
                        .font(.headline)
                        .foregroundColor(Color(nsColor: .labelColor))
                        .lineLimit(1)
                    Text(formatBytes(pending.totalSize))
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                Spacer()
            }
            .padding()

            Divider()

            // ── Save path
            HStack {
                Text("Save to:")
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                Text(pending.savePath)
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        model.pending.savePath = url.path
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // ── Spinner or tree
            if pending.isMagnet && pending.files.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching metadata\u{2026}")
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Column header row
                HStack(spacing: 0) {
                    Button { model.toggleAll() } label: {
                        TriStateCheckbox(state: allState)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)

                    sortButton("File", asc: .nameAsc,  desc: .nameDesc,  minWidth: 240)
                    Divider().frame(height: 20)
                    sortButton("Size", asc: .sizeAsc,  desc: .sizeDesc,  minWidth: 80)
                    Divider().frame(height: 20)
                    Text("Priority")
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 90)
                }
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Tree list
                List {
                    ForEach(rootNodes) { node in
                        FileTreeRow(node: node, depth: 0, model: model)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 28)
            }

            Divider()

            // ── Bottom bar
            HStack(spacing: 12) {
                Button { model.toggleAll() } label: {
                    HStack(spacing: 6) {
                        TriStateCheckbox(state: allState)
                        Text("Select all")
                            .font(.caption)
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                }
                .buttonStyle(.plain)

                Spacer()
                Text(formatBytes(selectedSize) + " selected")
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                Spacer()

                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.escape)

                Button("Add Torrent") { onConfirm(pending) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.isMagnet && pending.files.isEmpty)
            }
            .padding()
        }
    }

    // MARK: - Sort header button

    @ViewBuilder
    private func sortButton(_ title: String, asc: FileSortOrder,
                             desc: FileSortOrder, minWidth: CGFloat) -> some View {
        Button {
            sortOrder = sortOrder == asc ? desc : asc
            model.sort(by: sortOrder)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                if sortOrder == asc   { Image(systemName: "chevron.up").font(.system(size: 8)) }
                else if sortOrder == desc { Image(systemName: "chevron.down").font(.system(size: 8)) }
            }
            .frame(minWidth: minWidth, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tree row (recursive)

private struct FileTreeRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    @ObservedObject var model: PreAddViewModel

    var body: some View {
        // Folder row
        if node.isFolder {
            // Disclosure
            HStack(spacing: 4) {
                // indent
                indentSpacer

                Button {
                    node.isExpanded.toggle()
                } label: {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                // Folder checkbox
                Button {
                    let newPrio: FilePriority = node.checkState == .on ? .dontDownload : .normal
                    model.setFolderPriority(node: node, priority: newPrio)
                } label: {
                    TriStateCheckbox(state: node.checkState)
                }
                .buttonStyle(.plain)

                Image(systemName: node.isExpanded ? "folder.fill" : "folder")
                    .foregroundColor(.yellow)
                    .font(.system(size: 12))

                Text(node.name)
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .labelColor))
                    .lineLimit(1)

                Spacer()

                Text(formatBytes(node.size))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 80, alignment: .trailing)

                // No priority picker for folders — use checkbox
                Color.clear.frame(width: 90)
            }
            .frame(height: 26)
            .contentShape(Rectangle())

            // Children
            if node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeRow(node: child, depth: depth + 1, model: model)
                }
            }

        } else {
            // File row
            HStack(spacing: 6) {
                indentSpacer
                Color.clear.frame(width: 14) // align with folder chevron

                Button {
                    node.priority = node.priority == .dontDownload ? .normal : .dontDownload
                    model.syncFilePriorities()
                } label: {
                    TriStateCheckbox(state: node.priority == .dontDownload ? .off : .on)
                }
                .buttonStyle(.plain)

                Image(systemName: fileIcon(node.name))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .font(.system(size: 12))

                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(
                        node.priority == .dontDownload
                        ? Color(nsColor: .secondaryLabelColor)
                        : Color(nsColor: .labelColor)
                    )
                    .strikethrough(node.priority == .dontDownload)

                Spacer()

                Text(formatBytes(node.size))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 80, alignment: .trailing)

                Menu {
                    ForEach(FilePriority.allCases, id: \.self) { p in
                        Button(p.label) {
                            node.priority = p
                            model.syncFilePriorities()
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(node.priority.label)
                            .font(.caption)
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                .frame(width: 90)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
        }
    }

    private var indentSpacer: some View {
        Color.clear.frame(width: CGFloat(depth) * 16 + 4)
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
