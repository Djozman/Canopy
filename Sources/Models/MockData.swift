// MockData.swift — drives the SwiftUI prototype without a real libtorrent session.

import Foundation

extension TorrentStatus {
    static let mockList: [TorrentStatus] = [
        TorrentStatus(id: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", name: "Ubuntu 24.04 LTS Desktop amd64",
                      savePath: "~/Downloads", totalSize: 5_400_000_000, totalDone: 5_400_000_000,
                      totalUploaded: 2_100_000_000, downloadRate: 0, uploadRate: 45_000,
                      progress: 1.0, numSeeds: 120, numPeers: 0, etaSeconds: -1,
                      state: .seeding, isPaused: false, errorMessage: nil, handle: nil),

        TorrentStatus(id: "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3", name: "Arch Linux 2026.05.01 x86_64",
                      savePath: "~/Downloads", totalSize: 900_000_000, totalDone: 621_000_000,
                      totalUploaded: 150_000_000, downloadRate: 2_400_000, uploadRate: 80_000,
                      progress: 0.69, numSeeds: 34, numPeers: 8, etaSeconds: 117,
                      state: .downloading, isPaused: false, errorMessage: nil, handle: nil),

        TorrentStatus(id: "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4", name: "Debian 12 netinstall iso",
                      savePath: "~/Downloads", totalSize: 400_000_000, totalDone: 0,
                      totalUploaded: 0, downloadRate: 0, uploadRate: 0,
                      progress: 0.0, numSeeds: 0, numPeers: 0, etaSeconds: -1,
                      state: .downloading, isPaused: true, errorMessage: nil, handle: nil),

        TorrentStatus(id: "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5", name: "Fedora Workstation 41",
                      savePath: "~/Downloads", totalSize: 2_100_000_000, totalDone: 2_100_000_000,
                      totalUploaded: 800_000_000, downloadRate: 0, uploadRate: 120_000,
                      progress: 1.0, numSeeds: 75, numPeers: 2, etaSeconds: -1,
                      state: .seeding, isPaused: false, errorMessage: nil, handle: nil),

        TorrentStatus(id: "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6", name: "OpenBSD 7.5 amd64",
                      savePath: "~/Downloads", totalSize: 600_000_000, totalDone: 42_000_000,
                      totalUploaded: 0, downloadRate: 800_000, uploadRate: 0,
                      progress: 0.07, numSeeds: 5, numPeers: 1, etaSeconds: 698,
                      state: .checkingFiles, isPaused: false, errorMessage: nil, handle: nil),

        TorrentStatus(id: "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1", name: "NixOS 24.11 minimal ISO",
                      savePath: "~/Downloads", totalSize: 1_200_000_000, totalDone: 0,
                      totalUploaded: 0, downloadRate: 0, uploadRate: 0,
                      progress: 0.0, numSeeds: 0, numPeers: 0, etaSeconds: -1,
                      state: .downloading, isPaused: false,
                      errorMessage: "Tracker: connection timed out", handle: nil),
    ]
}
