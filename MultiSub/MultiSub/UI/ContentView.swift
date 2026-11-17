//
//  ContentView.swift
//  MultiSub
//
//  Root NavigationSplitView: sidebar + the selected tab's detail view.
//

import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(AppRouter.self) private var router
    #if !APP_STORE
    @Environment(UpdateChecker.self) private var updateChecker
    #endif

    var body: some View {
        // Standard collapsible sidebar — kept collapsible rather than pinned
        // via `columnVisibility: .constant(.all)`, since hiding the resulting
        // dead toggle button (`.toolbar(.hidden, for: .windowToolbar)`) also
        // hides the window's traffic lights (same hiddenTitleBar toolbar strip).
        NavigationSplitView {
            SidebarView(router: router)
        } detail: {
            switch router.selection {
            case .welcome:
                OnboardingView()
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
        #if !APP_STORE
        // Launch-time auto-check (at most once a day, throttled inside
        // `checkOnLaunchIfDue` itself). Lives here rather than inside
        // `GeneralSettingsView.task` so it fires regardless of which tab the
        // window happens to open on. The App Store build has no updater.
        .task { updateChecker.checkOnLaunchIfDue() }
        #endif
    }
}
