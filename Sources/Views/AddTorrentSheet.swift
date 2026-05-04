// AddTorrentSheet.swift

import SwiftUI
import UniformTypeIdentifiers
import ClibtorrentBridge

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var magnetURI = ""
    @State private var saveDir   = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @State private var showFilePicker = false
    @State private var tab = 0

    @State private var pendingTorrent: PendingTorrent?
    @State private var showingPreAdd = false
    @State private var parseError: String?
    @State private var isFetchingMetadata = false
    @State private var metadataHandle: LTTorrentHandle?

    let engine: TorrentEngine

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
                            .fileImporter(isPresented: $showFilePicker,
                                          allowedContentTypes: [UTType(filenameExtension: "torrent")!]) { result in
                                if case .success(let url) = result {
                                    magnetURI = url.path
                                }
                            }
                        if !magnetURI.isEmpty {
                            Text(magnetURI)
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

                if isFetchingMetadata {
                    Section {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Fetching metadata\u{2026}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isFetchingMetadata ? "Fetching\u{2026}" : "Next\u{2026}") {
                        if tab == 0 {
                            startMagnetFetch()
                        } else {
                            parseTorrentFile()
                        }
                    }
                    .disabled(magnetURI.isEmpty || isFetchingMetadata)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
        .sheet(isPresented: $showingPreAdd) {
            if let binding = Binding($pendingTorrent) {
                PreAddSheet(
                    pending: binding,
                    onConfirm: { confirmed in
                        if let handle = metadataHandle {
                            engine.commitMagnet(handle: handle,
                                                savePath: confirmed.savePath,
                                                files: confirmed.files)
                        } else {
                            engine.confirm(confirmed)
                        }
                        showingPreAdd = false
                        dismiss()
                    },
                    onCancel: {
                        if let handle = metadataHandle {
                            engine.cancelMagnet(handle: handle)
                        }
                        metadataHandle = nil
                        showingPreAdd = false
                    }
                )
            }
        }
        .alert("Error", isPresented: .constant(parseError != nil)) {
            Button("OK") { parseError = nil }
        } message: {
            Text(parseError ?? "")
        }
    }

    private func startMagnetFetch() {
        isFetchingMetadata = true
        metadataHandle = engine.fetchMetadata(
            uri: magnetURI,
            onFiles: { files in
                isFetchingMetadata = false
                var name = magnetURI
                if let comps = URLComponents(string: magnetURI),
                   let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value {
                    name = dn
                }
                let pending = PendingTorrent(
                    source: .magnet(uri: magnetURI),
                    name: name,
                    totalSize: files.reduce(0) { $0 + $1.size },
                    savePath: saveDir,
                    files: files
                )
                pendingTorrent = pending
                showingPreAdd = true
            },
            onError: {
                isFetchingMetadata = false
                parseError = "Could not fetch magnet metadata."
            }
        )
    }

    private func parseTorrentFile() {
        if let pending = engine.parse(torrentPath: magnetURI) {
            var p = pending
            p.savePath = saveDir
            pendingTorrent = p
            showingPreAdd = true
        } else {
            parseError = "Failed to parse torrent file."
        }
    }
}
