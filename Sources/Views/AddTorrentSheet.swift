// AddTorrentSheet.swift

import SwiftUI
import UniformTypeIdentifiers
import CanopyEngine

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var magnetURI    = ""
    @State private var torrentPath  = ""
    @State private var saveDir      = FileManager.default.homeDirectoryForCurrentUser
                                        .appendingPathComponent("Downloads").path
    @State private var showFilePicker = false
    @State private var tab            = 0
    @State private var parseError: String?

    let engine: CanopyEngine
    let onNext: (PendingTorrent, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Source", selection: $tab) {
                    Text("Magnet").tag(0)
                    Text(".torrent file").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if tab == 0 {
                    Section("Magnet URI") {
                        TextEditor(text: $magnetURI)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 60)
                    }
                } else {
                    Section(".torrent file") {
                        Button("Choose file\u{2026}") { showFilePicker = true }
                            .fileImporter(
                                isPresented: $showFilePicker,
                                allowedContentTypes: [UTType(filenameExtension: "torrent")!]
                            ) { result in
                                if case .success(let url) = result {
                                    torrentPath = url.path
                                }
                            }
                        if !torrentPath.isEmpty {
                            Text(torrentPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Save to") {
                    TextField("Save path", text: $saveDir)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next\u{2026}") {
                        if tab == 0 { handleMagnet() }
                        else        { handleTorrentFile() }
                    }
                    .disabled(tab == 0 ? magnetURI.isEmpty : torrentPath.isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 300)
        .alert("Error", isPresented: .constant(parseError != nil)) {
            Button("OK") { parseError = nil }
        } message: {
            Text(parseError ?? "")
        }
    }

    // MARK: - Magnet: open window immediately, fetch metadata in background

    @MainActor private func handleMagnet() {
        let uri  = magnetURI
        let save = saveDir

        // Extract display name from dn= if present
        var displayName = "Fetching metadata\u{2026}"
        if let comps = URLComponents(string: uri),
           let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value {
            displayName = dn
        }

        let stub = PendingTorrent(
            source:    .magnet(uri: uri),
            name:      displayName,
            totalSize: 0,
            savePath:  save,
            files:     []
        )

        // The handle is the infohash hex — derivable from the URI before the
        // fetch starts, so closures can capture it as `let` without the
        // sendable-mutation warning.
        let handle = engine.magnetHandle(for: uri)
        let magnetHandle = engine.fetchMetadata(
            uri: uri,
            onFiles: { files in
                let updated = PendingTorrent(
                    source:    .magnet(uri: uri),
                    name:      displayName,
                    totalSize: files.reduce(0) { $0 + $1.size },
                    savePath:  save,
                    files:     files
                )
                NotificationCenter.default.post(
                    name: .showPreAdd, object: nil,
                    userInfo: ["pending": updated, "handle": handle as Any]
                )
            },
            onError: {
                parseError = "Could not fetch magnet metadata."
            },
            onProgress: { msg in
                NotificationCenter.default.post(
                    name: .magnetMetadataProgress, object: nil,
                    userInfo: ["handle": handle as Any, "message": msg]
                )
            }
        )

        onNext(stub, magnetHandle)
        dismiss()
    }

    // MARK: - .torrent file: parse locally, open window with full file list

    @MainActor private func handleTorrentFile() {
        guard var pending = engine.parse(torrentPath: torrentPath) else {
            parseError = "Failed to parse torrent file."
            return
        }
        pending.savePath = saveDir
        onNext(pending, nil)
        dismiss()
    }
}
