//
//  UpdateChecker.swift
//  MultiSub
//
//  Checks GitHub Releases for a newer version than the running app's own
//  `CFBundleShortVersionString`. App target only, and direct (DMG) builds
//  only: the Mac App Store build updates through the App Store, so this
//  whole file is compiled out under `APP_STORE`. The extension has no use
//  for `lastCheckedAt`, so it lives in this process's own `UserDefaults`
//  rather than in the shared config.json.
//

#if !APP_STORE
import Foundation

@Observable
@MainActor
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, htmlURL: URL, downloadURL: URL?)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastCheckedAt: Date?

    let currentVersion: String

    // The public repo's coordinates. While it has no release yet, `check`
    // gets a 404, which is exactly the "查無 release" path that needs
    // verifying before shipping, so this stays the real constant rather than
    // a dev stub.
    private static let repoPath = "snch1211/multisub"
    private static let lastCheckedDefaultsKey = "UpdateChecker.lastCheckedAt"
    private static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        if let stored = UserDefaults.standard.object(forKey: Self.lastCheckedDefaultsKey) as? Date {
            lastCheckedAt = stored
        }
    }

    /// Called once at launch (see `ContentView`'s `.task`). At most once a
    /// day — skips entirely if the stored
    /// `lastCheckedAt` is still within the interval, rather than checking and
    /// discarding the result, so a launch right after a manual check doesn't
    /// spend the user's GitHub API rate-limit budget for nothing.
    func checkOnLaunchIfDue() {
        if let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < Self.autoCheckInterval {
            return
        }
        Task { await check() }
    }

    func check() async {
        status = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoPath)/releases/latest") else {
            status = .failed("檢查失敗，請稍後再試")
            return
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            recordCheckAttempt()

            guard let http = response as? HTTPURLResponse else {
                status = .failed("檢查失敗，請稍後再試")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                status = http.statusCode == 404
                    ? .failed("尚無正式發布版本")
                    : .failed("檢查失敗，請稍後再試")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

            if Self.isNewer(latestVersion, than: currentVersion) {
                let dmgAsset = release.assets.first { $0.name.hasSuffix(".dmg") }
                status = .updateAvailable(
                    version: latestVersion,
                    htmlURL: URL(string: release.htmlURL) ?? url,
                    downloadURL: dmgAsset.flatMap { URL(string: $0.browserDownloadURL) }
                )
            } else {
                status = .upToDate
            }
        } catch {
            recordCheckAttempt()
            status = .failed("檢查失敗，請稍後再試")
        }
    }

    /// Stamped on every attempt (success or failure alike), not just
    /// successful ones — this doubles as the throttle `checkOnLaunchIfDue`
    /// reads, so a persistent offline/API failure doesn't retry every launch.
    private func recordCheckAttempt() {
        lastCheckedAt = Date()
        UserDefaults.standard.set(lastCheckedAt, forKey: Self.lastCheckedDefaultsKey)
    }

    private static func isNewer(_ candidate: String, than base: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let baseParts = base.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, baseParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let basePart = index < baseParts.count ? baseParts[index] : 0
            if candidatePart != basePart { return candidatePart > basePart }
        }
        return false
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}
#endif
