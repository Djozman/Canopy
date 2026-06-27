import Foundation

struct AppSettings: Codable, Equatable {
    var defaultSavePath: String
    var listenPort: Int = 6881
    var downloadLimit: Int = 0   // bytes/sec, 0 = unlimited
    var uploadLimit: Int = 0     // bytes/sec, 0 = unlimited

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
