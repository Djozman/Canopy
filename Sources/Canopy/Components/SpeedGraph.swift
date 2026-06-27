import SwiftUI

/// A lightweight dual-series line chart (download + upload) drawn with Canvas.
struct SpeedGraph: View {
    let download: [Int64]
    let upload: [Int64]
    var downColor: Color = .green
    var upColor: Color = .blue

    private var maxValue: Double {
        let m = max(download.max() ?? 0, upload.max() ?? 0)
        return Double(max(m, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                legend(downColor, "Download \(Formatters.speed(download.last ?? 0))")
                legend(upColor, "Upload \(Formatters.speed(upload.last ?? 0))")
                Spacer()
                Text("Peak \(Formatters.speed(Int64(maxValue)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Canvas { ctx, size in
                drawGrid(ctx: ctx, size: size)
                drawSeries(upload, color: upColor, ctx: ctx, size: size, fill: true)
                drawSeries(download, color: downColor, ctx: ctx, size: size, fill: true)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption)
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        var p = Path()
        let rows = 4
        for i in 0...rows {
            let y = size.height * CGFloat(i) / CGFloat(rows)
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 1)
    }

    private func drawSeries(_ data: [Int64], color: Color, ctx: GraphicsContext, size: CGSize, fill: Bool) {
        guard data.count > 1 else { return }
        let maxV = maxValue
        let stepX = size.width / CGFloat(max(data.count - 1, 1))
        func point(_ i: Int) -> CGPoint {
            let v = Double(data[i]) / maxV
            return CGPoint(x: CGFloat(i) * stepX,
                           y: size.height - CGFloat(v) * size.height)
        }
        var line = Path()
        line.move(to: point(0))
        for i in 1..<data.count { line.addLine(to: point(i)) }

        if fill {
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.15)))
        }
        ctx.stroke(line, with: .color(color), lineWidth: 1.5)
    }
}
