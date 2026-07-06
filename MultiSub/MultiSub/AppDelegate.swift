//
//  AppDelegate.swift
//  MultiSub
//

import Cocoa

extension Notification.Name {
    /// D1: posted when the app is asked to open a `multisub://` URL while
    /// already running. `userInfo["url"]` carries the URL.
    static let multiSubOpenURL = Notification.Name("MultiSubOpenURL")
}

/// Entry point is `MultiSubApp` (Phase G); this is installed via
/// `@NSApplicationDelegateAdaptor` for lifecycle hooks SwiftUI's `Scene`
/// doesn't cover (URL opens arriving before `AppRouter` can observe them).
class AppDelegate: NSObject, NSApplicationDelegate {

    /// D1: holds a `multisub://` URL that arrived before `AppRouter`
    /// finished initializing and could start observing `.multiSubOpenURL` —
    /// macOS can call `application(_:open:)` either before or after
    /// `applicationDidFinishLaunching` depending on whether the app was just
    /// launched by the URL, so a notification alone could be missed.
    /// `AppRouter.init` drains and clears this.
    static var pendingOpenURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startIdleUnloadTimer()
    }

    /// M5: the App target also loads the shared `Translator` model
    /// (vocabulary extraction, test-translation in Settings), so it needs
    /// the same `idleUnloadMinutes` policy as the appex. Unlike the appex
    /// (an `NSExtensionRequestHandling` host the OS suspends between
    /// requests — see `Translator.checkIdleUnload()`'s doc comment for why
    /// a timer doesn't work there), the App is a normal GUI process that
    /// keeps running, so a real repeating timer works fine here. Runs for
    /// the lifetime of the App; never cancelled.
    private func startIdleUnloadTimer() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(60))
                await Translator.shared.checkIdleUnload()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Self.pendingOpenURL = url
        NotificationCenter.default.post(name: .multiSubOpenURL, object: nil, userInfo: ["url": url])
    }

}
