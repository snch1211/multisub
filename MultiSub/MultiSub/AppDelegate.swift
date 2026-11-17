//
//  AppDelegate.swift
//  MultiSub
//

import Cocoa

extension Notification.Name {
    /// Posted when the app is asked to open a `multisub://` URL while
    /// already running. `userInfo["url"]` carries the URL.
    static let multiSubOpenURL = Notification.Name("MultiSubOpenURL")
}

/// Entry point is `MultiSubApp`; this is installed via
/// `@NSApplicationDelegateAdaptor` for lifecycle hooks SwiftUI's `Scene`
/// doesn't cover (URL opens arriving before `AppRouter` can observe them).
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Holds a `multisub://` URL that arrived before `AppRouter`
    /// finished initializing and could start observing `.multiSubOpenURL` —
    /// macOS can call `application(_:open:)` either before or after
    /// `applicationDidFinishLaunching` depending on whether the app was just
    /// launched by the URL, so a notification alone could be missed.
    /// `AppRouter.init` drains and clears this.
    static var pendingOpenURL: URL?

    /// Set by `MultiSubApp.init`, so closing the window doesn't quit the
    /// app in the middle of 「整理本集單字」.
    static weak var vocabExtraction: VocabExtractionManager?

    /// Set by `MultiSubApp.init`, so closing the window doesn't quit the
    /// app in the middle of a model download.
    static weak var modelDownloads: ModelDownloadManager?

    /// Opens the main window again, or brings it back if it's already
    /// open. This delegate has no SwiftUI environment of its own, so
    /// `MultiSubApp` hands over the window's `openWindow` action once the
    /// window has appeared; nil until then (the launch window is on its way).
    static var openMainWindow: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startIdleUnloadTimer()
    }

    /// Cmd-Q (or logging out) in the middle of 「整理本集單字」. Without
    /// this, the episode's status keeps saying it's being organized until
    /// it goes stale, and the popup shows a spinner with the button locked
    /// for that long.
    func applicationWillTerminate(_ notification: Notification) {
        Self.vocabExtraction?.markInterrupted()
    }

    /// The App target also loads the shared `Translator` model
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

    /// Quits with the last window, except while vocabulary extraction is
    /// queued or running or a model is downloading: neither needs a window
    /// and both can take minutes, so the app stays up until they're done
    /// and then quits (each manager's `quitWhenIdle`, then `quitIfIdle`).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        var busy = false
        if let vocab = Self.vocabExtraction, vocab.hasActiveWork {
            vocab.quitWhenIdle = true
            busy = true
        }
        if let downloads = Self.modelDownloads, downloads.hasActiveDownloads {
            downloads.quitWhenIdle = true
            busy = true
        }
        return !busy
    }

    /// Called by a manager whose work kept the app up after its last window
    /// closed, once that work is over: quits unless the window is back or
    /// the other kind of work is still going (that one calls again when
    /// it's done).
    @MainActor
    static func quitIfIdle() {
        if NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) { return }
        if vocabExtraction?.hasActiveWork == true || modelDownloads?.hasActiveDownloads == true { return }
        NSApp.terminate(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // While an extraction runs, closing the window leaves the app
        // running with none (`applicationShouldTerminateAfterLastWindowClosed`).
        // A URL asks to show something, and neither the URL event nor
        // `activate()` creates a window, so open it again. On a cold launch
        // this is still nil and SwiftUI opens the window by itself.
        if !NSApp.windows.contains(where: { $0.isVisible }) {
            Self.openMainWindow?()
        }
        // The Safari extension opens these URLs from its own process, and
        // under cooperative activation macOS usually leaves us behind
        // Safari. Ask to come forward anyway; it's harmless when the system
        // declines, and nothing depends on the window being seen.
        NSApp.activate()
        Self.pendingOpenURL = url
        NotificationCenter.default.post(name: .multiSubOpenURL, object: nil, userInfo: ["url": url])
    }

}
