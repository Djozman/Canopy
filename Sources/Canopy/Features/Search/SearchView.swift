import SwiftUI
import AppKit

struct SearchView: View {
    @EnvironmentObject var search: SearchManager
    @EnvironmentObject var engine: EngineSession

    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<SearchResult>] = [
        .init(\SearchResult.seeders, order: .reverse)
    ]

    private var sorted: [SearchResult] { search.results.sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            enginesBar
            Divider()
            resultsTable
            Divider()
            statusBar
        }
        .navigationTitle("Search")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search torrents\u{2026}", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await search.runSearch() } }
            Picker("", selection: $search.category) {
                ForEach(SearchCategory.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 160)
            Button {
                Task { await search.runSearch() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(search.isSearching || search.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private var enginesBar: some View {
        HStack(spacing: 14) {
            Text("Engines:").font(.caption).foregroundStyle(.secondary)
            ForEach(search.plugins, id: \.name) { plugin in
                Toggle(plugin.name, isOn: Binding(
                    get: { search.enabledEngines.contains(plugin.name) },
                    set: { _ in search.toggle(plugin.name) }
                ))
                .toggleStyle(.checkbox)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var resultsTable: some View {
        Table(sorted, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \SearchResult.name) { (r: SearchResult) in
                Text(r.name).lineLimit(1)
            }
            .width(min: 260, ideal: 380)
            TableColumn("Size", value: \SearchResult.size) { (r: SearchResult) in
                Text(verbatim: r.size >= 0 ? Formatters.bytes(r.size) : "\u{2014}")
            }
            .width(90)
            TableColumn("Seeds", value: \SearchResult.seeders) { (r: SearchResult) in
                Text(verbatim: "\(r.seeders)")
            }
            .width(60)
            TableColumn("Peers", value: \SearchResult.leechers) { (r: SearchResult) in
                Text(verbatim: "\(r.leechers)")
            }
            .width(60)
            TableColumn("Engine", value: \SearchResult.engine) { (r: SearchResult) in
                Text(r.engine).foregroundStyle(.secondary)
            }
            .width(120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Download") { download(ids) }
            if ids.count == 1, let r = sorted.first(where: { $0.id == ids.first }),
               let page = r.pageURL, let url = URL(string: page) {
                Button("Open Description Page") { NSWorkspace.shared.open(url) }
            }
        } primaryAction: { ids in
            download(ids)
        }
    }

    private var statusBar: some View {
        HStack {
            if search.isSearching {
                ProgressView().controlSize(.small)
                Text("Searching\u{2026}").foregroundStyle(.secondary)
            } else {
                Text("\(search.results.count) results").foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                download(selection)
            } label: {
                Label("Download Selected", systemImage: "arrow.down.circle")
            }
            .disabled(selection.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func download(_ ids: Set<UUID>) {
        for id in ids {
            guard let r = search.results.first(where: { $0.id == id }),
                  let link = r.downloadLink else { continue }
            engine.addFromRemote(link)
        }
    }
}
