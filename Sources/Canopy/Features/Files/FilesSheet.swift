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

    private let options: [(label: String, value: Int)] = [
        ("Do not download", 0),
        ("Normal", 4),
        ("High", 6),
        ("Maximum", 7),
    ]

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
                List(files) { file in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1)
                            Text("\(Formatters.bytes(file.size)) \u{2022} \(Int(file.progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { displayValue(file.priority) },
                            set: { setPriority($0, for: file) }
                        )) {
                            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }

            HStack {
                Button("Refresh") { reload() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 470)
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
        let ordered = files.sorted { $0.id < $1.id }.map { $0.priority }
        engine.setFilePriorities(ordered, for: target.hash)
    }
}
