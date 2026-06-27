import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var engine: EngineSession

    init() {
        let settings = AppSettings.load()
        _engine = StateObject(wrappedValue: EngineSession(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear { engine.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
