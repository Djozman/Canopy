// PreAddSheet.swift — file selection before adding torrent

import SwiftUI

struct PreAddSheet: View {
    // ObservableObject owned by the NSWindow, not a Binding over a reference box.
    // Every write to model.pending triggers @Published → SwiftUI diff → re-render.
    @ObservedObject var model: PreAddViewModel
    let onConfirm: (PendingTorrent) -> Void
    let onCancel: () -> Void

    @State private var sortOrder: FileSortOrder = .nameAsc

    // Convenience shorthands
    private var pending: PendingTorrent { model.pending }

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
        if skipped == 0                   { return .on   }
        if skipped == pending.files.count { return .off  }
        return .mixed
    }

    private var selectedSize: Int64 {
        pending.files.filter { $0.priority != .dontDownload }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(formatBytes(pending.totalSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // ── Save path ─────────────────────────────────────────
            HStack {
                Text("Save to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pending.savePath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        model.pending.savePath = url.path
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // ── File list or loading spinner ──────────────────────
            if pending.isMagnet && pending.files.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching metadata\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Column header
                HStack(spacing: 0) {
                    Button { toggleAll() } label: {
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
                        .foregroundStyle(.secondary)
                        .frame(width: 90)
                }
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List {
                    ForEach(sortedFiles) { file in
                        PreAddFileRow(model: model, fileID: file.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // ── Bottom bar ────────────────────────────────────────
            HStack(spacing: 12) {
                Button { toggleAll() } label: {
                    HStack(spacing: 6) {
                        TriStateCheckbox(state: allState)
                        Text("Select all")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(formatBytes(selectedSize) + " selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

    // MARK: - Sort button

    @ViewBuilder
    private func sortButton(_ title: String, asc: FileSortOrder,
                             desc: FileSortOrder, minWidth: CGFloat) -> some View {
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

    // MARK: - Helpers

    private func toggleAll() {
        let newPrio: FilePriority = allState == .on ? .dontDownload : .normal
        for i in model.pending.files.indices {
            model.pending.files[i].priority = newPrio
        }
    }
}

// MARK: - File row
// Receives the shared ObservableObject + a stable file ID.
// Writes go directly to model.pending.files[idx] — @Published fires, parent re-renders.

private struct PreAddFileRow: View {
    @ObservedObject var model: PreAddViewModel
    let fileID: Int

    private var idx: Int? {
        model.pending.files.firstIndex(where: { $0.id == fileID })
    }

    var body: some View {
        // Guard: file might not exist yet (shouldn’t happen, but be safe)
        guard let i = idx else { return AnyView(EmptyView()) }
        let file = model.pending.files[i]
        return AnyView(
            HStack(spacing: 8) {

                Button {
                    model.pending.files[i].priority =
                        model.pending.files[i].priority == .dontDownload ? .normal : .dontDownload
                } label: {
                    TriStateCheckbox(state: file.priority == .dontDownload ? .off : .on)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)

                Image(systemName: fileIcon(file.name))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(file.priority == .dontDownload)
                        .foregroundStyle(file.priority == .dontDownload ? .secondary : .primary)
                    if !file.directory.isEmpty {
                        Text(file.directory)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

                Text(formatBytes(file.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)

                Menu {
                    ForEach(FilePriority.allCases, id: \.self) { p in
                        Button(p.label) { model.pending.files[i].priority = p }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(file.priority.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 90)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Divider().opacity(0.3)
            }
        )
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
