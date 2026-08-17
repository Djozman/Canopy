import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: TorrentEngine

    // Settings are edited as a draft. The previous AppStorage bindings wrote
    // every keystroke immediately, so Cancel did not actually cancel.
    @State private var downloadDir: String
    @State private var downloadLimit: Int
    @State private var uploadLimit: Int
    @State private var maxActiveDown: Int
    @State private var maxActiveSeed: Int
    @State private var enableDHT: Bool
    @State private var enableLSD: Bool
    @State private var enableUPnP: Bool
    @State private var enableNatPMP: Bool
    @State private var listenPort: Int
    @State private var anonymousMode: Bool

    init(engine: TorrentEngine) {
        self.engine = engine
        let defaults = UserDefaults.standard
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        _downloadDir = State(initialValue: defaults.string(forKey: "downloadDir") ?? fallback)
        _downloadLimit = State(initialValue: defaults.integer(forKey: "downloadLimit"))
        _uploadLimit = State(initialValue: defaults.integer(forKey: "uploadLimit"))
        _maxActiveDown = State(initialValue: defaults.object(forKey: "maxActiveDown") == nil ? 3 : defaults.integer(forKey: "maxActiveDown"))
        _maxActiveSeed = State(initialValue: defaults.object(forKey: "maxActiveSeed") == nil ? 5 : defaults.integer(forKey: "maxActiveSeed"))
        _enableDHT = State(initialValue: defaults.object(forKey: "enableDHT") == nil ? true : defaults.bool(forKey: "enableDHT"))
        _enableLSD = State(initialValue: defaults.object(forKey: "enableLSD") == nil ? true : defaults.bool(forKey: "enableLSD"))
        _enableUPnP = State(initialValue: defaults.object(forKey: "enableUPnP") == nil ? true : defaults.bool(forKey: "enableUPnP"))
        _enableNatPMP = State(initialValue: defaults.object(forKey: "enableNatPMP") == nil ? true : defaults.bool(forKey: "enableNatPMP"))
        _listenPort = State(initialValue: defaults.object(forKey: "listenPort") == nil ? 6881 : defaults.integer(forKey: "listenPort"))
        _anonymousMode = State(initialValue: defaults.bool(forKey: "anonymousMode"))
    }

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
                        persistDraft()
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

    private func persistDraft() {
        let defaults = UserDefaults.standard
        defaults.set(downloadDir, forKey: "downloadDir")
        defaults.set(downloadLimit, forKey: "downloadLimit")
        defaults.set(uploadLimit, forKey: "uploadLimit")
        defaults.set(maxActiveDown, forKey: "maxActiveDown")
        defaults.set(maxActiveSeed, forKey: "maxActiveSeed")
        defaults.set(enableDHT, forKey: "enableDHT")
        defaults.set(enableLSD, forKey: "enableLSD")
        defaults.set(enableUPnP, forKey: "enableUPnP")
        defaults.set(enableNatPMP, forKey: "enableNatPMP")
        defaults.set(listenPort, forKey: "listenPort")
        defaults.set(anonymousMode, forKey: "anonymousMode")
    }
}
