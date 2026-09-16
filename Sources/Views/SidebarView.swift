// SidebarView.swift — modern minimal navigation

import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TorrentListViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Brand
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Canopy")
                        .font(.system(size: 14, weight: .semibold))
                    Text("BitTorrent client")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            // Filters
            List(selection: $vm.selectedFilter) {
                Section("Transfers") {
                    ForEach(FilterCategory.allCases, id: \.self) { category in
                        Label {
                            HStack(spacing: 8) {
                                Text(category.rawValue)
                                    .font(.system(size: 13))
                                Spacer()
                                let count = vm.filterCount(category)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Color.secondary.opacity(0.12),
                                            in: Capsule()
                                        )
                                }
                            }
                        } icon: {
                            Image(systemName: iconName(for: category))
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 14))
                        }
                        .tag(category)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().opacity(0.4)

            // Session status
            HStack(spacing: 7) {
                Circle()
                    .fill(CanopyPalette.positive)
                    .frame(width: 6, height: 6)
                Text("Session active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
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
