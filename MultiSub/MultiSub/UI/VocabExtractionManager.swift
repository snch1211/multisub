//
//  VocabExtractionManager.swift
//  MultiSub
//
//  C4(a) (2026-07-05): extraction progress used to live in VocabularyView's
//  own @State. SwiftUI tears a view's @State down once it leaves the
//  hierarchy (e.g. the user switches to another sidebar tab while "整理本集
//  單字" is still running), so the progress bar vanished from the user's
//  perspective even though the extraction Task kept running underneath.
//  Same root cause C3 hit with model downloads — see ModelDownloadManager.swift
//  for the fuller writeup. Fix follows the same shape: own the Task and its
//  progress at the App root, independent of which view is on screen.
//

import Foundation

@Observable
@MainActor
final class VocabExtractionManager {
    struct ExtractionState {
        var progress: Double = 0
        var statusText: String
        var failed = false
    }

    private(set) var extractions: [String: ExtractionState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isExtracting(_ movieId: String) -> Bool { tasks[movieId] != nil }

    /// No-op if `movieId` already has an extraction running.
    func start(_ pending: PendingTranscript, onFinished: @escaping (VocabFile) -> Void) {
        guard tasks[pending.movieId] == nil else { return }
        let movieId = pending.movieId
        extractions[movieId] = ExtractionState(statusText: "正在整理《\(pending.displayTitle)》的生詞本…")

        tasks[movieId] = Task { [weak self] in
            do {
                let words = try await Translator.shared.extractVocabulary(
                    lines: pending.lines, targetLang: pending.targetLang
                ) { fraction in
                    Task { @MainActor in self?.extractions[movieId]?.progress = fraction }
                }
                // Extraction is a one-shot task, unlike the extension's
                // continuous real-time translation — no reason for the App
                // to keep several GB of model resident afterward.
                await Translator.shared.unload()
                let file = VocabFile(
                    movieId: pending.movieId, seriesTitle: pending.seriesTitle,
                    episodeTitle: pending.episodeTitle, seasonNumber: pending.seasonNumber,
                    sourceLang: pending.sourceLang, targetLang: pending.targetLang,
                    createdAt: Date(), words: words
                )
                VocabStore.save(file)
                PendingTranscriptStore.delete(movieId: pending.movieId)
                self?.extractions[movieId] = nil
                self?.tasks[movieId] = nil
                onFinished(file)
            } catch {
                await Translator.shared.unload()
                self?.extractions[movieId]?.failed = true
                self?.extractions[movieId]?.statusText = "整理失敗：\(error.localizedDescription)"
                self?.tasks[movieId] = nil
            }
        }
    }

    /// Lets the UI drop a finished-with-error entry once the user has seen it.
    func dismissError(movieId: String) {
        extractions[movieId] = nil
    }
}
