import SwiftUI

/// qBittorrent-style file list: per-file include checkbox, Select All / None,
/// a name filter, and multi-select right-click priority changes.
///
/// Bind it to a `[TorrentFile]` array. Whenever priorities change it mutates the
/// binding and calls `onChange`, so callers can push priorities to the engine
/// (Content tab) or just read them on confirm (Add dialog).
struct FilePriorityTable: View {
    @Binding var files: [TorrentFile]
    var onChange: () -> Void = {}

    @State private var selection: Set<Int> = []
    @State private var sortOrder: [KeyPathComparator<TorrentFile>] = [
        .init(\TorrentFile.name, order: .forward)
    ]
    @State private var filter = ""

    private var shown: [TorrentFile] {
        let base = filter.isEmpty
            ? files
            : files.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Select All") { apply(4, to: Set(shown.map { $0.id })) }
                Button("Select None") { apply(0, to: Set(shown.map { $0.id })) }
                Spacer()
                TextField("Filter files\u{2026}", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }

            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { file in
                    Toggle("", isOn: Binding(
                        get: { file.priority > 0 },
                        set: { on in toggle(file, on: on) }
                    ))
                    .labelsHidden()
                }
                .width(28)

                TableColumn("Name", value: \TorrentFile.name) { file in
                    Text(file.name).lineLimit(1).help(file.path)
                }
                .width(min: 180, ideal: 320)

                TableColumn("Size", value: \TorrentFile.size) { file in
                    Text(Formatters.bytes(file.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 90)

                TableColumn("Progress", value: \TorrentFile.progress) { file in
                    HStack(spacing: 6) {
                        ProgressView(value: min(max(file.progress, 0), 1)).frame(width: 70)
                        Text("\(Int((file.progress * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .width(min: 130, ideal: 140)

                TableColumn("Priority", value: \TorrentFile.priority) { file in
                    Text(file.priorityLabel)
                }
                .width(min: 110, ideal: 130)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                let targets = ids.isEmpty ? selection : ids
                Button("Do Not Download") { apply(0, to: targets) }
                Button("Normal Priority") { apply(4, to: targets) }
                Button("High Priority") { apply(6, to: targets) }
                Button("Maximum Priority") { apply(7, to: targets) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Toggling one row's checkbox affects the whole selection if that row is
    /// part of a multi-selection (matches qBittorrent).
    private func toggle(_ file: TorrentFile, on: Bool) {
        let targets: Set<Int> = (selection.contains(file.id) && selection.count > 1)
            ? selection
            : [file.id]
        apply(on ? 4 : 0, to: targets)
    }

    private func apply(_ value: Int, to ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let i = files.firstIndex(where: { $0.id == id }) {
                files[i].priority = value
            }
        }
        onChange()
    }
}
