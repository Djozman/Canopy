// PreAddSheet.swift — file selection before adding torrent

import SwiftUI

// MARK: - Sheet

struct PreAddSheet: View {
    @ObservedObject var model: PreAddViewModel
    let onConfirm: (PendingTorrent) -> Void
    let onCancel: () -> Void

    @State private var sortOrder: FileSortOrder = .nameAsc

    private var pending: PendingTorrent { model.pending }
    private var rootNodes: [FileNode]   { model.tree }
    private var allState: CheckState    { model.treeRoot?.checkState ?? .on }

    private var selectedSize: Int64 {
        pending.files.filter { $0.priority != .dontDownload }.reduce(0) { $0 + $1.size }
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
                // Column header
                HStack(spacing: 0) {
                    NativeCheckbox(state: allState) { model.toggleAll() }
                        .padding(.horizontal, 8)

                    sortButton("File", asc: .nameAsc, desc: .nameDesc, minWidth: 240)
                    Divider().frame(height: 20)
                    sortButton("Size", asc: .sizeAsc, desc: .sizeDesc, minWidth: 80)
                    Divider().frame(height: 20)
                    Text("Priority")
                        .font(.caption)
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 90)
                }
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List {
                    ForEach(rootNodes) { node in
                        PreAddTreeRow(node: node, depth: 0, model: model)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 28)
            }

            Divider()

            // ── Bottom bar
            HStack(spacing: 12) {
                NativeCheckbox(state: allState) { model.toggleAll() }
                Text("Select all")
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))

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

    @ViewBuilder
    private func sortButton(_ title: String, asc: FileSortOrder,
                             desc: FileSortOrder, minWidth: CGFloat) -> some View {
        Button {
            sortOrder = sortOrder == asc ? desc : asc
            model.sort(by: sortOrder)
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundColor(Color(nsColor: .secondaryLabelColor))
                if sortOrder == asc        { Image(systemName: "chevron.up").font(.system(size: 8)) }
                else if sortOrder == desc  { Image(systemName: "chevron.down").font(.system(size: 8)) }
            }
            .frame(minWidth: minWidth, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tree row (recursive)

private struct PreAddTreeRow: View {
    @ObservedObject var node: FileNode
    let depth: Int
    @ObservedObject var model: PreAddViewModel

    var body: some View {
        if node.isFolder {
            folderRow
            if node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    PreAddTreeRow(node: child, depth: depth + 1, model: model)
                }
            }
        } else {
            fileRow
        }
    }

    // MARK: Folder row
    private var folderRow: some View {
        HStack(spacing: 4) {
            indentSpacer

            // 32×32 tap target — easy to click even on small arrows
            Button {
                node.isExpanded.toggle()
            } label: {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NativeCheckbox(state: node.checkState) {
                let newPrio: FilePriority = node.checkState == .on ? .dontDownload : .normal
                model.setFolderPriority(node: node, priority: newPrio)
            }

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

            Color.clear.frame(width: 90)
        }
        .frame(height: 32)
        .contentShape(Rectangle())
    }

    // MARK: File row
    private var fileRow: some View {
        HStack(spacing: 6) {
            indentSpacer
            // Spacer matching the 32pt arrow button width
            Color.clear.frame(width: 32)

            NativeCheckbox(state: node.priority == .dontDownload ? .off : .on) {
                node.priority = node.priority == .dontDownload ? .normal : .dontDownload
                model.syncFilePriorities()
            }

            Image(systemName: fileIcon(node.name))
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
                .font(.system(size: 12))

            Text(node.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(Color(nsColor: .labelColor))
                .strikethrough(node.priority == .dontDownload,
                               color: Color(nsColor: .secondaryLabelColor))

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
        .frame(height: 32)
        .contentShape(Rectangle())
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
