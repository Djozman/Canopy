import Foundation
import Combine

/// Drives multi-engine torrent search using the registered SearchPlugins.
@MainActor
final class SearchManager: ObservableObject {
    @Published var query: String = ""
    @Published var category: SearchCategory = .all
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published var enabledEngines: Set<String>

    let plugins: [any SearchPlugin] = allSearchPlugins

    private static let key = "canopy.search.enabled"

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.key) as? [String] {
            enabledEngines = Set(saved)
        } else {
            enabledEngines = Set(allSearchPlugins.map { $0.name })
        }
    }

    func toggle(_ engine: String) {
        if enabledEngines.contains(engine) { enabledEngines.remove(engine) }
        else { enabledEngines.insert(engine) }
        UserDefaults.standard.set(Array(enabledEngines), forKey: Self.key)
    }

    func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let cat = category
        let active = plugins.filter { enabledEngines.contains($0.name) }
        guard !active.isEmpty else { results = []; return }

        isSearching = true
        results = []

        var collected: [SearchResult] = []
        await withTaskGroup(of: [SearchResult].self) { group in
            for plugin in active {
                group.addTask { await plugin.search(q, category: cat) }
            }
            for await batch in group { collected.append(contentsOf: batch) }
        }
        results = collected.sorted { $0.seeders > $1.seeders }
        isSearching = false
    }

    func clear() { results = []; query = "" }
}
