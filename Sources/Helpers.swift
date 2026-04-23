import Foundation

func formatSpeed(_ bps: Int64) -> String {
    guard bps > 0 else { return "0 KB/s" }
    let kb = Double(bps) / 1024
    if kb < 1024 { return String(format: "%.1f KB/s", kb) }
    return String(format: "%.1f MB/s", kb / 1024)
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatETA(_ seconds: Int) -> String {
    guard seconds > 0, seconds < 8_640_000 else { return "∞" }
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}
