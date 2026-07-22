// AddTorrentSheet.swift

import AppKit
import ClibtorrentBridge
import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var magnetURI = ""
    @State private var torrentPath = ""
    @State private var saveDir: String
    @State private var showFilePicker = false
    @State private var tab = 0
    @State private var parseError: String?

    let engine: TorrentEngine
    let onNext: (PendingTorrent, LTTorrentHandle?) -> Void

    init(engine: TorrentEngine, onNext: @escaping (PendingTorrent, LTTorrentHandle?) -> Void) {
        self.engine = engine
        self.onNext = onNext
        _saveDir = State(initialValue: engine.defaultSavePath)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Source", selection: $tab) {
                    Text("Magnet").tag(0)
                    Text(".torrent file").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .onChange(of: tab) { _, newTab in
                    if newTab == 0 { checkClipboard() }
                }

                if tab == 0 {
                    Section("Magnet URL") {
                        MagnetTextEditor(text: $magnetURI)
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
                        if tab == 0 { handleMagnet() } else { handleTorrentFile() }
                    }
                    .disabled(
                        tab == 0
                            ? magnetURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            : torrentPath.isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .alert("Error", isPresented: Binding(
            get: { parseError != nil },
            set: { if !$0 { parseError = nil } }
        )) {
            Button("OK") { parseError = nil }
        } message: {
            Text(parseError ?? "")
        }
        .onAppear { checkClipboard() }
    }

    private func checkClipboard() {
        let firstLine =
            magnetURI.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces)
            ?? ""
        guard firstLine.isEmpty else { return }
        guard let str = NSPasteboard.general.string(forType: .string),
            str.hasPrefix("magnet:?")
        else { return }
        let parts = magnetURI.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        magnetURI = ([str] + parts).joined(separator: "\n")
    }

    @MainActor private func handleMagnet() {
        let lines =
            magnetURI
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("magnet:?") }

        guard !lines.isEmpty else {
            parseError = "No valid magnet links found."
            return
        }

        let save = saveDir

        for (i, uri) in lines.enumerated() {
            var displayName = "Fetching metadata\u{2026}"
            if let comps = URLComponents(string: uri),
                let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value
            {
                displayName = dn
            }

            let stub = PendingTorrent(
                source: .magnet(uri: uri), name: displayName,
                totalSize: 0, savePath: save, files: []
            )

            var magnetHandle: LTTorrentHandle?
            magnetHandle = engine.fetchMetadata(
                uri: uri,
                onFiles: { files in
                    let updated = PendingTorrent(
                        source: .magnet(uri: uri), name: displayName,
                        totalSize: files.reduce(0) { $0 + $1.size },
                        savePath: save, files: files
                    )
                    // Update the existing window for this magnet index
                    PreAddCoordinator.shared.updateWindow(
                        at: i, pending: updated, handle: magnetHandle)
                },
                onError: { PreAddCoordinator.shared.failWindow(at: i, message: "Could not fetch magnet metadata. Check the link and network connection.") }
            )

            if i == 0 {
                onNext(stub, magnetHandle)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.1) {
                    NotificationCenter.default.post(
                        name: .showPreAdd, object: nil,
                        userInfo: [
                            "pending": stub,
                            "handle": magnetHandle as Any,
                            "magnetIndex": i,
                        ]
                    )
                }
            }
        }

        dismiss()
    }

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

// MARK: - No-wrap text editor

private struct MagnetTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font =
            font
            ?? NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MagnetTextEditor
        init(_ parent: MagnetTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
