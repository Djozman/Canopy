import SwiftUI

struct FilesTarget: Identifiable {
    let id = UUID()
    let hash: String
    let name: String
}

struct FilesSheet: View {
    @EnvironmentObject var engine: EngineSession
    @Environment(\.dismiss) private var dismiss
    let target: FilesTarget

    @State private var files: [TorrentFile] = []
    @State private var sortOrder: [KeyPathComparator<TorrentFile>] = [
        .init(\TorrentFile.name, order: .forward)
    ]

    private let options: [(label: String, value: Int)] = [
        ("Do not download", 0),
        ("Normal", 4),
        ("High", 6),
        ("Maximum", 7),
    ]

    private var sortedFiles: [TorrentFile] { files.sorted(using: sortOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files \u{2014} \(target.name)")
                .font(.headline)
                .lineLimit(1)

            if files.isEmpty {
                ContentUnavailableView("No file list yet",
                    systemImage: "doc.questionmark",
                    description: Text("Metadata is still downloading for this torrent."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(sortedFiles, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \TorrentFile.name) { file in
                        Text(file.name).lineLimit(1).help(file.path)
                    }
                    .width(min: 200, ideal: 340)

                    TableColumn("Size", value: \TorrentFile.size) { file in
                        Text(Formatters.bytes(file.size)).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90)

                    TableColumn("Progress", value: \TorrentFile.progress) { file in
                        HStack(spacing: 6) {
                            ProgressView(value: min(max(file.progress, 0), 1))
                                .frame(width: 90)
                            Text("\(Int((file.progress * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    .width(min: 150, ideal: 160)

                    TableColumn("Priority") { file in
                        Picker("", selection: Binding(
                            get: { displayValue(file.priority) },
                            set: { setPriority($0, for: file) }
                        )) {
                            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                    }
                    .width(min: 150, ideal: 160)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("Refresh") { reload() }
                Spacer()
                Text("\(files.count) files").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560, idealWidth: 780, maxWidth: .infinity,
               minHeight: 420, idealHeight: 620, maxHeight: .infinity)
        .onAppear { reload() }
    }

    private func reload() {
        files = engine.files(for: target.hash)
    }

    /// Snap any libtorrent priority (0..7) onto one of our four buckets.
    private func displayValue(_ p: Int) -> Int {
        switch p {
        case 0: return 0
        case 7: return 7
        case 6: return 6
        default: return 4
        }
    }

    private func setPriority(_ value: Int, for file: TorrentFile) {
        if let i = files.firstIndex(where: { $0.id == file.id }) {
            files[i].priority = value
        }
        // Engine expects priorities ordered by file index.
        let ordered = files.sorted { $0.id < $1.id }.map { $0.priority }
        engine.setFilePriorities(ordered, for: target.hash)
    }
}
