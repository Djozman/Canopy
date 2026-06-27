import Foundation
import Combine

struct LogEntry: Identifiable, Hashable {
    enum Level: String { case info = "INFO", warning = "WARN", error = "ERROR" }
    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

/// A lightweight in-app log surfaced by the Log window.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published private(set) var entries: [LogEntry] = []
    private let limit = 1000

    func log(_ message: String, level: LogEntry.Level = .info) {
        entries.append(LogEntry(date: Date(), level: level, message: message))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        NSLog("[\(level.rawValue)] \(message)")
    }

    func clear() { entries.removeAll() }
}
