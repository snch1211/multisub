//
//  MultiSubApp.swift
//  MultiSub
//
//  SwiftUI lifecycle entry point (Phase G, replaces Main.storyboard).
//  AppDelegate is kept via NSApplicationDelegateAdaptor for the
//  application(_:open:) / pendingOpenURL handling (see AppDelegate.swift
//  and CLAUDE.md's D1 cold-start note) — deliberately not `.onOpenURL`.
//

import SwiftUI

@main
@MainActor
struct MultiSubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = AppRouter()
    @State private var configStore = ConfigStore()
    @State private var modelDownloadManager = ModelDownloadManager()
    @State private var vocabExtractionManager = VocabExtractionManager()
    @State private var updateChecker = UpdateChecker()
    @State private var updateDownloadManager = UpdateDownloadManager()

    var body: some Scene {
        Window("MultiSub", id: "main") {
            ContentView()
                .environment(router)
                .environment(configStore)
                .environment(modelDownloadManager)
                .environment(vocabExtractionManager)
                .environment(updateChecker)
                .environment(updateDownloadManager)
                // C4(a): 760 used to be narrower than the sidebar's own
                // reserved minimum (190, see SidebarView's
                // navigationSplitViewColumnWidth) plus the vocab tab's inner
                // HSplitView minimums (episode list 200 + word pane 400) —
                // at the window's smallest size, NavigationSplitView had
                // nowhere to take that missing width from but the sidebar,
                // squeezing it below its own declared minimum. 860 covers
                // sidebar + vocab tab's content minimums with headroom for
                // the outer padding and split-view dividers.
                .frame(minWidth: 860, minHeight: 520)
        }
        // Drops the titlebar's "MultiSub" text + the hairline separator
        // beneath it (the sidebar's own brand row already states the name),
        // so content — including the sidebar — runs up to the traffic
        // lights instead of sitting below a separate title strip.
        .windowStyle(.hiddenTitleBar)
    }
}
