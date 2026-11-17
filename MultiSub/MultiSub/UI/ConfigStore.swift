//
//  ConfigStore.swift
//  MultiSub
//
//  UI-side single source of truth for config.json. Views read `config` and
//  change it only through `update`, which goes through
//  `MultiSubConfig.update` (load fresh → mutate → coordinated write). The
//  Safari extension writes the same file (prefs from the popup's
//  `set-prefs`), so saving a whole copy held here since launch would
//  silently undo whatever it wrote in between.
//

import AppKit
import Foundation

@Observable
@MainActor
final class ConfigStore {
    private(set) var config: MultiSubConfig = MultiSubConfig.load()

    // Not removed in a `deinit`: like `AppRouter`, this store is a single
    // `@State` in `MultiSubApp` that lives as long as the app.
    init() {
        // Coming back to the app is the moment a change made in Safari (the
        // popup's mode / language / engine) should show up here.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (`queue: .main` above).
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Re-reads config.json. Only assigns when something changed, so views
    /// observing `config` don't re-render every time the window is focused.
    func reload() {
        let fresh = MultiSubConfig.load()
        if fresh != config { config = fresh }
    }

    /// Applies `mutate` to the on-disk config (not to the possibly stale copy
    /// held here) and adopts the result, which also picks up anything the
    /// extension wrote since the last reload.
    func update(_ mutate: (inout MultiSubConfig) -> Void) {
        config = MultiSubConfig.update(mutate)
    }
}
