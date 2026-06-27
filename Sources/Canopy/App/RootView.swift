import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var engine: EngineSession

    var body: some View {
        TransferListView()
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification)) { _ in
                engine.saveAll()
            }
    }
}
