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
    }
}
