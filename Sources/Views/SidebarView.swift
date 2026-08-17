// SidebarView.swift — quiet native navigation

import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TorrentListViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Canopy")
                        .font(.headline)
                    Text("BitTorrent client")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            Divider()

            List(selection: $vm.selectedFilter) {
                Section("Transfers") {
                    ForEach(FilterCategory.allCases, id: \.self) { category in
                        Label {
                            HStack(spacing: 8) {
                                Text(category.rawValue)
                                Spacer()
                                Text("\(vm.filterCount(category))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: iconName(for: category))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .tag(category)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 7) {
                Circle()
                    .fill(CanopyPalette.positive)
                    .frame(width: 6, height: 6)
                Text("Session active")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(.bar)
    }

    private func iconName(for category: FilterCategory) -> String {
        switch category {
        case .all: return "square.stack.3d.up"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
