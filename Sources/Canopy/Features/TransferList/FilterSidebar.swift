import SwiftUI

struct FilterSidebar: View {
    @EnvironmentObject var engine: EngineSession
    @Binding var filter: TransferFilter

    var body: some View {
        List {
            Section("Status") {
                ForEach(StatusFilter.allCases) { f in
                    row(.status(f), title: f.title, systemImage: f.systemImage,
                       count: engine.torrents.filter { f.matches($0) }.count)
                }
            }

            Section("Categories") {
                row(.uncategorized, title: "Uncategorized", systemImage: "folder.badge.questionmark",
                    count: engine.torrents.filter { $0.category.isEmpty }.count)
                ForEach(engine.library.categories) { c in
                    row(.category(c.name), title: c.name, systemImage: "folder",
                        count: engine.torrents.filter { $0.category == c.name }.count)
                }
            }

            Section("Tags") {
                row(.untagged, title: "Untagged", systemImage: "tag.slash",
                    count: engine.torrents.filter { $0.tags.isEmpty }.count)
                ForEach(engine.library.tags, id: \.self) { t in
                    row(.tag(t), title: t, systemImage: "tag",
                        count: engine.torrents.filter { $0.tags.contains(t) }.count)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func row(_ value: TransferFilter, title: String, systemImage: String, count: Int) -> some View {
        Button {
            filter = value
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(filter == value ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
