// UpdateChecker.swift — polls GitHub releases for new versions

import Foundation
import AppKit

@MainActor
public final class UpdateChecker: ObservableObject {
    @Published public private(set) var updateAvailable = false
    @Published public private(set) var latestVersion: String?
    @Published public private(set) var downloadURL: String?
    @Published public private(set) var isChecking = false

    private let owner: String
    private let repo: String
    private let currentVersion: String

    public init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    public func checkForUpdate() async {
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tagName.replacingOccurrences(of: "v", with: "")

            if compareVersions(remoteVersion, isGreaterThan: currentVersion) {
                latestVersion = release.tagName
                updateAvailable = true
                // Find the DMG asset
                if let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) {
                    downloadURL = dmg.browserDownloadURL
                } else if let first = release.assets.first {
                    downloadURL = first.browserDownloadURL
                }
            }
        } catch {
            // Silently fail — no network or rate limited
        }
    }

    public func downloadAndInstall() {
        guard let urlStr = downloadURL, let url = URL(string: urlStr) else { return }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] localURL, _, error in
            guard let self, let localURL = localURL, error == nil else { return }
            DispatchQueue.main.async {
                self.installDMG(at: localURL)
            }
        }
        task.resume()
    }

    private func installDMG(at localURL: URL) {
        // Mount the DMG
        let process = Process()
        process.launchPath = "/usr/bin/hdiutil"
        process.arguments = ["attach", localURL.path, "-nobrowse", "-readonly"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.launch()
        process.waitUntilExit()

        // Find the mounted volume
        let finder = Process()
        finder.launchPath = "/usr/bin/env"
        finder.arguments = ["bash", "-c", "ls /Volumes/ | grep -i canopy | head -1"]
        let pipe = Pipe()
        finder.standardOutput = pipe
        finder.launch()
        finder.waitUntilExit()
        let volumeName = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !volumeName.isEmpty else { return }

        let appPath = "/Volumes/\(volumeName)/Canopy.app"
        let destPath = "/Applications/Canopy.app"

        // Replace old app
        let fm = FileManager.default
        if fm.fileExists(atPath: destPath) {
            try? fm.removeItem(atPath: destPath)
        }
        try? fm.copyItem(atPath: appPath, toPath: destPath)

        // Eject
        let detach = Process()
        detach.launchPath = "/usr/bin/hdiutil"
        detach.arguments = ["detach", "/Volumes/\(volumeName)", "-force"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        detach.launch()
        detach.waitUntilExit()

        // Relaunch new version, quit current
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let relaunch = Process()
            relaunch.launchPath = "/usr/bin/open"
            relaunch.arguments = [destPath]
            relaunch.launch()
        }
        NSApp.terminate(nil)
    }

    private func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
