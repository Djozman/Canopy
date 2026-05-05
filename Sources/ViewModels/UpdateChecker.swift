// UpdateChecker.swift — polls GitHub releases for new versions

import Foundation
import AppKit

@MainActor
public final class UpdateChecker: ObservableObject {
    public enum InstallState: Equatable {
        case idle
        case downloading
        case mounting
        case copying
        case relaunching
        case error(String)
    }

    @Published public private(set) var updateAvailable = false
    @Published public private(set) var latestVersion: String?
    @Published public private(set) var downloadURL: String?
    @Published public private(set) var isChecking = false
    @Published public private(set) var installState: InstallState = .idle

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

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return }

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
                if let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) {
                    downloadURL = dmg.browserDownloadURL
                } else if let first = release.assets.first {
                    downloadURL = first.browserDownloadURL
                }
            }
        } catch {}
    }

    public func downloadAndInstall() {
        guard installState == .idle else { return }
        guard let urlStr = downloadURL, let url = URL(string: urlStr) else {
            installState = .error("No download URL available")
            return
        }
        installState = .downloading

        Task.detached { [weak self] in
            await self?.performInstall(url: url)
        }
    }

    public func resetError() {
        if case .error = installState { installState = .idle }
    }

    private nonisolated func performInstall(url: URL) async {
        do {
            let (downloadedURL, _) = try await URLSession.shared.download(from: url)
            let stableURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("canopy_update_\(UUID().uuidString.prefix(8)).dmg")
            try FileManager.default.moveItem(at: downloadedURL, to: stableURL)

            await MainActor.run { [weak self] in self?.installState = .mounting }

            let mountPoint = try Self.mountDMG(at: stableURL.path)
            let srcAppPath = "\(mountPoint)/Canopy.app"
            guard FileManager.default.fileExists(atPath: srcAppPath) else {
                _ = try? Self.detachVolume(mountPoint)
                throw UpdateError.message("Canopy.app not found inside the downloaded DMG")
            }

            await MainActor.run { [weak self] in self?.installState = .copying }

            let pid = ProcessInfo.processInfo.processIdentifier
            let scriptPath = "/tmp/canopy_update.sh"
            let script = """
            #!/bin/bash
            set -u
            for _ in $(seq 1 200); do
                kill -0 \(pid) 2>/dev/null || break
                sleep 0.1
            done
            rm -rf '/Applications/Canopy.app'
            cp -R '\(srcAppPath)' '/Applications/Canopy.app'
            xattr -d -r com.apple.quarantine '/Applications/Canopy.app' 2>/dev/null || true
            codesign -s - -f '/Applications/Canopy.app' 2>/dev/null || true
            hdiutil detach '\(mountPoint)' -force >/dev/null 2>&1 || true
            rm -f '\(stableURL.path)'
            rm -f '$0'
            open '/Applications/Canopy.app'
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: scriptPath)

            let proc = Process()
            proc.launchPath = "/bin/bash"
            proc.arguments = ["-c", "nohup '\(scriptPath)' >/dev/null 2>&1 &"]
            try proc.run()
            proc.waitUntilExit()

            await MainActor.run { [weak self] in
                self?.installState = .relaunching
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.terminate(nil)
                }
            }
        } catch {
            let msg = (error as? UpdateError)?.message ?? error.localizedDescription
            await MainActor.run { [weak self] in self?.installState = .error(msg) }
        }
    }

    private static func mountDMG(at path: String) throws -> String {
        let proc = Process()
        proc.launchPath = "/usr/bin/hdiutil"
        proc.arguments = ["attach", path, "-nobrowse", "-readonly", "-plist"]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw UpdateError.message("hdiutil attach failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.message("Could not parse hdiutil plist output")
        }
        guard let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.message("DMG mounted but no mount point reported")
        }
        return mountPoint
    }

    private static func detachVolume(_ mountPoint: String) throws {
        let proc = Process()
        proc.launchPath = "/usr/bin/hdiutil"
        proc.arguments = ["detach", mountPoint, "-force"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
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

private enum UpdateError: Error {
    case message(String)
    var message: String {
        switch self { case .message(let m): return m }
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
