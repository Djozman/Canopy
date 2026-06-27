import SwiftUI

struct ProgressCell: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            Text(String(format: "%.0f%%", progress * 100))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
