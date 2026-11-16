//
//  VocabExtractionManager.swift
//  MultiSub
//
//  Owns 「整理本集單字」 from the Safari hand-off to the saved word list, at
//  the App root for the process's lifetime. Extraction progress used to live
//  in VocabularyView's own @State, and the hand-off itself was handled in
//  VocabularyView.onAppear behind a confirmation alert. Both broke in the
//  field: SwiftUI tears a view's @State down once it leaves the hierarchy,
//  so the list never refreshed when an extraction finished on another tab;
//  and a `multisub://` URL opened from the Safari extension's process does
//  not bring the app forward (cooperative activation), so the alert sat
//  behind Safari and nothing ran. Same root cause model downloads hit (see
//  ModelDownloadManager.swift); same fix: own the work here, independent of
//  which view is on screen, and let views observe it.
//
//  The click on 「整理本集單字」 is the consent: `request(movieId:)` checks
//  the gates (English source, a usable engine) and starts right away. Jobs
//  run one at a time in arrival order. Every state change is mirrored into
//  `VocabStatusStore` (shared container) so the popup can show it; nothing
//  here depends on a window being open or the user seeing an alert.
//
//  Runs on whichever engine `Translator` resolves (local model or the user's
//  API key); nothing here is specific to the local model.
//

import AppKit
import Foundation
import os

@Observable
@MainActor
final class VocabExtractionManager {
    struct Job: Identifiable, Equatable {
        enum Phase: Equatable {
            case queued
            case running
            case failed(code: String, message: String)
        }

        let movieId: String
        var seriesTitle: String
        var episodeTitle: String?
        var seasonNumber: Int?
        var phase: Phase = .queued
        /// Segments finished / total, the units `Translator.extractVocabulary`
        /// reports (`Translator.vocabSegmentCount`).
        var done = 0
        var total = 0
        /// e.g. "本機模型（Gemma 4 E4B）"; empty when no engine resolved.
        var engineName = ""

        var id: String { movieId }

        var displayTitle: String {
            guard let episodeTitle, !episodeTitle.isEmpty else { return seriesTitle }
            return "\(seriesTitle) - \(episodeTitle)"
        }

        var isActive: Bool { phase == .queued || phase == .running }

        var failureCode: String? {
            if case .failed(let code, _) = phase { return code }
            return nil
        }

        /// Running it again can't fix a non-English transcript.
        var canRetry: Bool {
            guard let code = failureCode else { return false }
            return code != VocabExtractionManager.nonEnglishCode
        }

        /// The fix is in 一般設定 (engine or model setup).
        var needsEngineSetup: Bool {
            failureCode == TranslatorError.engineNotReady.code
                || failureCode == TranslatorError.modelNotDownloaded.code
        }

        /// One line for the episode list.
        var statusLine: String {
            switch phase {
            case .queued: return "排隊中"
            // done stays 0 while the engine starts (a local model can take
            // a while to load); 「整理中（0/N）」 would look stuck.
            case .running: return done > 0 && total > 0 ? "整理中（\(done)/\(total)）" : "準備中…"
            case .failed(_, let message): return message
            }
        }
    }

    /// Which row the 生詞本 tab should select next. `seq` makes a repeat of
    /// the same request a change `onChange` can see.
    struct Focus: Equatable {
        enum Target: Equatable {
            case job(String)
            case episode(String)
        }

        let target: Target
        let seq: Int
    }

    nonisolated static let nonEnglishCode = "non-english"
    nonisolated static let emptyCode = "vocab-empty"
    nonisolated static let failedCode = "vocab-failed"

    /// Queued, running and failed jobs in arrival order, which is also the
    /// order they run in. A job leaves the list once its words are saved.
    private(set) var jobs: [Job] = []
    /// Set when a hand-off arrives (select its row) and when an extraction
    /// saves its words (select the new episode). The 生詞本 tab applies it
    /// and calls `clearFocus()`, on appear or right away if it's on screen.
    private(set) var focus: Focus?

    /// For the sidebar's activity indicator.
    var isBusy: Bool { jobs.contains { $0.isActive } }

    /// Also counts the moments between jobs when the worker is unloading
    /// the model, so the app doesn't quit in the middle of that.
    var hasActiveWork: Bool { isBusy || worker != nil }

    /// Set by `AppDelegate` when it kept the app running after the last
    /// window closed because work was still going; the app quits once the
    /// queue is empty (unless a window has been opened again by then).
    @ObservationIgnored var quitWhenIdle = false

    /// Transcripts of queued and running jobs. A failed job's transcript
    /// stays staged in `PendingTranscriptStore` for 「重試」.
    @ObservationIgnored private var transcripts: [String: PendingTranscript] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var focusSeq = 0

    private static let log = Logger(subsystem: AppIdentity.appBundleID, category: "vocab")

    init() {
        recoverFromLastRun()
    }

    // MARK: - Requests

    /// `multisub://vocab?movieId=…`: the user pressed 「整理本集單字」 in
    /// Safari, which is the consent to run it. A job already queued or
    /// running for this movie just keeps going; a failed one runs again.
    func request(movieId: String) {
        guard VocabStatusStore.isValidMovieId(movieId) else { return }
        if let job = job(movieId), job.isActive {
            requestFocus(.job(movieId))
            return
        }
        guard let pending = PendingTranscriptStore.load(movieId: movieId) else {
            // Nothing staged: a repeat of a URL whose run already finished.
            Self.log.info("vocab request for \(movieId, privacy: .public) has no staged transcript")
            requestFocus(.episode(movieId))
            return
        }
        enqueue(pending)
        requestFocus(.job(movieId))
    }

    /// 「重試」 on a failed job: runs again from the staged transcript.
    func retry(movieId: String) {
        guard let job = job(movieId), !job.isActive else { return }
        guard let pending = PendingTranscriptStore.load(movieId: movieId) else {
            fail(movieId, code: Self.failedCode,
                 message: "找不到這集的字幕了，請回到 Netflix 播放頁再按一次「整理本集單字」。")
            return
        }
        enqueue(pending)
    }

    /// 「移除」 on a failed job: forgets it, its status and its transcript.
    func dismiss(movieId: String) {
        guard let job = job(movieId), !job.isActive else { return }
        jobs.removeAll { $0.movieId == movieId }
        VocabStatusStore.delete(movieId: movieId)
        PendingTranscriptStore.delete(movieId: movieId)
    }

    func clearFocus() {
        focus = nil
    }

    // MARK: - Queue

    private func enqueue(_ pending: PendingTranscript) {
        let movieId = pending.movieId
        upsert(Job(movieId: movieId, seriesTitle: pending.seriesTitle,
                   episodeTitle: pending.episodeTitle, seasonNumber: pending.seasonNumber,
                   total: Translator.vocabSegmentCount(lineCount: pending.lines.count)))

        // content.js and the popup check the track language before the
        // button can be pressed; this is the line of defense for a stale
        // popup or any other caller that gets past them.
        guard LanguageNames.isEnglish(pending.sourceLang) else {
            fail(movieId, code: Self.nonEnglishCode,
                 message: "這集的原文字幕語言是「\(pending.sourceLang)」，生詞本只支援英文字幕。")
            return
        }
        // Checked up front so a run that would fail on its first request
        // says why right away instead of after loading a model.
        do {
            let engineName = try Self.engineDescription()
            if let i = index(movieId) { jobs[i].engineName = engineName }
        } catch {
            fail(movieId, code: Self.code(for: error), message: Self.message(for: error) + "設定好後按「重試」。")
            return
        }
        transcripts[movieId] = pending
        if let job = job(movieId) { writeStatus(job) }
        pump()
    }

    /// Starts the next queued job when nothing is running.
    private func pump() {
        defer { updateKeepAlive() }
        guard worker == nil, let i = jobs.firstIndex(where: { $0.phase == .queued }) else { return }
        let movieId = jobs[i].movieId
        guard let pending = transcripts[movieId] else {
            fail(movieId, code: Self.failedCode, message: "找不到這集的字幕了，請回到 Netflix 播放頁再按一次「整理本集單字」。")
            pump()
            return
        }
        jobs[i].phase = .running
        writeStatus(jobs[i])
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(pending)
            // Extraction is a one-shot task, unlike the extension's
            // continuous real-time translation: no reason for the app to
            // keep several GB of model resident once the queue is empty.
            // (A no-op when the cloud engine ran it.) `worker` stays set
            // until this returns, so a job queued meanwhile can't start
            // loading the model while it's being unloaded.
            if !self.jobs.contains(where: { $0.phase == .queued }) {
                await Translator.shared.unload()
            }
            self.worker = nil
            self.pump()
        }
    }

    private func run(_ pending: PendingTranscript) async {
        let movieId = pending.movieId
        defer { transcripts[movieId] = nil }
        do {
            let words = try await Translator.shared.extractVocabulary(
                lines: pending.lines, targetLang: pending.targetLang
            ) { [self] done, total in
                // Held only while the extraction runs; the manager lives
                // for the whole app anyway.
                Task { @MainActor in self.progress(movieId, done: done, total: total) }
            }
            // `Translator` treats a failed segment as "no words" so one bad
            // segment can't sink the episode. Nothing at all for a whole
            // episode almost always means every request failed (e.g. a
            // revoked key or no network), so keep the transcript for a
            // retry instead of saving an empty list over it.
            guard !words.isEmpty else {
                fail(movieId, code: Self.emptyCode,
                     message: "沒有整理出任何單字，可能是 AI 引擎連線失敗。請到「一般設定」測試翻譯，再按「重試」。")
                return
            }
            let file = VocabFile(
                movieId: movieId, seriesTitle: pending.seriesTitle,
                episodeTitle: pending.episodeTitle, seasonNumber: pending.seasonNumber,
                sourceLang: pending.sourceLang, targetLang: pending.targetLang,
                createdAt: Date(), words: words
            )
            VocabStore.save(file)
            PendingTranscriptStore.delete(movieId: movieId)
            let total = job(movieId)?.total ?? 0
            jobs.removeAll { $0.movieId == movieId }
            VocabStatusStore.write(VocabOrganizeStatus(
                movieId: movieId, state: .done, accepted: true, done: total, total: total,
                wordCount: words.count, title: pending.displayTitle, updatedAt: Date()))
            requestFocus(.episode(movieId))
        } catch {
            fail(movieId, code: Self.code(for: error), message: "整理失敗：" + Self.message(for: error))
        }
    }

    private func progress(_ movieId: String, done: Int, total: Int) {
        // A late update can land after the job finished or failed.
        guard let i = index(movieId), jobs[i].phase == .running else { return }
        jobs[i].done = done
        jobs[i].total = total
        writeStatus(jobs[i])
    }

    private func fail(_ movieId: String, code: String, message: String) {
        guard let i = index(movieId) else { return }
        jobs[i].phase = .failed(code: code, message: message)
        transcripts[movieId] = nil
        writeStatus(jobs[i])
        Self.log.info("vocab \(movieId, privacy: .public) failed: \(code, privacy: .public)")
    }

    // MARK: - Keeping the work alive

    /// While anything is queued or running: refresh the status entries so
    /// the popup can tell this run from one that stopped, and keep App Nap
    /// from throttling the app (its window is usually behind Safari). Once
    /// the queue is empty: stop both, and quit if the last window was
    /// closed while the work was going.
    private func updateKeepAlive() {
        if hasActiveWork {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiated, reason: "Organizing episode vocabulary")
            }
            if heartbeatTask == nil {
                heartbeatTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(VocabStatusStore.heartbeat))
                        guard let self, !Task.isCancelled else { return }
                        for job in self.jobs where job.isActive { self.writeStatus(job) }
                    }
                }
            }
            return
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if quitWhenIdle {
            quitWhenIdle = false
            if !NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Quit

    /// The app is quitting with work still queued or running
    /// (`AppDelegate.applicationWillTerminate`). Each such job is marked
    /// failed right away, so the popup stops showing a spinner and frees
    /// 「整理本集單字」 on its next poll, not after `VocabStatusStore.staleAfter`.
    /// The staged transcripts stay, and the next launch brings these back
    /// as failed rows with 「重試」 (`recoverFromLastRun`).
    func markInterrupted() {
        for job in jobs where job.isActive {
            fail(job.movieId, code: VocabStatusStore.interruptedCode,
                 message: "整理到一半 MultiSub App 就關掉了。按「重試」重新整理。")
        }
    }

    // MARK: - Launch

    /// Picks up where the last app process left off: a hand-off that
    /// arrived just before launch runs (its URL is on the way too and is
    /// then a no-op), work cut off by a quit becomes a failed job that can
    /// be retried, and expired entries are cleaned up.
    private func recoverFromLastRun() {
        let now = Date()
        var handedOff: [String] = []
        for status in VocabStatusStore.loadAll() {
            let age = now.timeIntervalSince(status.updatedAt)
            if status.isActive {
                if !status.accepted, age <= VocabStatusStore.staleAfter {
                    handedOff.append(status.movieId)
                    continue
                }
                var failed = status
                failed.state = .failed
                failed.code = status.accepted ? VocabStatusStore.interruptedCode : VocabStatusStore.notStartedCode
                failed.message = status.accepted
                    ? "整理到一半 MultiSub App 就關掉了。按「重試」重新整理。"
                    : "MultiSub App 沒有開始整理這集。按「重試」開始整理。"
                failed.updatedAt = now
                VocabStatusStore.write(failed)
                restoreFailed(failed)
            } else if age > VocabStatusStore.keepFinishedFor {
                VocabStatusStore.delete(movieId: status.movieId)
                if status.state == .failed { PendingTranscriptStore.delete(movieId: status.movieId) }
            } else if status.state == .failed {
                restoreFailed(status)
            }
        }
        // Transcripts nothing points at any more, e.g. left by the earlier
        // confirm-first flow when the user pressed 取消.
        for staged in PendingTranscriptStore.stagedFiles()
        where VocabStatusStore.load(movieId: staged.movieId) == nil
            && now.timeIntervalSince(staged.stagedAt) > VocabStatusStore.keepFinishedFor {
            PendingTranscriptStore.delete(movieId: staged.movieId)
        }
        for movieId in handedOff { request(movieId: movieId) }
    }

    /// A failed entry with its transcript still staged comes back as a row
    /// with 「重試」; without one there is nothing to retry from.
    private func restoreFailed(_ status: VocabOrganizeStatus) {
        guard let pending = PendingTranscriptStore.load(movieId: status.movieId) else { return }
        upsert(Job(movieId: status.movieId, seriesTitle: pending.seriesTitle,
                   episodeTitle: pending.episodeTitle, seasonNumber: pending.seasonNumber,
                   phase: .failed(code: status.code ?? Self.failedCode,
                                  message: status.message ?? "整理失敗，請按「重試」。"),
                   done: status.done, total: status.total))
    }

    // MARK: - Helpers

    private func index(_ movieId: String) -> Int? { jobs.firstIndex { $0.movieId == movieId } }

    private func job(_ movieId: String) -> Job? { index(movieId).map { jobs[$0] } }

    /// Replaces the job in place (keeping its spot in the list) or appends it.
    private func upsert(_ job: Job) {
        if let i = index(job.movieId) { jobs[i] = job } else { jobs.append(job) }
    }

    private func requestFocus(_ target: Focus.Target) {
        focusSeq += 1
        focus = Focus(target: target, seq: focusSeq)
    }

    private func writeStatus(_ job: Job) {
        var status = VocabOrganizeStatus(
            movieId: job.movieId, state: .queued, accepted: true, done: job.done, total: job.total,
            title: job.displayTitle, updatedAt: Date())
        switch job.phase {
        case .queued:
            status.state = .queued
        case .running:
            status.state = .running
        case .failed(let code, let message):
            status.state = .failed
            status.code = code
            status.message = message
        }
        VocabStatusStore.write(status)
    }

    /// The engine `Translator` would use right now, e.g. for the progress
    /// view. Throws `TranslatorError` when none can run.
    static func engineDescription() throws -> String {
        switch try Translator.resolveEngine(config: MultiSubConfig.load()) {
        case .local(let modelID):
            return "本機模型（\(ModelCatalog.displayName(for: modelID))）"
        case .cloud(let client):
            return "\(client.provider.displayName)（\(client.model)）"
        }
    }

    /// The stable code the popup maps to its own wording.
    static func code(for error: Error) -> String {
        if let error = error as? TranslatorError { return error.code }
        if let error = error as? CloudLLMError { return error.code }
        return failedCode
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
        if error is CancellationError {
            return "整理中斷了。"
        }
        return error.localizedDescription
    }
}
