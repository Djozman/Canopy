import Foundation
import LibtorrentKit

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func speed(_ value: Int64) -> String {
        guard value > 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary) + "/s"
    }

    static func eta(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "\u{221E}" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: TimeInterval(seconds)) ?? "\u{2014}"
    }

    static func duration(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "\u{2014}" }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        f.unitsStyle = .abbreviated
        return f.string(from: TimeInterval(seconds)) ?? "\u{2014}"
    }

    static func date(_ unixSeconds: Int64) -> String {
        guard unixSeconds > 0 else { return "\u{2014}" }
        let d = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    static func ratio(_ r: Double) -> String {
        String(format: "%.2f", r)
    }

    static func stateLabel(_ t: Torrent) -> String {
        if t.paused { return "Paused" }
        switch t.state {
        case .downloading: return "Downloading"
        case .downloadingMetadata: return "Fetching metadata"
        case .finished: return "Finished"
        case .seeding: return "Seeding"
        case .checkingFiles: return "Checking"
        case .checkingResumeData: return "Checking resume"
        case .error: return "Error"
        default: return "\u{2014}"
        }
    }
}
