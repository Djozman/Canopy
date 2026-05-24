// Helpers.swift — shared formatting utilities and helpers

import Foundation
import SwiftUI

// MARK: - Byte formatting

func formatBytes(_ bytes: Int64) -> String {
    let kb = 1_024.0
    let mb = kb * 1_024
    let gb = mb * 1_024
    let tb = gb * 1_024
    let d = Double(bytes)
    switch d {
    case ..<kb:          return "\(bytes) B"
    case ..<mb:          return String(format: "%.1f KiB", d / kb)
    case ..<gb:          return String(format: "%.1f MiB", d / mb)
    case ..<tb:          return String(format: "%.2f GiB", d / gb)
    default:             return String(format: "%.2f TiB", d / tb)
    }
}

func formatSpeed(_ bytesPerSec: Int) -> String {
    formatBytes(Int64(bytesPerSec)) + "/s"
}

func formatETA(_ seconds: Int64) -> String {
    guard seconds >= 0, seconds < 360_000 else { return "\u{221E}" }
    if seconds < 60    { return "\(seconds)s" }
    if seconds < 3600  { return "\(seconds / 60)m \(seconds % 60)s" }
    let h = seconds / 3600; let m = (seconds % 3600) / 60
    return "\(h)h \(m)m"
}

func formatRatio(uploaded: Int64, downloaded: Int64) -> String {
    guard downloaded > 0 else { return "∞" }
    return String(format: "%.3f", Double(uploaded) / Double(downloaded))
}

// MARK: - File icon helper

func fileIcon(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "mkv","mp4","avi","mov","webm": return "film"
    case "mp3","flac","wav","m4a":       return "music.note"
    case "iso","img","dmg":              return "opticaldisc"
    case "zip","rar","7z","tar","gz":   return "doc.zipper"
    case "txt","md","nfo":              return "doc.text"
    case "jpg","png","gif","webp":      return "photo"
    default:                              return "doc"
    }
}

// MARK: - State color

extension TorrentState {
    var color: Color {
        switch self {
        case .downloading, .downloadingMetadata: return .blue
        case .seeding:                           return .green
        case .finished:                          return .green.opacity(0.7)
        case .checkingFiles, .checkingResumeData,
             .allocating:                        return .orange
        }
    }
}

extension TorrentStatus {
    var statusColor: Color {
        if errorMessage != nil { return .red }
        if isPaused            { return .secondary }
        return state.color
    }

    var statusLabel: String {
        if let err = errorMessage { return "Error: \(err)" }
        if isPaused               { return "Paused" }
        return state.label
    }
}

// MARK: - Sort button builder

@ViewBuilder
func sortButton(
    _ title: String,
    asc: FileSortOrder,
    desc: FileSortOrder,
    sortOrder: Binding<FileSortOrder>,
    onSort: @escaping (FileSortOrder) -> Void,
    minWidth: CGFloat
) -> some View {
    Button {
        let newOrder = sortOrder.wrappedValue == asc ? desc : asc
        sortOrder.wrappedValue = newOrder
        onSort(newOrder)
    } label: {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if sortOrder.wrappedValue == asc {
                Image(systemName: "chevron.up").font(.system(size: 8))
            } else if sortOrder.wrappedValue == desc {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
        .padding(.horizontal, 4)
    }
    .buttonStyle(.plain)
}
