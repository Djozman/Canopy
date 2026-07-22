import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: TorrentEngine

    @AppStorage("downloadDir") private var downloadDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @AppStorage("downloadLimit") private var downloadLimit = 0
    @AppStorage("uploadLimit") private var uploadLimit = 0
    @AppStorage("maxActiveDown") private var maxActiveDown = 3
    @AppStorage("maxActiveSeed") private var maxActiveSeed = 5
    @AppStorage("enableDHT") private var enableDHT = true
    @AppStorage("enableLSD") private var enableLSD = true
    @AppStorage("enableUPnP") private var enableUPnP = true
    @AppStorage("enableNatPMP") private var enableNatPMP = true
    @AppStorage("listenPort") private var listenPort = 6881
    @AppStorage("anonymousMode") private var anonymousMode = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Downloads") {
                    LabeledContent("Default save path") {
                        HStack {
                            TextField("Path", text: $downloadDir).font(.system(.body, design: .monospaced))
                            Button("Choose…", action: chooseDirectory)
                        }.frame(minWidth: 300)
                    }
                }
                Section("Speed Limits") {
                    limitField("Download limit", value: $downloadLimit)
                    limitField("Upload limit", value: $uploadLimit)
                    Text("Use 0 for unlimited. Limits are applied in KiB/s.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Queue") {
                    Stepper("Max active downloads: \(maxActiveDown)", value: $maxActiveDown, in: 1...99)
                    Stepper("Max active seeds: \(maxActiveSeed)", value: $maxActiveSeed, in: 1...99)
                }
                Section("Connection") {
                    LabeledContent("Listen port") {
                        TextField("Port", value: $listenPort, format: .number).frame(width: 90)
                    }
                    Toggle("Distributed Hash Table (DHT)", isOn: $enableDHT)
                    Toggle("Local Service Discovery (LSD)", isOn: $enableLSD)
                    Toggle("Automatic router mapping (UPnP)", isOn: $enableUPnP)
                    Toggle("Automatic router mapping (NAT-PMP)", isOn: $enableNatPMP)
                    Toggle("Anonymous mode", isOn: $anonymousMode)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        listenPort = min(65535, max(1, listenPort))
                        downloadLimit = max(0, downloadLimit)
                        uploadLimit = max(0, uploadLimit)
                        engine.applyPreferences()
                        dismiss()
                    }.keyboardShortcut(.defaultAction)
                }
            }
        }.frame(minWidth: 560, minHeight: 600)
    }

    private func limitField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) { TextField("KiB/s", value: value, format: .number).frame(width: 100) }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (downloadDir as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { downloadDir = url.path }
    }
}
