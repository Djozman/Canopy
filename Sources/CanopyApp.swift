import SwiftUI

@main
struct CanopyApp: App {
    @State private var engine = TorrentEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .frame(minWidth: 700, minHeight: 400)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Separate window for adding a .torrent file. Re-opening just brings it forward.
        Window("Add Torrent", id: "add-torrent") {
            AddTorrentView().environment(engine)
        }
        .defaultSize(width: 540, height: 420)
        .windowResizability(.contentSize)

        // Separate small window for pasting a magnet URI; resizes itself larger when the
        // flow advances to the file-selection phase.
        Window("Add Magnet Link", id: "add-magnet") {
            MagnetView().environment(engine)
        }
        .defaultSize(width: 520, height: 360)
        .windowResizability(.contentSize)

        // Fallback file-selection window for magnets that resolved across an app restart
        // (i.e. were already added before this launch and just got their metadata now).
        Window("Choose Files", id: "file-selection") {
            FileSelectionWindowView().environment(engine)
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(engine)
        }
    }
}
