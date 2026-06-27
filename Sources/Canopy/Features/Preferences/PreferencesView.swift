import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject var engine: EngineSession

    var body: some View {
        TabView {
            DownloadsPrefs().environmentObject(engine)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            ConnectionPrefs().environmentObject(engine)
                .tabItem { Label("Connection", systemImage: "network") }
            SpeedPrefs().environmentObject(engine)
                .tabItem { Label("Speed", systemImage: "speedometer") }
            BitTorrentPrefs().environmentObject(engine)
                .tabItem { Label("BitTorrent", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - Shared binding helper

extension EngineSession {
    /// A binding into `settings` that re-applies preferences to the session
    /// whenever the value changes.
    func bind<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                guard self.settings[keyPath: keyPath] != newValue else { return }
                self.settings[keyPath: keyPath] = newValue
                self.applyAllSettings()
            }
        )
    }
}

// MARK: - Downloads

private struct DownloadsPrefs: View {
    @EnvironmentObject var engine: EngineSession
    @State private var showImporter = false

    var body: some View {
        Form {
            Section("Save Location") {
                HStack {
                    Text(engine.settings.defaultSavePath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose\u{2026}") { showImporter = true }
                }
                Text("New torrents without a category save here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Add torrents in paused state", isOn: engine.bind(\.startPaused))
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                engine.settings.defaultSavePath = url.path
                engine.applyAllSettings()
            }
        }
    }
}

// MARK: - Connection

private struct ConnectionPrefs: View {
    @EnvironmentObject var engine: EngineSession

    var body: some View {
        Form {
            Section("Listening") {
                LabeledIntField(label: "Port used for incoming connections:",
                                value: engine.bind(\.listenPort), range: 1...65535)
            }
            Section("Limits") {
                LabeledIntField(label: "Global maximum number of connections:",
                                value: engine.bind(\.maxConnections), range: 1...5000)
                LabeledIntField(label: "Global maximum number of upload slots:",
                                value: engine.bind(\.maxUploads), range: 1...1000)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speed

private struct SpeedPrefs: View {
    @EnvironmentObject var engine: EngineSession

    var body: some View {
        Form {
            Section("Global Rate Limits") {
                KiBField(label: "Download (KiB/s, 0 = \u{221E}):", bytes: engine.bind(\.downloadLimit))
                KiBField(label: "Upload (KiB/s, 0 = \u{221E}):", bytes: engine.bind(\.uploadLimit))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - BitTorrent

private struct BitTorrentPrefs: View {
    @EnvironmentObject var engine: EngineSession

    var body: some View {
        Form {
            Section("Network") {
                Toggle("Enable DHT (decentralized network)", isOn: engine.bind(\.enableDHT))
                Toggle("Enable Local Peer Discovery", isOn: engine.bind(\.enableLSD))
                Toggle("Enable UPnP port forwarding", isOn: engine.bind(\.enableUPnP))
                Toggle("Enable NAT-PMP port forwarding", isOn: engine.bind(\.enableNATPMP))
                Picker("Encryption mode:", selection: engine.bind(\.encryption)) {
                    Text("Prefer encryption").tag(0)
                    Text("Require encryption").tag(1)
                    Text("Disable encryption").tag(2)
                }
            }
            Section("Torrent Queueing") {
                Toggle("Enable queueing", isOn: engine.bind(\.queueingEnabled))
                Group {
                    LabeledIntField(label: "Maximum active downloads:",
                                    value: engine.bind(\.maxActiveDownloads), range: 1...1000)
                    LabeledIntField(label: "Maximum active uploads:",
                                    value: engine.bind(\.maxActiveUploads), range: 1...1000)
                    LabeledIntField(label: "Maximum active torrents:",
                                    value: engine.bind(\.maxActiveTotal), range: 1...1000)
                }
                .disabled(!engine.settings.queueingEnabled)
            }
            Section("Seeding Limits") {
                RatioField(label: "Stop seeding at ratio (0 = \u{221E}):",
                           value: engine.bind(\.shareRatioLimit))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Field helpers

private struct LabeledIntField: View {
    let label: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: $value, format: .number)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Stepper("", value: $value, in: range).labelsHidden()
        }
    }
}

/// Edits a bytes/sec setting using KiB/s in the UI.
private struct KiBField: View {
    let label: String
    @Binding var bytes: Int

    private var kib: Binding<Int> {
        Binding(get: { bytes / 1024 }, set: { bytes = max(0, $0) * 1024 })
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: kib, format: .number)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Stepper("", value: kib, in: 0...1_000_000).labelsHidden()
        }
    }
}

private struct RatioField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Stepper("", value: $value, in: 0...100, step: 0.5).labelsHidden()
        }
    }
}
