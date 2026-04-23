import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var error: String?
    @State private var isTargeted = false

    var body: some View {
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
        .padding(24)
        .frame(width: 420)
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
                    Image(systemName: "doc.badge.plus")
                        .font(.largeTitle)
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
                    DispatchQueue.main.async { addFile(fileData) }
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
        addFile(data)
    }

    private func addFile(_ data: Data) {
        do {
            try engine.add(torrentFileData: data)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
