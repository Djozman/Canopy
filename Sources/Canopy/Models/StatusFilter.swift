import Foundation
import LibtorrentKit

enum StatusFilter: String, CaseIterable, Identifiable {
    case all, downloading, seeding, completed, active, inactive, paused, checking, errored

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .seeding: return "Seeding"
        case .completed: return "Completed"
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .paused: return "Paused"
        case .checking: return "Checking"
        case .errored: return "Errored"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .completed: return "checkmark.circle"
        case .active: return "bolt.circle"
        case .inactive: return "moon.zzz"
        case .paused: return "pause.circle"
        case .checking: return "magnifyingglass.circle"
        case .errored: return "exclamationmark.triangle"
        }
    }

    func matches(_ t: Torrent) -> Bool {
        switch self {
        case .all:
            return true
        case .downloading:
            return !t.paused && (t.state == .downloading || t.state == .downloadingMetadata)
        case .seeding:
            return !t.paused && (t.state == .seeding || t.state == .finished)
        case .completed:
            return t.progress >= 1.0
        case .active:
            return t.downloadRate > 0 || t.uploadRate > 0
        case .inactive:
            return t.downloadRate == 0 && t.uploadRate == 0
        case .paused:
            return t.paused
        case .checking:
            return t.state == .checkingFiles || t.state == .checkingResumeData
        case .errored:
            return t.state == .error
        }
    }
}
