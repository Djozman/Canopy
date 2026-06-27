import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @EnvironmentObject var engine: EngineSession
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case magnet = "Magnet / URL"
        case file = ".torrent file"
        var id: String { rawValue }
    }

    @State private var source: Source = .magnet
    @State private var magnet = ""
    @State private var filePath: String?
    @State private var startPaused = false
    @State private var showImporter = false
    @State private var category = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Torrent").font(.title2.bold())

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

            Divider()

            Picker("Category:", selection: $category) {
                Text("None").tag("")
                ForEach(engine.library.categories) { Text($0.name).tag($0.name) }
            }

            HStack {
                Text("Save to:").foregroundStyle(.secondary)
                Text(saveLocation).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)

            Toggle("Start paused", isOn: $startPaused)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            if case .success(let url) = result { filePath = url.path }
        }
    }

    private var saveLocation: String {
        engine.library.savePath(forCategory: category) ?? engine.settings.defaultSavePath
    }

    private var canAdd: Bool {
        source == .magnet ? !magnet.trimmingCharacters(in: .whitespaces).isEmpty : filePath != nil
    }

    private func add() {
        switch source {
        case .magnet:
            engine.addMagnet(magnet, paused: startPaused, category: category)
        case .file:
            if let p = filePath { engine.addTorrentFile(p, paused: startPaused, category: category) }
        }
        dismiss()
    }
}
