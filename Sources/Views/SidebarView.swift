// SidebarView.swift

import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TorrentListViewModel

    var body: some View {
        List(FilterCategory.allCases, id: \.self, selection: $vm.selectedFilter) { cat in
            Label {
                HStack {
                    Text(cat.rawValue)
                    Spacer()
                    let count = vm.filterCount(cat)
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            } icon: {
                Image(systemName: iconName(for: cat))
                    .foregroundStyle(iconColor(for: cat))
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("qBittorrent")
    }

    private func iconName(for cat: FilterCategory) -> String {
        switch cat {
        case .all:         return "tray.2"
        case .downloading: return "arrow.down.circle"
        case .seeding:     return "arrow.up.circle"
        case .paused:      return "pause.circle"
        case .finished:    return "checkmark.circle"
        case .error:       return "exclamationmark.triangle"
        }
    }

    private func iconColor(for cat: FilterCategory) -> Color {
        switch cat {
        case .all:         return .primary
        case .downloading: return .blue
        case .seeding:     return .green
        case .paused:      return .secondary
        case .finished:    return .green.opacity(0.8)
        case .error:       return .red
        }
    }
}
