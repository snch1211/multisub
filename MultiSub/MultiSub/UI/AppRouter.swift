//
//  AppRouter.swift
//  MultiSub
//
//  @Observable sidebar navigation state + multisub:// URL routing (G1).
//  Drains AppDelegate.pendingOpenURL and subscribes to .multiSubOpenURL —
//  see AppDelegate's doc comment for why a notification alone isn't enough.
//

import Foundation

@Observable
@MainActor
final class AppRouter {
    enum Tab: Hashable {
        case general, styles, cache, vocab
    }

    var selection: Tab = .general
    /// Movie ID handed off by `multisub://vocab?movieId=...`; G5's vocab tab
    /// reads and clears this once it can act on it (prompt-to-organize flow).
    var pendingVocabMovieId: String?

    // Not removed in a `deinit` — this router lives for the app's entire
    // lifetime (single `@State` in `MultiSubApp`), so there's nothing to
    // tear down in practice, and a `deinit` can't touch a main-actor
    // property synchronously anyway.
    init() {
        NotificationCenter.default.addObserver(
            forName: .multiSubOpenURL, object: nil, queue: .main
        ) { note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor [weak self] in self?.handle(url: url) }
        }
        if let pending = AppDelegate.pendingOpenURL {
            AppDelegate.pendingOpenURL = nil
            handle(url: pending)
        }
    }

    private func handle(url: URL) {
        switch url.host {
        case "styles":
            selection = .styles
        case "vocab":
            selection = .vocab
            pendingVocabMovieId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "movieId" })?.value
        default:
            break
        }
    }
}
