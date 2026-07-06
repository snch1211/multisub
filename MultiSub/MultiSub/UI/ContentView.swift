//
//  ContentView.swift
//  MultiSub
//
//  Root NavigationSplitView (style guide v2 §5.0). G2–G5 replace each
//  PlaceholderView branch with the real detail view as they land.
//

import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        // Standard collapsible sidebar — kept collapsible rather than pinned
        // via `columnVisibility: .constant(.all)`, since hiding the resulting
        // dead toggle button (`.toolbar(.hidden, for: .windowToolbar)`) also
        // hides the window's traffic lights (same hiddenTitleBar toolbar strip).
        NavigationSplitView {
            SidebarView(router: router)
        } detail: {
            switch router.selection {
            case .general:
                GeneralSettingsView()
            case .styles:
                SubtitleStylesView()
            case .cache:
                CacheManagementView()
            case .vocab:
                VocabularyView()
            }
        }
        // C7: launch-time auto-check (at most once/day, throttled inside
        // `checkOnLaunchIfDue` itself) — lives here rather than inside
        // `GeneralSettingsView.task` so it fires regardless of which tab the
        // window happens to open on.
        .task { updateChecker.checkOnLaunchIfDue() }
    }
}
