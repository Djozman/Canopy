// PreAddSheet.swift — file selection before adding torrent

import SwiftUI

struct PreAddSheet: View {
    @Binding var pending: PendingTorrent
    let onConfirm: (PendingTorrent) -> Void
    let onCancel: () -> Void

    @State private var sortOrder: FileSortOrder = .nameAsc

    private var sortedFiles: [PendingFile] {
        switch sortOrder {
        case .nameAsc:  return pending.files.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .nameDesc: return pending.files.sorted { $0.name.localizedCompare($1.name) == .orderedDescending }
        case .sizeAsc:  return pending.files.sorted { $0.size < $1.size }
        case .sizeDesc: return pending.files.sorted { $0.size > $1.size }
        }
    }

    private var allState: CheckState {
        let skipped = pending.files.filter { $0.priority == .dontDownload }.count
        if skipped == 0                    { return .on  }
        if skipped == pending.files.count  { return .off }
        return .mixed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.name).font(.headline).lineLimit(1)
                    Text(formatBytes(pending.totalSize))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Text("Save to:").font(.caption).foregroundStyle(.secondary)
                Text(pending.savePath)
                    .font(.caption).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        pending.savePath = url.path
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            fileListHeader
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sortedFiles) { file in
                        PreAddFileRow(file: fileBinding(file), totalSize: pending.totalSize)
                        Divider().opacity(0.3)
                    }
                }
            }

            Divider()

            HStack {
                TriStateCheckbox(state: allState)
                    .onTapGesture { toggleAll() }
                Text("Select all")
                    .font(.caption).foregroundStyle(.secondary)
                    .onTapGesture { toggleAll() }

                Spacer()

                let selectedSize = pending.files
                    .filter { $0.priority != .dontDownload }
                    .reduce(0) { $0 + $1.size }
                Text(formatBytes(selectedSize) + " selected")
                    .font(.caption).foregroundStyle(.secondary)

                Spacer()

                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.escape)
                Button("Add Torrent") { onConfirm(pending) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 440, idealHeight: 520)
    }

    @ViewBuilder
    private var fileListHeader: some View {
        HStack(spacing: 0) {
            TriStateCheckbox(state: allState)
                .onTapGesture { toggleAll() }
                .padding(.horizontal, 8)
            sortButton("File", asc: .nameAsc, desc: .nameDesc, minWidth: 240)
            Divider().frame(height: 20)
            sortButton("Size", asc: .sizeAsc, desc: .sizeDesc, minWidth: 80)
            Divider().frame(height: 20)
            Text("Priority").font(.caption).foregroundStyle(.secondary).frame(width: 80)
        }
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func sortButton(_ title: String, asc: FileSortOrder, desc: FileSortOrder, minWidth: CGFloat) -> some View {
        Button {
            sortOrder = sortOrder == asc ? desc : asc
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if sortOrder == asc {
                    Image(systemName: "chevron.up").font(.system(size: 8))
                } else if sortOrder == desc {
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
            }
            .frame(minWidth: minWidth, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private func fileBinding(_ file: PendingFile) -> Binding<PendingFile> {
        Binding(
            get: { pending.files.first(where: { $0.id == file.id }) ?? file },
            set: { updated in
                if let idx = pending.files.firstIndex(where: { $0.id == updated.id }) {
                    pending.files[idx] = updated
                }
            }
        )
    }

    private func toggleAll() {
        let newPrio: FilePriority = allState == .on ? .dontDownload : .normal
        for i in pending.files.indices { pending.files[i].priority = newPrio }
    }
}

private struct PreAddFileRow: View {
    @Binding var file: PendingFile
    let totalSize: Int64

    var body: some View {
        HStack(spacing: 8) {
            TriStateCheckbox(state: file.priority == .dontDownload ? .off : .on)
                .onTapGesture {
                    file.priority = file.priority == .dontDownload ? .normal : .dontDownload
                }
                .padding(.leading, 8)

            Image(systemName: fileIcon(file.name))
                .foregroundStyle(.secondary).font(.system(size: 12))

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .strikethrough(file.priority == .dontDownload)
                    .foregroundStyle(file.priority == .dontDownload ? .secondary : .primary)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            Text(formatBytes(file.size))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            Menu {
                ForEach(FilePriority.allCases, id: \.self) { p in
                    Button(p.label) { file.priority = p }
                }
            } label: {
                Text(file.priority.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
}
