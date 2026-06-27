import SwiftUI

struct FilterSidebar: View {
    @EnvironmentObject var engine: EngineSession
    @Binding var statusFilter: StatusFilter

    var body: some View {
        List {
            Section("Status") {
                ForEach(StatusFilter.allCases) { f in
                    Button {
                        statusFilter = f
                    } label: {
                        HStack {
                            Label(f.title, systemImage: f.systemImage)
                            Spacer()
                            Text("\(count(for: f))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(statusFilter == f
                        ? Color.accentColor.opacity(0.18) : Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    private func count(for f: StatusFilter) -> Int {
        engine.torrents.filter { f.matches($0) }.count
    }
}
