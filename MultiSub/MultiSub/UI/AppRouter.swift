//
//  AppRouter.swift
//  MultiSub
//
//  @Observable sidebar navigation state + multisub:// URL routing.
//  Drains AppDelegate.pendingOpenURL and subscribes to .multiSubOpenURL —
//  see AppDelegate's doc comment for why a notification alone isn't enough.
//

import Foundation

@Observable
@MainActor
final class AppRouter {
    enum Tab: Hashable {
        case welcome, general, styles, cache, vocab
    }

    /// First launch (and every launch until the user finishes the last
    /// onboarding step) opens on 開始使用; after that, on 一般設定.
    var selection: Tab
    /// Set by `multisub://engine` (the popup's 「使用本機模型」): the engine
    /// settings open on this half. EngineSetupView reads and clears it.
    var requestedEngineTab: EngineSetupTab?
    /// `multisub://vocab?movieId=...` hands the episode straight to the
    /// extraction queue, whichever tab or window is showing (or none).
    private let vocab: VocabExtractionManager

    // Not removed in a `deinit` — this router lives for the app's entire
    // lifetime (single `@State` in `MultiSubApp`), so there's nothing to
    // tear down in practice, and a `deinit` can't touch a main-actor
    // property synchronously anyway.
    init(vocab: VocabExtractionManager) {
        self.vocab = vocab
        selection = MultiSubConfig.load().onboardingCompleted ? .general : .welcome
        NotificationCenter.default.addObserver(
            forName: .multiSubOpenURL, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            // Delivered on the main queue (`queue: .main` above).
            MainActor.assumeIsolated { self?.handle(url: url) }
        }
        if let pending = AppDelegate.pendingOpenURL {
            AppDelegate.pendingOpenURL = nil
            handle(url: pending)
        }
    }

    private func handle(url: URL) {
        switch url.host {
        case "welcome":
            selection = .welcome
        case "general":
            selection = .general
        case "engine":
            selection = .general
            requestedEngineTab = .local
        case "styles":
            selection = .styles
        case "vocab":
            selection = .vocab
            if let movieId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "movieId" })?.value {
                vocab.request(movieId: movieId)
            }
        default:
            break
        }
    }
}
