//
//  SafariSupport.swift
//  MultiSub
//
//  Safari-facing helpers shared by the onboarding page and 一般設定: the
//  extension's enabled state, opening its settings pane, opening Netflix
//  in Safari specifically, and plain-language text for SafariServices'
//  errors.
//

import AppKit
import SafariServices
import SwiftUI

/// The Safari extension is always "<app bundle id>.Extension" (see MultiSub.xcconfig).
let extensionBundleIdentifier = AppIdentity.extensionBundleID

enum SafariExtensionState: Equatable {
    case checking
    case enabled
    case disabled
    /// Safari couldn't report a state (e.g. the extension isn't registered
    /// yet because Safari hasn't seen this build). Carries what the user
    /// can do about it (`SafariErrorText.guidance`), never the raw error.
    case unknown(String)

    var isEnabled: Bool { self == .enabled }

    var color: Color {
        switch self {
        case .checking: return .secondary
        case .enabled: return .green
        case .disabled: return .orange
        case .unknown: return .red
        }
    }

    var text: String {
        switch self {
        case .checking: return "檢查中…"
        case .enabled: return "已啟用"
        case .disabled: return "尚未啟用"
        case .unknown: return "無法取得狀態"
        }
    }

    /// What to do next, shown under the status line.
    var guidance: String? {
        if case .unknown(let guidance) = self { return guidance }
        return nil
    }

    /// Asks Safari for the current state. Bridged through a continuation that
    /// resumes with plain values: the completion handler runs on an arbitrary
    /// queue, and `SFSafariExtensionState` itself isn't Sendable.
    static func fetch() async -> SafariExtensionState {
        await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, error in
                if let state {
                    continuation.resume(returning: state.isEnabled ? .enabled : .disabled)
                } else {
                    continuation.resume(returning: .unknown(SafariErrorText.guidance(for: error)))
                }
            }
        }
    }
}

/// Links shown in 一般設定 › 關於 and on the onboarding page. Set per build in
/// MultiSub.xcconfig (MULTISUB_PRIVACY_URL / MULTISUB_SOURCE_URL).
enum MultiSubLinks {
    static var privacyPolicy: URL? { url(forInfoKey: "MultiSubPrivacyPolicyURL") }
    static var sourceCode: URL? { url(forInfoKey: "MultiSubSourceURL") }
    static var issues: URL? { sourceCode?.appendingPathComponent("issues") }

    private static func url(forInfoKey key: String) -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              raw.hasPrefix("https://") else { return nil }
        return URL(string: raw)
    }
}

/// Plain-language guidance for SafariServices' errors, which on their own
/// read like "SFErrorDomain error 1". Codes are `SFErrorCode` from
/// SafariServices/SFError.h.
enum SafariErrorText {
    private static let restartSafari = "請結束 Safari（⌘Q）再重新打開，然後回到這裡。"

    static func guidance(for error: Error?) -> String {
        guard let error else { return "Safari 沒有回報原因。" + restartSafari }
        let nsError = error as NSError
        if nsError.domain == SFErrorDomain, let code = SFErrorCode(rawValue: nsError.code) {
            switch code {
            case .noExtensionFound:
                // Safari hasn't picked up this copy of the app yet: it scans
                // for extensions when it launches.
                return "Safari 還沒抓到 MultiSub。" + restartSafari
            case .loadingInterrupted:
                return "Safari 讀取 MultiSub 時中斷了。" + restartSafari
            case .noAttachmentFound:
                return "Safari 讀不到 MultiSub 的延伸功能。" + restartSafari
            @unknown default:
                break
            }
        }
        // Anything else: the same advice, plus the code for a bug report.
        return "Safari 沒有回應。" + restartSafari + "（\(nsError.domain) \(nsError.code)）"
    }
}

enum SafariLauncher {
    /// Opens Safari's 設定 › 延伸功能 with MultiSub selected. Returns what to
    /// tell the user when Safari can't (nil when it opened).
    static func openExtensionSettings() async -> String? {
        await withCheckedContinuation { continuation in
            SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { error in
                continuation.resume(returning: error.map { SafariErrorText.guidance(for: $0) })
            }
        }
    }

    /// Opens Netflix's home page in Safari even when another browser is the
    /// default: MultiSub only exists as a Safari extension, so the default
    /// browser would show Netflix without any of it. Falls back to the
    /// default browser only if Safari can't be located at all.
    static func openNetflix() {
        guard let url = URL(string: "https://www.netflix.com/browse") else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: configuration) { _, _ in }
    }
}

/// Status on the left, the button to fix it on the right: one Form row,
/// shared by the onboarding page and 一般設定. When Safari can't report the
/// state, or can't open its settings, what to do about it goes underneath.
@MainActor
struct SafariExtensionRow: View {
    let state: SafariExtensionState

    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                StatusDot(color: state.color, text: state.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("打開 Safari 設定") {
                    Task { openError = await SafariLauncher.openExtensionSettings() }
                }
            }
            if let guidance = openError ?? state.guidance {
                Text(guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A state Safari did report means the earlier failure is over.
        .onChange(of: state) { _, newValue in
            if newValue == .enabled || newValue == .disabled { openError = nil }
        }
    }
}
