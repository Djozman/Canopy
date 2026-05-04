// SettingsView.swift

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("downloadDir")       private var downloadDir    = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    @AppStorage("downloadLimit")     private var downloadLimit  = 0
    @AppStorage("uploadLimit")       private var uploadLimit    = 0
    @AppStorage("maxActiveDown")     private var maxActiveDown  = 3
    @AppStorage("maxActiveSeed")     private var maxActiveSeed  = 5
    @AppStorage("enableDHT")         private var enableDHT      = true
    @AppStorage("enableLSD")         private var enableLSD      = true
    @AppStorage("enableUPnP")        private var enableUPnP     = true
    @AppStorage("enableNatPMP")      private var enableNatPMP   = true
    @AppStorage("listenPort")        private var listenPort     = 6881
    @AppStorage("anonymousMode")     private var anonymousMode  = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Downloads") {
                    LabeledContent("Default save path") {
                        TextField("Path", text: $downloadDir)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 200)
                    }
                }

                Section("Speed Limits") {
                    LabeledContent("Download limit (KiB/s, 0=∞)") {
                        TextField("", value: $downloadLimit, format: .number)
                            .frame(width: 80)
                    }
                    LabeledContent("Upload limit (KiB/s, 0=∞)") {
                        TextField("", value: $uploadLimit, format: .number)
                            .frame(width: 80)
                    }
                }

                Section("Queue") {
                    Stepper("Max active downloads: \(maxActiveDown)", value: $maxActiveDown, in: 1...99)
                    Stepper("Max active seeds: \(maxActiveSeed)",     value: $maxActiveSeed,  in: 1...99)
                }

                Section("Connection") {
                    LabeledContent("Listen port") {
                        TextField("", value: $listenPort, format: .number)
                            .frame(width: 80)
                    }
                    Toggle("Enable DHT",          isOn: $enableDHT)
                    Toggle("Enable Local Service Discovery", isOn: $enableLSD)
                    Toggle("Enable UPnP",         isOn: $enableUPnP)
                    Toggle("Enable NAT-PMP",       isOn: $enableNatPMP)
                    Toggle("Anonymous mode",       isOn: $anonymousMode)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Preferences")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 540)
    }
}
