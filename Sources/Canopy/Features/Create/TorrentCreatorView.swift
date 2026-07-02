import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Mirrors qBittorrent's Torrent Creator: pick a file or folder, add trackers,
/// set options, and write a .torrent via the libtorrent bridge.
struct TorrentCreatorView: View {
    @EnvironmentObject var engine: EngineSession

    @State private var sourcePath = ""
    @State private var showFile = false
    @State private var showFolder = false
    @State private var trackers = ""
    @State private var comment = ""
    @State private var isPrivate = false
    @State private var pieceSize = 0   // 0 = auto; otherwise KiB
    @State private var status = ""
    @State private var busy = false

    private let pieceOptions: [(String, Int)] = [
        ("Auto", 0), ("16 KiB", 16), ("32 KiB", 32), ("64 KiB", 64),
        ("128 KiB", 128), ("256 KiB", 256), ("512 KiB", 512),
        ("1 MiB", 1024), ("2 MiB", 2048), ("4 MiB", 4096), ("8 MiB", 8192)
    ]

    var body: some View {
        Form {
            Section("Source") {
                HStack {
                    TextField("File or folder path", text: $sourcePath)
                        .textFieldStyle(.roundedBorder)
                    Button("File\u{2026}") { showFile = true }
                    Button("Folder\u{2026}") { showFolder = true }
                }
            }
            Section("Trackers") {
                TextEditor(text: $trackers)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("One tracker URL per line.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Options") {
                TextField("Comment", text: $comment).textFieldStyle(.roundedBorder)
                Toggle("Private torrent (disable DHT / PEX / LSD)", isOn: $isPrivate)
                Picker("Piece size:", selection: $pieceSize) {
                    ForEach(pieceOptions, id: \.1) { Text($0.0).tag($0.1) }
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
            Section {
                Button { create() } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Create Torrent\u{2026}")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourcePath.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 540)
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sourcePath = url.path }
        }
        .fileImporter(isPresented: $showFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sourcePath = url.path }
        }
    }

    private func create() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        let base = (sourcePath as NSString).lastPathComponent
        panel.nameFieldStringValue = (base.isEmpty ? "created" : base) + ".torrent"
        guard panel.runModal() == .OK, let out = panel.url else { return }

        let trackerList = trackers
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        busy = true
        status = "Creating\u{2026} (hashing can take a while for large content)"
        // Hashing runs on the main actor; the window stays responsive enough for
        // typical content and this keeps the bridge call simple and safe.
        let result = engine.createTorrent(sourcePath: sourcePath,
                                          output: out.path,
                                          trackers: trackerList,
                                          comment: comment,
                                          isPrivate: isPrivate,
                                          pieceSize: pieceSize * 1024)
        busy = false
        status = result != nil
            ? "Created: \(out.lastPathComponent)"
            : "Failed to create torrent. See Log for details."
    }
}
