import Foundation

struct AppSettings: Codable, Equatable {
    // Downloads
    var defaultSavePath: String
    var startPaused: Bool = false

    // Connection
    var listenPort: Int = 6881
    var maxConnections: Int = 200      // 0 = unlimited (clamped to 200)
    var maxUploads: Int = 20           // 0 = unlimited

    // Speed (bytes/sec, 0 = unlimited)
    var downloadLimit: Int = 0
    var uploadLimit: Int = 0

    // BitTorrent / network features
    var enableDHT: Bool = true
    var enableLSD: Bool = true
    var enableUPnP: Bool = true
    var enableNATPMP: Bool = true
    var encryption: Int = 0            // 0 = enabled, 1 = forced, 2 = disabled

    // Queueing
    var queueingEnabled: Bool = false
    var maxActiveDownloads: Int = 3
    var maxActiveUploads: Int = 3
    var maxActiveTotal: Int = 5

    // Seeding limit (share ratio). 0 = unlimited; torrent pauses when reached.
    var shareRatioLimit: Double = 0

    private static let key = "canopy.settings"

    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Downloads")
        return AppSettings(defaultSavePath: downloads)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
