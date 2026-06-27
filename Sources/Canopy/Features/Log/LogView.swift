import SwiftUI

struct LogView: View {
    @ObservedObject private var log = AppLog.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.date))
                                    .foregroundStyle(.secondary)
                                Text(entry.level.rawValue)
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 48, alignment: .leading)
                                Text(entry.message)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: log.entries.count) {
                    if let last = log.entries.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(log.entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .navigationTitle("Log")
        .frame(minWidth: 520, minHeight: 360)
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
