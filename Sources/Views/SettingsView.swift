import SwiftUI

struct SettingsView: View {
    @Environment(TorrentEngine.self) private var engine

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(engine.saveDirectory.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .leading)
                        Button("Change…") { chooseSaveDir() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Section("Network") {
                LabeledContent("Listen port", value: "6881 (TCP + uTP)")
                LabeledContent("DHT", value: engine.torrents.isEmpty ? "Starting…" : "Active")
            }

            Section("About") {
                LabeledContent("Client name", value: "Canopy/1.0")
                LabeledContent("Protocol", value: "BitTorrent (BEP 3, 5, 9, 10, 29)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 280)
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose the default folder for downloaded files"
        if panel.runModal() == .OK, let url = panel.url {
            engine.setSaveDirectory(url)
        }
    }
}
