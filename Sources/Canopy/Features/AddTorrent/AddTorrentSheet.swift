import SwiftUI
import UniformTypeIdentifiers

/// Mirrors qBittorrent's "Add new torrent" dialog: pick a source, fetch the
/// metadata (for magnets), then choose which files to download, where to save,
/// category / tags, and start options before committing.
struct AddTorrentSheet: View {
    @EnvironmentObject var engine: EngineSession
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case magnet = "Magnet / URL"
        case file = ".torrent file"
        var id: String { rawValue }
    }

    enum Phase { case input, fetching, ready }

    @State private var source: Source = .magnet
    @State private var magnet = ""
    @State private var filePath: String?
    @State private var showImporter = false
    @State private var showFolderImporter = false

    @State private var phase: Phase = .input
    @State private var addedHash: String?
    @State private var addedSavePath = ""
    @State private var files: [TorrentFile] = []
    @State private var timedOut = false

    // Options shown once metadata is ready.
    @State private var savePath = ""
    @State private var category = ""
    @State private var tags = ""
    @State private var startTorrent = true
    @State private var sequential = false
    @State private var firstLast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Torrent").font(.title2.bold())

            switch phase {
            case .input:   inputSection
            case .fetching: fetchingSection
            case .ready:   readySection
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 860, maxWidth: .infinity,
               minHeight: phase == .ready ? 560 : 260,
               idealHeight: phase == .ready ? 720 : 300,
               maxHeight: .infinity)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            if case .success(let url) = result { filePath = url.path }
        }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { savePath = url.path }
        }
        .onChange(of: category) {
            savePath = engine.library.savePath(forCategory: category) ?? engine.settings.defaultSavePath
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if source == .magnet {
                TextField("magnet:?xt=urn:btih:\u{2026} or http URL", text: $magnet, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
            } else {
                HStack {
                    Text(filePath.map { ($0 as NSString).lastPathComponent } ?? "No file selected")
                        .foregroundStyle(filePath == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose\u{2026}") { showImporter = true }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Next") { beginFetch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canFetch)
            }
        }
    }

    private var canFetch: Bool {
        source == .magnet ? !magnet.trimmingCharacters(in: .whitespaces).isEmpty : filePath != nil
    }

    // MARK: - Fetching metadata

    private var fetchingSection: some View {
        VStack(spacing: 16) {
            Spacer()
            if timedOut {
                Image(systemName: "clock.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text("Still retrieving metadata\u{2026}").font(.headline)
                Text("This magnet has no peers yet. You can keep waiting or cancel.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text("Retrieving metadata\u{2026}").font(.headline)
                Text("Fetching the file list from peers / DHT.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ready (choose files + options)

    private var readySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Save location
            HStack {
                Text("Save to:").foregroundStyle(.secondary)
                TextField("", text: $savePath)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                Button("Choose\u{2026}") { showFolderImporter = true }
            }

            HStack(spacing: 12) {
                Picker("Category:", selection: $category) {
                    Text("None").tag("")
                    ForEach(engine.library.categories) { Text($0.name).tag($0.name) }
                }
                .frame(maxWidth: 240)
                TextField("Tags (comma separated)", text: $tags)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 16) {
                Toggle("Start torrent", isOn: $startTorrent)
                Toggle("Sequential", isOn: $sequential)
                Toggle("First && last pieces first", isOn: $firstLast)
                Spacer()
            }

            Divider()

            HStack {
                Text("Files").font(.headline)
                Spacer()
                Text("\(selectedCount) of \(files.count) selected \u{2022} \(Formatters.bytes(selectedSize))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            FilePriorityTable(files: $files)

            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Add") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0)
            }
        }
    }

    private var selectedCount: Int { files.filter { $0.priority > 0 }.count }
    private var selectedSize: Int64 { files.filter { $0.priority > 0 }.reduce(0) { $0 + $1.size } }

    // MARK: - Actions

    private func beginFetch() {
        let hash: String?
        switch source {
        case .magnet:
            hash = engine.addMagnet(magnet.trimmingCharacters(in: .whitespaces), paused: false)
        case .file:
            hash = filePath.flatMap { engine.addTorrentFile($0, paused: false) }
        }
        guard let h = hash else { dismiss(); return }
        addedHash = h
        savePath = engine.settings.defaultSavePath
        phase = .fetching
        Task { await waitForMetadata(h) }
    }

    @MainActor
    private func waitForMetadata(_ hash: String) async {
        for attempt in 0..<600 { // ~5 minutes at 0.5s
            let f = engine.files(for: hash)
            if !f.isEmpty {
                files = f
                // Freeze the torrent so no data downloads while the user decides.
                engine.pause([hash])
                addedSavePath = engine.torrents.first { $0.infoHash == hash }?.savePath
                    ?? engine.settings.defaultSavePath
                if savePath.isEmpty { savePath = addedSavePath }
                phase = .ready
                return
            }
            if attempt == 20 { timedOut = true } // ~10s with no metadata
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func confirm() {
        guard let hash = addedHash else { dismiss(); return }

        // File priorities (ordered by file index).
        let ordered = files.sorted { $0.id < $1.id }.map { $0.priority }
        engine.setFilePriorities(ordered, for: hash)

        // Save location.
        let trimmedPath = savePath.trimmingCharacters(in: .whitespaces)
        if !trimmedPath.isEmpty, trimmedPath != addedSavePath {
            engine.moveStorage(hash, to: trimmedPath)
        }

        // Category & tags.
        if !category.isEmpty { engine.setCategory(category, for: [hash]) }
        for tag in tags.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
            engine.addTag(tag, for: [hash])
        }

        // BitTorrent options.
        if sequential { engine.setSequential(true, for: [hash]) }
        if firstLast { engine.setFirstLastPiece(true, for: [hash]) }

        // Start or leave paused.
        if startTorrent { engine.resume([hash]) }

        dismiss()
    }

    private func cancel() {
        if let hash = addedHash {
            engine.remove([hash], deleteFiles: true)
        }
        dismiss()
    }
}
