// SidebarView.swift — transfer filters and visible Canopy identity

import AppKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: TorrentListViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit()
                    .frame(width: 42, height: 42)
                    .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Canopy").font(.title3.weight(.semibold))
                    Text("BitTorrent Client · 3.0.0")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            Divider()

            List(selection: $vm.selectedFilter) {
                Section("Status") {
                    ForEach(FilterCategory.allCases, id: \.self) { category in
                        Label {
                            HStack {
                                Text(category.rawValue)
                                Spacer()
                                Text("\(vm.filterCount(category))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        } icon: {
                            Image(systemName: iconName(for: category))
                                .foregroundStyle(iconColor(for: category))
                                .frame(width: 18)
                        }
                        .tag(category)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 7) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("libtorrent session active")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func iconName(for category: FilterCategory) -> String {
        switch category {
        case .all: return "square.stack.3d.up"
        case .downloading: return "arrow.down.circle.fill"
        case .seeding: return "arrow.up.circle.fill"
        case .paused: return "pause.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func iconColor(for category: FilterCategory) -> Color {
        switch category {
        case .all: return .accentColor
        case .downloading: return .blue
        case .seeding, .finished: return .green
        case .paused: return .secondary
        case .error: return .red
        }
    }
}
