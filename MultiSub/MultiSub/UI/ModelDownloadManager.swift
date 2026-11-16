//
//  ModelDownloadManager.swift
//  MultiSub
//
//  Downloads used to be started from a Task owned
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

    /// Hugging Face's answer to "how big is this model", for a model that
    /// isn't downloaded yet.
    enum SizeEstimate: Equatable {
        case loading
        case known(Int64)
        /// Offline, rate-limited, or a repo with no matching files. Stays
        /// failed until the user asks again (`retrySizeEstimate`), so an
        /// offline Mac doesn't keep calling Hugging Face in the background.
        case failed

        var bytes: Int64? {
            if case .known(let bytes) = self { return bytes }
            return nil
        }
    }

    private(set) var downloads: [String: DownloadState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Kept here rather than in a view's `@State` so it lives as long as the
    /// app: switching tabs, or the engine row and 一般設定's list both
    /// showing the same model, asks Hugging Face once instead of each time.
    private(set) var sizeEstimates: [String: SizeEstimate] = [:]

    func isDownloading(_ modelID: String) -> Bool { tasks[modelID] != nil }

    /// No-op if `modelID` already has a task running — selecting the same
    /// not-yet-downloaded model twice (e.g. re-opening the picker) shouldn't
    /// spawn a second concurrent download of the same files.
    ///
    /// `onFinished` runs after a successful download even if the view that
    /// started it is gone by then (the user switched tabs or scrolled the
    /// row away), which is why follow-up work like "use this model now"
    /// belongs here rather than in a view's `onChange`.
    func start(modelID: String, onFinished: (@MainActor () -> Void)? = nil) {
        guard tasks[modelID] == nil else { return }
        downloads[modelID] = DownloadState()

        tasks[modelID] = Task { [weak self] in
            do {
                // Pre-populate the HF cache ourselves with a resumable
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
                onFinished?()
            } catch is CancellationError where Translator.isModelDownloaded(modelID) {
                // The files are all on disk; only the warm-up load was cut
                // short (an unload, e.g. by the vocab extractor, or a load
                // of another model superseded it). The model will load on
                // first use, so this download did its job.
                self?.downloads[modelID] = nil
                self?.tasks[modelID] = nil
                onFinished?()
            } catch {
                self?.downloads[modelID]?.failed = true
                self?.downloads[modelID]?.errorDescription = error.localizedDescription
                self?.tasks[modelID] = nil
            }
        }
    }

    /// Looks the size up once per model per app run; a row calls this when
    /// it appears. Only rows the user is looking at ask, so Hugging Face
    /// isn't contacted just because the app launched.
    func requestSizeEstimate(modelID: String) {
        guard sizeEstimates[modelID] == nil else { return }
        lookUpSize(modelID: modelID)
    }

    /// The user asked again after a failed lookup.
    func retrySizeEstimate(modelID: String) {
        if sizeEstimates[modelID] == .loading { return }
        lookUpSize(modelID: modelID)
    }

    /// Shown in a row's label in place of a size it doesn't have yet.
    func sizePlaceholder(for modelID: String) -> String {
        sizeEstimates[modelID] == .failed ? "查不到大小" : "查詢大小中…"
    }

    private func lookUpSize(modelID: String) {
        sizeEstimates[modelID] = .loading
        Task { [weak self] in
            do {
                let bytes = try await ModelDownloader.estimatedSize(modelID: modelID)
                // Zero means no weight files matched: the download would
                // fail too, so there is no size worth showing.
                self?.sizeEstimates[modelID] = bytes > 0 ? .known(bytes) : .failed
            } catch {
                self?.sizeEstimates[modelID] = .failed
            }
        }
    }

    /// Lets a row's UI drop a finished-with-error entry once the user has
    /// seen it (e.g. before retrying), without needing a whole-manager reset.
    func dismissError(modelID: String) {
        downloads[modelID] = nil
    }
}
