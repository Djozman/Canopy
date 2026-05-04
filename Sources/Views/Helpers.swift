// Helpers.swift — shared formatting utilities

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
    guard seconds >= 0 else { return "∞" }
    if seconds < 60    { return "\(seconds)s" }
    if seconds < 3600  { return "\(seconds / 60)m \(seconds % 60)s" }
    let h = seconds / 3600; let m = (seconds % 3600) / 60
    return "\(h)h \(m)m"
}

func formatRatio(uploaded: Int64, downloaded: Int64) -> String {
    guard downloaded > 0 else { return "∞" }
    return String(format: "%.3f", Double(uploaded) / Double(downloaded))
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
