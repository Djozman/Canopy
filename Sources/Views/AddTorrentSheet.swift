// AddTorrentSheet.swift

import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var magnetURI = ""
    @State private var saveDir   = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @State private var showFilePicker = false
    @State private var tab = 0

    var onAdd: (String, String, Bool) -> Void  // (uri/path, saveDir, isMagnet)

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
                        Button("Choose file…") { showFilePicker = true }
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
            }
            .formStyle(.grouped)
            .navigationTitle("Add Torrent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(magnetURI, saveDir, tab == 0)
                        dismiss()
                    }
                    .disabled(magnetURI.isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
    }
}
