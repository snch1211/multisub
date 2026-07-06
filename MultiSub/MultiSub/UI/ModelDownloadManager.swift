//
//  ModelDownloadManager.swift
//  MultiSub
//
//  C3 (2026-07-05 follow-up): downloads used to be started from a Task owned
//  by GeneralSettingsView's own button-tap closure, with progress tracked in
//  that view's @State. Since SwiftUI tears down a view's @State once it's no
//  longer part of the hierarchy (e.g. the user switches to "快取管理"), and
//  the Picker's selection used to double as "which model the one shared
//  progress bar points at", both switching tabs and switching the picker
//  interrupted an in-flight download from the user's perspective — restarting
//  it (resumably, thanks to ModelDownloader's own Range-based resume) was the
//  only way forward. Owning downloads here instead — injected at the App
//  root, alive for the process's lifetime, independent of which view is
//  currently on screen — means a download's `Task` just keeps running
//  regardless of navigation, and multiple models can download concurrently
//  without stepping on each other's progress state.
//

import Foundation

@Observable
@MainActor
final class ModelDownloadManager {
    struct DownloadState {
        var progress: Double = 0
        var failed = false
        var errorDescription: String?
    }

    private(set) var downloads: [String: DownloadState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isDownloading(_ modelID: String) -> Bool { tasks[modelID] != nil }

    /// No-op if `modelID` already has a task running — selecting the same
    /// not-yet-downloaded model twice (e.g. re-opening the picker) shouldn't
    /// spawn a second concurrent download of the same files.
    func start(modelID: String) {
        guard tasks[modelID] == nil else { return }
        downloads[modelID] = DownloadState()

        tasks[modelID] = Task { [weak self] in
            do {
                // S1: pre-populate the HF cache ourselves with a resumable
                // downloader (see ModelDownloader.swift) instead of letting
                // swift-huggingface's own download path handle the big
                // weight files — that path gets stuck around 1% on flaky
                // connections. loadModel below then finds everything already
                // cached and does no network I/O for the weights.
                try await ModelDownloader.download(modelID: modelID) { fraction in
                    Task { @MainActor in self?.downloads[modelID]?.progress = fraction }
                }
                try await Translator.shared.loadModel(modelID: modelID, allowDownload: true) { fraction in
                    Task { @MainActor in self?.downloads[modelID]?.progress = fraction }
                }
                self?.downloads[modelID] = nil
                self?.tasks[modelID] = nil
            } catch {
                self?.downloads[modelID]?.failed = true
                self?.downloads[modelID]?.errorDescription = error.localizedDescription
                self?.tasks[modelID] = nil
            }
        }
    }

    /// Lets a row's UI drop a finished-with-error entry once the user has
    /// seen it (e.g. before retrying), without needing a whole-manager reset.
    func dismissError(modelID: String) {
        downloads[modelID] = nil
    }
}
