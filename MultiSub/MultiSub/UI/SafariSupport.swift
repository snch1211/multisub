//
//  SafariSupport.swift
//  MultiSub
//
//  Safari-facing helpers shared by the onboarding page and 一般設定: the
//  extension's enabled state, opening its settings pane, and opening Netflix
//  in Safari specifically.
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
    /// yet because Safari hasn't seen this build). Carries the system's reason.
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
        case .unknown(let reason): return "無法取得狀態（\(reason)）"
        }
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
                    continuation.resume(returning: .unknown(error?.localizedDescription ?? "未知錯誤"))
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

enum SafariLauncher {
    /// Opens Safari's 設定 › 延伸功能 with MultiSub selected.
    static func openExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
    }

    /// Opens Netflix in Safari even when another browser is the default:
    /// MultiSub only exists as a Safari extension, so the default browser
    /// would show Netflix without any of it. Falls back to the default
    /// browser only if Safari can't be located at all.
    static func openNetflix() {
        guard let url = URL(string: "https://www.netflix.com") else { return }
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
/// shared by the onboarding page and 一般設定.
@MainActor
struct SafariExtensionRow: View {
    let state: SafariExtensionState

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: state.color, text: state.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("打開 Safari 設定") { SafariLauncher.openExtensionSettings() }
        }
    }
}
