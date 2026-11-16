//
//  VocabExtractionManager.swift
//  MultiSub
//
//  Extraction progress used to live in VocabularyView's own @State. SwiftUI
//  tears a view's @State down once it leaves the hierarchy (e.g. the user
//  switches to another sidebar tab while "整理本集單字" is still running), so
//  the progress bar vanished from the user's perspective even though the
//  extraction Task kept running underneath. Same root cause model downloads
//  hit — see ModelDownloadManager.swift for the fuller writeup. Fix follows
//  the same shape: own the Task and its progress at the App root,
//  independent of which view is on screen.
//
//  Runs on whichever engine `Translator` resolves (local model or the user's
//  API key); nothing here is specific to the local model.
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
                // to keep several GB of model resident afterward. (A no-op
                // when the cloud engine ran it.)
                await Translator.shared.unload()
                // `Translator` treats a failed segment as "no words" so one
                // bad segment can't sink the episode. Nothing at all for a
                // whole episode almost always means every request failed
                // (e.g. a revoked key or no network), so keep the transcript
                // for a retry instead of saving an empty list over it.
                if words.isEmpty {
                    self?.fail(movieId, message: "沒有整理出任何單字，可能是 AI 引擎連線失敗。請到「一般設定」測試翻譯後再試一次。")
                    return
                }
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
                self?.fail(movieId, message: "整理失敗：" + Self.message(for: error))
            }
        }
    }

    private func fail(_ movieId: String, message: String) {
        extractions[movieId]?.failed = true
        extractions[movieId]?.statusText = message
        tasks[movieId] = nil
    }

    /// User-facing text for an extraction error. Engine errors point at the
    /// place to fix them; provider errors (`CloudLLMError`) already carry a
    /// short Chinese message.
    static func message(for error: Error) -> String {
        if case .engineNotReady? = error as? TranslatorError {
            return "尚未設定 AI 引擎，請到「一般設定」設定 API Key 或下載本機模型。"
        }
        if case .modelNotDownloaded? = error as? TranslatorError {
            return "目前設定用本機模型，但模型還沒下載。請到「一般設定」下載模型，或改用 API Key。"
        }
        return error.localizedDescription
    }

    /// Lets the UI drop a finished-with-error entry once the user has seen it.
    func dismissError(movieId: String) {
        extractions[movieId] = nil
    }
}
