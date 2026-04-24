import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    // Drop-zone state
    @State private var isTargeted = false
    @State private var error: String?

    // After parse — confirmation phase
    @State private var parsedMeta: Metainfo?
    @State private var torrentData: Data?
    @State private var fileSelections: [Bool] = []
    @State private var saveDir: URL? = nil

    var body: some View {
        Group {
            if let meta = parsedMeta {
                confirmView(meta: meta)
            } else {
                pickView
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    // MARK: - Phase 1: Drop / pick

    private var pickView: some View {
        VStack(spacing: 20) {
            Text("Add Torrent")
                .font(.title2.bold())

            dropZone

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 2, dash: [6])
            )
            .background(Color.secondary.opacity(0.04))
            .frame(height: 140)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus").font(.largeTitle)
                    Text("Drop .torrent file here")
                    Button("Choose File…") { openFilePicker() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                    guard let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let fileData = try? Data(contentsOf: url)
                    else { return }
                    DispatchQueue.main.async { parseTorrent(fileData) }
                }
                return true
            }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        parseTorrent(data)
    }

    private func parseTorrent(_ data: Data) {
        do {
            let meta = try Metainfo.parse(data)
            torrentData = data
            parsedMeta = meta
            fileSelections = Array(repeating: true, count: meta.files.count)
            saveDir = engine.saveDirectory
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Phase 2: Confirm

    private func confirmView(meta: Metainfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(meta.name)
                .font(.title2.bold())
                .lineLimit(2)

            // File list
            if meta.files.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Files").font(.headline)
                        Spacer()
                        Button(fileSelections.allSatisfy({ $0 }) ? "Deselect All" : "Select All") {
                            let all = fileSelections.allSatisfy { $0 }
                            fileSelections = Array(repeating: !all, count: fileSelections.count)
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(meta.files.indices, id: \.self) { idx in
                                HStack {
                                    Toggle(isOn: $fileSelections[idx]) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(meta.files[idx].name)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(formatBytes(meta.files[idx].length))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                if idx < meta.files.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Selected size summary
            let selectedSize = selectedBytes(meta: meta)
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text(meta.files.count > 1
                     ? "\(formatBytes(selectedSize)) selected of \(formatBytes(meta.totalSize))"
                     : formatBytes(meta.totalSize))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Save location
            HStack {
                Text("Save to:").font(.callout)
                Text(saveDir?.path ?? engine.saveDirectory.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { chooseSaveDir() }
                    .buttonStyle(.borderless)
            }

            HStack {
                Button("Back") {
                    parsedMeta = nil; torrentData = nil; fileSelections = []
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Download") { startDownload(meta: meta) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fileSelections.allSatisfy { !$0 })
            }
        }
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK { saveDir = panel.url }
    }

    private func startDownload(meta: Metainfo) {
        guard let data = torrentData else { return }
        let dir = saveDir ?? engine.saveDirectory
        let sel = fileSelections.allSatisfy { $0 } ? nil : fileSelections
        do {
            try engine.add(torrentFileData: data, saveDirectory: dir, fileSelections: sel)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func selectedBytes(meta: Metainfo) -> Int64 {
        zip(meta.files, fileSelections).reduce(0) { $0 + ($1.1 ? $1.0.length : 0) }
    }

    private func formatBytes(_ n: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: n)
    }
}

// MARK: - Magnet link sheet

struct MagnetView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var magnetText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Magnet Link")
                .font(.title2.bold())

            TextField("magnet:?xt=urn:btih:…", text: $magnetText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { addMagnet() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(magnetText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func addMagnet() {
        let uri = magnetText.trimmingCharacters(in: .whitespaces)
        do {
            try engine.addMagnet(uri)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
