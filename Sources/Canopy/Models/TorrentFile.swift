import Foundation
import LibtorrentKit

struct TorrentFile: Identifiable, Hashable {
    let id: Int
    var path: String
    var size: Int64
    var downloaded: Int64
    var progress: Double
    var priority: Int   // libtorrent 0..7 (0 = skip)

    var name: String { (path as NSString).lastPathComponent }

    var priorityLabel: String {
        switch priority {
        case 0: return "Do not download"
        case 1...4: return "Normal"
        case 5...6: return "High"
        default: return "Maximum"
        }
    }

    init(_ e: LTFileEntry) {
        id = e.index
        path = e.path
        size = e.size
        downloaded = e.downloaded
        progress = e.progress
        priority = Int(e.priority)
    }
}
