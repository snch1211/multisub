//
//  Translator.swift
//  MultiSub
//
//  Shared between the host app and the Safari extension. Runs every AI task
//  (translation, glossary, annotation, vocabulary) on whichever engine the
//  config selects: the local Gemma model via MLX, or the user's own cloud
//  API key. Both engines get the same prompts (`Prompts`); this file only
//  decides where the text goes and keeps the local model's lifecycle.
//

import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

enum TranslatorError: LocalizedError, Equatable {
    /// The local engine was selected (or is the only option) but its model
    /// isn't on disk.
    case modelNotDownloaded
    /// No engine can run: no saved key for the selected provider and no
    /// downloaded model.
    case engineNotReady

    /// Stable code shared with the extension (`error` in native replies).
    var code: String {
        switch self {
        case .modelNotDownloaded: return "model-not-ready"
        case .engineNotReady: return "engine-not-ready"
        }
    }

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: return "本機模型尚未下載。"
        case .engineNotReady: return "還沒設定 AI 引擎：請貼上 API Key，或下載本機模型。"
        }
    }
}

/// Where a request will run, decided fresh from config.json each time.
enum ResolvedEngine: Sendable {
    case local(modelID: String)
    case cloud(CloudLLMClient)

    var kind: String {
        switch self {
        case .local: return "local"
        case .cloud: return "cloud"
        }
    }
}

/// Snapshot of the engine settings for `ping` / the popup / the app.
struct EngineStatus: Sendable, Equatable {
    var configured: EngineKind
    /// "local" | "cloud", or nil when nothing can run.
    var active: String?
    var provider: CloudProvider
    var providerName: String
    /// Cloud model that would be requested (provider default when unset).
    var model: String
    /// A key is saved for `provider`.
    var hasKey: Bool
    var localModelId: String
    var localModelDownloaded: Bool
    var localModelLoaded: Bool
    /// Saved server address; only meaningful (and only sent) for `.custom`,
    /// so the popup can prefill its form.
    var baseURL: String = ""

    /// Plist-compatible shape for native replies. `active` is left out when
    /// nil (JS reads it as undefined) because NSNull isn't guaranteed to
    /// survive the extension reply bridge.
    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "configured": configured.rawValue,
            "provider": provider.rawValue,
            "providerName": providerName,
            "model": model,
            "hasKey": hasKey,
            "localModelId": localModelId,
            "localModelDownloaded": localModelDownloaded,
            "localModelLoaded": localModelLoaded,
        ]
        if let active { d["active"] = active }
        if provider == .custom, !baseURL.isEmpty { d["baseURL"] = baseURL }
        return d
    }
}

actor Translator {
    static let shared = Translator()

    private var container: ModelContainer?
    private var loadedModelID: String?
    /// The load in flight and the model it's loading. The actor is free to
    /// take other calls while a load is suspended, and a cold start sends
    /// several requests at once (the first translate batch and the glossary,
    /// a second tab, the popup's test); they all await this one task
    /// instead of each loading another multi-GB copy of the weights.
    private var loadTask: Task<ModelContainer, Error>?
    private var loadingModelID: String?
    /// Bumped by every new load and by `unload()`. A load that finishes
    /// under an older generation was superseded, so its result is dropped
    /// rather than stored; otherwise an unload that arrives during a cold
    /// load would be undone the moment the load finished.
    private var loadGeneration = 0
    private var lastUsedAt: Date?
    // Counts in-flight requests (see the `defer` blocks). Lets `unload()`
    // callers other than the extension's toggle-off path (which is safe by
    // design — background.js stops issuing further batches once it flips
    // settings.enabled off) check whether unloading right now would pull the
    // container out from under an active episode translation.
    private var activeRequests = 0

    var isLoaded: Bool { container != nil }
    /// Read-only app-side accessor so the settings view can tell which
    /// specific model a deletion candidate would be pulling out from under,
    /// instead of only knowing *that* something is loaded.
    var currentlyLoadedModelID: String? { loadedModelID }
    var isBusy: Bool { activeRequests > 0 }

    // MARK: - Engine selection

    /// auto: cloud if a key is saved for the selected provider (a custom
    /// server needs a base URL and a model instead; its key is optional),
    /// else the local model if it's downloaded, else not ready.
    /// local / cloud: that engine or an error saying what's missing.
    ///
    /// Cloud also needs the user's recorded consent for that provider
    /// (`MultiSubConfig.cloudConsent`): without it no subtitle text may
    /// leave the Mac, so the provider counts as not ready, and auto falls
    /// through to the local model.
    static func resolveEngine(config: MultiSubConfig) throws -> ResolvedEngine {
        switch config.engine {
        case .local:
            guard isModelDownloaded(config.modelID) else { throw TranslatorError.modelNotDownloaded }
            return .local(modelID: config.modelID)
        case .cloud:
            guard let client = consentedCloudClient(config: config) else { throw TranslatorError.engineNotReady }
            return .cloud(client)
        case .auto:
            if let client = consentedCloudClient(config: config) { return .cloud(client) }
            if isModelDownloaded(config.modelID) { return .local(modelID: config.modelID) }
            throw TranslatorError.engineNotReady
        }
    }

    private static func consentedCloudClient(config: MultiSubConfig) -> CloudLLMClient? {
        guard config.hasCloudConsent(for: config.cloud.provider) else { return nil }
        return cloudClient(for: config.cloud)
    }

    /// A client for the saved cloud settings, or nil when they can't run yet.
    static func cloudClient(for settings: CloudSettings) -> CloudLLMClient? {
        let provider = settings.provider
        let key = SecretStore.apiKey(for: provider)
        if provider == .custom {
            guard !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
        } else {
            guard let key, !key.isEmpty else { return nil }
        }
        return CloudLLMClient(provider: provider, model: settings.model, baseURL: settings.baseURL, apiKey: key)
    }

    static func engineStatus() async -> EngineStatus {
        await engineStatus(config: MultiSubConfig.load())
    }

    static func engineStatus(config: MultiSubConfig) async -> EngineStatus {
        let provider = config.cloud.provider
        let active = (try? resolveEngine(config: config))?.kind
        return EngineStatus(
            configured: config.engine,
            active: active,
            provider: provider,
            providerName: provider.displayName,
            model: config.cloud.resolvedModel,
            hasKey: SecretStore.hasAPIKey(for: provider),
            localModelId: config.modelID,
            localModelDownloaded: isModelDownloaded(config.modelID),
            localModelLoaded: await shared.isLoaded,
            baseURL: config.cloud.baseURL)
    }

    // MARK: - Model presence / download

    /// A complete copy is on this Mac (`MultiSubPaths.modelSnapshotDirectory`),
    /// so `loadModel` can load it without the network.
    nonisolated static func isModelDownloaded(_ modelID: String) -> Bool {
        MultiSubPaths.modelSnapshotDirectory(for: modelID) != nil
    }

    private nonisolated func hubClient() -> HubClient {
        HubClient(cache: HubCache(cacheDirectory: MultiSubPaths.modelsRoot))
    }

    /// Loads the local model from the files on this Mac. Progress is reported in [0, 1].
    ///
    /// A model that's complete on disk loads from its snapshot folder and
    /// nothing contacts Hugging Face. Otherwise a call with
    /// `allowDownload: false` (every translation, test and vocabulary
    /// request) fails with `modelNotDownloaded`; only the app's own download
    /// (`ModelDownloadManager`, `allowDownload: true`) may fetch what's
    /// missing.
    ///
    /// A call for the model that's already loading joins that load (its
    /// `progress` isn't reported; only the caller that started the load
    /// gets progress). A call for another model, or `unload()`, supersedes
    /// the load in flight: it's cancelled, and everyone waiting on it gets
    /// `CancellationError` instead of a model that would stay resident.
    func loadModel(modelID: String, allowDownload: Bool,
                   progress: (@Sendable (Double) -> Void)? = nil) async throws {
        markUsed()
        if loadedModelID == modelID, container != nil { return }
        // Checked before joining, so a translation request during the app's
        // download fails fast with model-not-ready instead of waiting out a
        // multi-GB download.
        if !allowDownload && !Self.isModelDownloaded(modelID) {
            throw TranslatorError.modelNotDownloaded
        }

        let task: Task<ModelContainer, Error>
        if let inFlight = loadTask, loadingModelID == modelID {
            task = inFlight
        } else {
            loadTask?.cancel()
            loadGeneration += 1
            // Release the previous model before loading a new one.
            container = nil
            loadedModelID = nil
            Memory.cacheLimit = 512 * 1024 * 1024
            task = Task {
                let source: any MLXLMCommon.Downloader
                if let directory = MultiSubPaths.modelSnapshotDirectory(for: modelID) {
                    source = LocalModelFolder(directory: directory)
                } else if allowDownload {
                    source = HubDownloader(self.hubClient())
                } else {
                    // Removed or left incomplete since the check above.
                    throw TranslatorError.modelNotDownloaded
                }
                // The configuration keeps the repo id (not a directory) so
                // the model is still named by it, e.g. for mlx-swift-lm's
                // per-model conventions.
                return try await LLMModelFactory.shared.loadContainer(
                    from: source,
                    using: TransformersTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelID)
                ) { prog in
                    progress?(prog.fractionCompleted)
                }
            }
            loadTask = task
            loadingModelID = modelID
        }
        let generation = loadGeneration

        let loaded: ModelContainer
        do {
            loaded = try await task.value
        } catch {
            if generation == loadGeneration {
                loadTask = nil
                loadingModelID = nil
            }
            throw error
        }
        // Superseded while suspended: drop the result so ARC frees it once
        // nothing holds it, and leave whatever replaced it alone.
        guard generation == loadGeneration else { throw CancellationError() }
        // Every waiter resumes here in some order; the assignment is the
        // same for all of them.
        container = loaded
        loadedModelID = modelID
        loadTask = nil
        loadingModelID = nil
    }

    // MARK: - Memory management

    /// Releases the loaded model container and clears MLX's cached buffers,
    /// freeing the multi-GB footprint. The `ChatSession` used per request
    /// (see `generate`) holds no persistent reference, so dropping
    /// `container` is enough to let ARC deallocate the weights; `clearCache`
    /// additionally returns MLX's recycled buffer pool to the system rather
    /// than leaving it around for reuse. Safe to call when nothing is loaded
    /// — the next local request reloads lazily.
    ///
    /// A load still in flight is cancelled and its result dropped (see
    /// `loadGeneration`), so unloading during a cold start sticks.
    func unload() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
        container = nil
        loadedModelID = nil
        Memory.clearCache()
    }

    /// Records model activity. Called from `loadModel` and again when each
    /// local generation finishes, so the idle clock counts from the end of
    /// the last use: a ping in the gap between two long batches must not
    /// see the model as idle since the first batch started.
    private func markUsed() {
        lastUsedAt = Date()
    }

    /// Unloads the model if it's been idle past the configured threshold.
    /// `idleUnloadMinutes` is a global policy — both the appex and the host
    /// app load this same model singleton, and both are expected to call this.
    ///
    /// The two callers drive it very differently, though. The appex is an
    /// `NSExtensionRequestHandling` host, and empirically the OS suspends
    /// the whole process between native-message requests (confirmed via
    /// `sample`: every thread parked, RSS never dropped after 10+ idle
    /// minutes with a 1-minute threshold) — an internal `Task.sleep`-based
    /// timer was tried there and doesn't work. So the appex only runs this
    /// opportunistically whenever *something* wakes the process:
    /// `handlePing` calls it on every `ping`, and content.js pings
    /// periodically (independent of the popup) specifically to drive this.
    /// This constraint is specific to the appex host — it does NOT apply to
    /// the app target, which is a normal GUI process the OS doesn't suspend
    /// between requests, so the app drives this with a real 60s timer
    /// (`AppDelegate`).
    ///
    /// Never unloads while a request is running (`activeRequests`) or a load
    /// is in flight: one long generation (a 2048-token vocabulary segment on
    /// a base M1, or a big model) can outlast a 1-minute threshold, and
    /// pulling the model then only forces the next call to reload it.
    func checkIdleUnload() {
        guard activeRequests == 0, loadTask == nil else { return }
        guard container != nil, let lastUsedAt else { return }
        let minutes = MultiSubConfig.load().idleUnloadMinutes
        guard minutes > 0 else { return }
        if Date().timeIntervalSince(lastUsedAt) >= TimeInterval(minutes * 60) {
            unload()
        }
    }

    // MARK: - Generation

    /// One prompt through the currently configured engine.
    func generate(system: String, prompt: String, maxTokens: Int = 2048) async throws -> String {
        activeRequests += 1
        defer { activeRequests -= 1 }
        let engine = try Self.resolveEngine(config: MultiSubConfig.load())
        return try await generate(engine, system: system, prompt: prompt, maxTokens: maxTokens)
    }

    private func generate(_ engine: ResolvedEngine, system: String, prompt: String,
                          maxTokens: Int = 2048) async throws -> String {
        switch engine {
        case .local(let modelID):
            try await loadModel(modelID: modelID, allowDownload: false)
            defer { markUsed() }
            guard let container else { throw TranslatorError.modelNotDownloaded }
            var parameters = GenerateParameters()
            parameters.temperature = 0.0
            parameters.maxTokens = maxTokens
            // A fresh session per request: subtitle batches are independent and we
            // don't want history to accumulate KV cache across an episode.
            let session = ChatSession(container, instructions: system, generateParameters: parameters)
            return try await session.respond(to: prompt)
        case .cloud(let client):
            return try await client.complete(system: system, user: prompt, maxTokens: maxTokens)
        }
    }

    /// Resolves the engine once for a multi-call request and, for the local
    /// engine, loads the model up front so a missing model fails fast.
    private func prepareEngine() async throws -> ResolvedEngine {
        let engine = try Self.resolveEngine(config: MultiSubConfig.load())
        if case .local(let modelID) = engine {
            try await loadModel(modelID: modelID, allowDownload: false)
        }
        return engine
    }

    // MARK: - Translation

    /// Translates subtitle lines into the target language. `targetLang` is a
    /// BCP-47-ish code from the extension (e.g. "zh-TW").
    ///
    /// `reference`, when provided, is the official target-language subtitle
    /// aligned to each line (same count as `lines`, `nil` entries where
    /// there's no official text for that line). It's used only to steer
    /// name/proper-noun translation toward Netflix's own wording — never as
    /// a source to copy verbatim. A mismatched count is treated as no
    /// reference at all rather than risking misaligned guidance.
    ///
    /// `glossary`, when non-empty, is an episode-wide term →
    /// official-translation map (see `extractGlossary`). It supersedes
    /// `reference` when both are given: it's cheaper per batch (one block
    /// vs. per-line text) and, unlike `reference`, still helps lines with no
    /// directly-aligned official cue (e.g. CC-only text).
    ///
    /// A refused or empty batch (`CloudLLMError.refused`) falls back to one
    /// call per line, so one line that trips a provider's filter doesn't
    /// blank the other 23; a refused line comes back as "" and only that
    /// line. Other errors still throw.
    func translate(lines: [String], targetLang: String, reference: [String?]? = nil,
                   glossary: [String: String]? = nil) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let engine = try await prepareEngine()
        return try await translate(engine, lines: lines, targetLang: targetLang,
                                   reference: reference, glossary: glossary)
    }

    private func translate(_ engine: ResolvedEngine, lines: [String], targetLang: String,
                           reference: [String?]?, glossary: [String: String]?) async throws -> [String] {
        let language = LanguageNames.name(for: targetLang)
        let system = Prompts.systemPrompt(language: language)
        let glossaryBlock = Prompts.glossaryBlock(glossary, language: language)
        // Normalize to a flat, always-matching-length array so downstream
        // prompt builders never deal with a missing/mismatched reference.
        // Suppressed entirely once a glossary block is in play.
        let ref: [String?] = (glossaryBlock == nil && reference?.count == lines.count)
            ? reference! : Array(repeating: nil, count: lines.count)

        // One line. A refusal means "no translation for this line", which
        // the extension leaves untranslated and asks for again later.
        func single(_ i: Int) async throws -> String {
            do {
                let out = try await generate(engine, system: system,
                                             prompt: Prompts.singlePrompt(lines[i], language: language,
                                                                          reference: ref[i], glossaryBlock: glossaryBlock))
                return Prompts.cleanLine(out)
            } catch let error as CloudLLMError where error.isRefusal {
                return ""
            }
        }

        if lines.count == 1 { return [try await single(0)] }

        let batchOut: String?
        do {
            batchOut = try await generate(engine, system: system,
                                          prompt: Prompts.batchPrompt(lines, language: language, reference: ref,
                                                                      glossaryBlock: glossaryBlock))
        } catch let error as CloudLLMError where error.isRefusal {
            batchOut = nil
        }
        if let batchOut, let parsed = Prompts.parseNumbered(batchOut, expected: lines.count) {
            return parsed
        }
        // Fallback: line by line, when the model didn't keep the format or
        // the batch as a whole was refused.
        var results: [String] = []
        results.reserveCapacity(lines.count)
        for i in lines.indices {
            results.append(try await single(i))
        }
        return results
    }

    private static let testSentence = "I can't believe you did that behind my back."

    /// Runs one fixed sentence through the current engine so settings can
    /// show that it works and how fast it answers. The local engine's first
    /// call includes loading the model.
    func testEngine() async throws -> (latencyMs: Int, sample: String) {
        activeRequests += 1
        defer { activeRequests -= 1 }
        let start = Date()
        let engine = try await prepareEngine()
        return try await runTest(engine, start: start)
    }

    /// Tests settings that aren't saved yet (`client` built from what the
    /// user typed), so a failed test can leave the working engine alone.
    /// Only the fixed English test sentence is sent, never subtitle text,
    /// which is why this doesn't need the user's cloud consent.
    func testEngine(client: CloudLLMClient) async throws -> (latencyMs: Int, sample: String) {
        try await runTest(.cloud(client), start: Date())
    }

    /// Same as `Translator.shared.testEngine(client:)`.
    static func testEngine(client: CloudLLMClient) async throws -> (latencyMs: Int, sample: String) {
        try await shared.testEngine(client: client)
    }

    /// Unlike `translate`, a refusal or an empty answer fails the test: an
    /// engine that can't translate the test sentence isn't ready.
    private func runTest(_ engine: ResolvedEngine, start: Date) async throws -> (latencyMs: Int, sample: String) {
        let language = LanguageNames.name(for: "zh-TW")
        let out = try await generate(engine, system: Prompts.systemPrompt(language: language),
                                     prompt: Prompts.singlePrompt(Self.testSentence, language: language,
                                                                  reference: nil, glossaryBlock: nil))
        let sample = Prompts.cleanLine(out)
        guard !sample.isEmpty else {
            throw CloudLLMError.badResponse("測試句沒有拿到譯文，可以換一個模型再試。")
        }
        let elapsed = Date().timeIntervalSince(start)
        return (Int((elapsed * 1000).rounded()), sample)
    }

    // MARK: - Glossary extraction

    /// Compares original/official-translation subtitle pairs and extracts a
    /// proper-noun glossary (character names, places, etc.) with the exact
    /// wording used in the official translation. Meant to be called on
    /// chunks of an episode's aligned pairs; results are merged and cached
    /// by the caller.
    func extractGlossary(pairs: [(source: String, reference: String)], targetLang: String) async throws -> [String: String] {
        guard !pairs.isEmpty else { return [:] }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let engine = try await prepareEngine()

        let language = LanguageNames.name(for: targetLang)
        do {
            let out = try await generate(engine, system: Prompts.glossarySystemPrompt(language: language),
                                         prompt: Prompts.glossaryExtractionPrompt(pairs, language: language))
            return Prompts.parseGlossaryJSON(out)
        } catch let error as CloudLLMError where error.isRefusal {
            // The glossary is a best-effort hint; a refused chunk just adds no terms.
            return [:]
        }
    }

    // MARK: - Annotation (生字標註)

    /// Picks the few words in each line a learner at `level` would stumble
    /// on and glosses them in `targetLang`, in this line's sense, reusing the
    /// official subtitle's wording (`reference`, aligned to `lines`) where it
    /// has one. `context` is the couple of lines before the chunk, shown to
    /// the model read-only.
    ///
    /// For English sources the word list pre-selects candidates above the
    /// learner's level, which keeps density consistent and stops the model
    /// from glossing words the learner obviously knows; other sources rely
    /// on the model's judgement of the stated level.
    ///
    /// Always returns one array per line. Bad model output never throws: an
    /// output with no JSON array is retried once, then the chunk is "no
    /// annotations", and individual picks that break a rule are dropped.
    /// A refused or empty answer (`CloudLLMError.refused`) is also "no
    /// annotations" for the chunk, without a retry that would be refused
    /// the same way. Engine, network and other provider errors still throw.
    func annotate(lines: [String], context: [String], reference: [String?],
                  sourceLang: String, targetLang: String, level: String) async throws -> [[Annotation]] {
        guard !lines.isEmpty else { return [] }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let engine = try await prepareEngine()

        let ref: [String?] = reference.count == lines.count ? reference : Array(repeating: nil, count: lines.count)
        let candidates: [[String]]? = LanguageNames.isEnglish(sourceLang)
            ? lines.map { Lexicon.candidates(in: $0, learnerLevel: level) }
            : nil
        // Netflix track codes can be regional ("en-GB"); the prompt wants a name.
        // The DOM fallback may not know the track language at all.
        let sourceLanguage: String
        if sourceLang.trimmingCharacters(in: .whitespaces).isEmpty {
            sourceLanguage = "the show's language"
        } else {
            let fullName = LanguageNames.name(for: sourceLang)
            sourceLanguage = fullName != sourceLang
                ? fullName : LanguageNames.name(for: LanguageNames.primarySubtag(sourceLang))
        }
        let targetLanguage = LanguageNames.name(for: targetLang)
        let system = Prompts.annotateSystemPrompt(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                                                  targetLang: targetLang, level: level,
                                                  hasCandidates: candidates != nil)
        let prompt = Prompts.annotatePrompt(lines: lines, context: context, reference: ref,
                                            candidates: candidates, targetLanguage: targetLanguage)

        let none = Array(repeating: [Annotation](), count: lines.count)
        do {
            let first = try await generate(engine, system: system, prompt: prompt)
            var parsed = Prompts.parseAnnotations(first, lineCount: lines.count)
            if parsed == nil {
                let retry = try await generate(engine, system: system, prompt: prompt + Prompts.annotateRetrySuffix)
                parsed = Prompts.parseAnnotations(retry, lineCount: lines.count)
            }
            guard let parsed else { return none }
            return Prompts.validateAnnotations(parsed, lines: lines, targetLang: targetLang)
        } catch let error as CloudLLMError where error.isRefusal {
            return none
        }
    }

    // MARK: - Vocabulary extraction (生詞本)

    /// Extracts notable English vocabulary from an episode's source-language
    /// subtitle lines, for the "生詞本" feature. Runs in the host app — the
    /// caller is responsible for verifying `sourceLang` is English before
    /// calling this; this function assumes it and does not re-check, since
    /// by the time lines reach here they're already just plain subtitle text
    /// with no language tag attached.
    ///
    /// `progress` reports finished / total segments
    /// (`vocabSegmentCount(lineCount:)`): 0 of total once the engine is
    /// ready (for the local engine, after the model has loaded), then once
    /// per segment. There is no finer-grained progress within a single
    /// model call.
    ///
    /// A segment that fails is skipped, except that a rejected API key
    /// throws right away, and an episode where every segment failed throws
    /// the last error, so the UI can say what went wrong.
    func extractVocabulary(lines: [String], targetLang: String,
                           progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> [VocabWord] {
        guard !lines.isEmpty else { return [] }
        // This can run for many segments over a long stretch of wall time
        // (each segment is its own model call) — `isBusy` must stay true for
        // the whole extraction, not just `loadModel`, or the app's 60s
        // idle-unload timer could yank the model out mid-extraction.
        activeRequests += 1
        defer { activeRequests -= 1 }
        let engine = try await prepareEngine()

        let language = LanguageNames.name(for: targetLang)
        let segments = stride(from: 0, to: lines.count, by: Self.vocabSegmentSize).map {
            Array(lines[$0..<min($0 + Self.vocabSegmentSize, lines.count)])
        }
        progress?(0, segments.count)

        // Dedup by lemma, first occurrence wins. An earlier design copied the
        // glossary's cross-segment vote-tallying scheme (require >=2 segments
        // to agree on the exact same output before trusting a lemma),
        // reasoning that it was the same "model cross-wires fields in a
        // multi-item response" risk as glossary extraction. Real-episode
        // testing showed that assumption was wrong: unlike glossary's target
        // value (an official translation string, which the model tends to
        // reproduce identically whenever it's copying the same source text),
        // a word's `definitionEn`/`translation`/`example` are freely
        // generated prose that differs between calls even for the same
        // lemma — so two segments essentially never produce byte-identical
        // output, votes never reached 2, and every lemma in a real
        // multi-segment episode got silently dropped (verified: a full
        // episode produced 0 words, while a single-segment test batch
        // — which bypassed the vote requirement entirely — worked fine,
        // which is what hid this until real usage). The actual
        // within-a-single-response cross-wiring risk (one JSON array
        // attaching word A's definition to word B) is still a known,
        // accepted risk here — lower-stakes than glossary's proper-noun
        // mistranslation (a wrong definition on one vocab-list entry vs. a
        // wrong name baked across a whole episode's subtitles), and without
        // a cheap mitigation for free-generated text the way tallying was
        // for glossary's narrow string-matching case.
        var seen: [String: RawVocabEntry] = [:]
        var lastError: Error?

        for (index, segment) in segments.enumerated() {
            // Refresh the idle clock on every segment, not just once at the
            // top of the function — a long episode's extraction can outlast
            // the idle threshold on its own otherwise.
            markUsed()
            let entries: [RawVocabEntry]
            do {
                entries = try await extractVocabSegment(engine, lines: segment, language: language)
            } catch let error as CloudLLMError {
                // A rejected key fails every segment the same way: stop now
                // and say so, instead of an empty word list.
                if case .authFailed = error { throw error }
                // One flaky segment shouldn't sink the episode.
                lastError = error
                entries = []
            } catch {
                lastError = error
                entries = []
            }
            for entry in entries {
                let lemma = entry.lemma.lowercased()
                // Guardrail for when the model doesn't fully follow the
                // "skip function words" instruction.
                guard !lemma.isEmpty, !Lexicon.isStopword(lemma) else { continue }
                if seen[lemma] == nil { seen[lemma] = entry }
            }
            progress?(index + 1, segments.count)
        }
        // Nothing came back and at least one segment errored (offline, rate
        // limit…): report that error rather than "this episode has no words".
        if seen.isEmpty, let lastError { throw lastError }

        return seen.values.map { entry in
            // The word list beats the model's own CEFR guess.
            let corrected = Lexicon.cefrWordlist[entry.lemma.lowercased()] ?? entry.cefr
            return VocabWord(word: entry.word, lemma: entry.lemma, pos: entry.pos, cefr: corrected,
                             definitionEn: entry.definitionEn, translation: entry.translation,
                             example: entry.example, exampleTranslation: entry.exampleTranslation,
                             cueIndex: Self.firstCueIndex(for: entry.lemma, in: lines))
        }
    }

    /// ~40 lines/segment, matching the glossary's `GLOSSARY_SEGMENT_SIZE`
    /// (extension/background.js) — same "bounded prompt per call" tradeoff.
    private static let vocabSegmentSize = 40

    /// How many model calls (progress units) `extractVocabulary` makes for
    /// `lineCount` lines, so a caller can show the total before it starts.
    nonisolated static func vocabSegmentCount(lineCount: Int) -> Int {
        (lineCount + vocabSegmentSize - 1) / vocabSegmentSize
    }

    /// Runs one segment through the engine, retrying once on unparseable
    /// output. Returns `[]` — not an error — if both attempts fail to parse;
    /// a bad segment shouldn't abort the whole episode.
    private func extractVocabSegment(_ engine: ResolvedEngine, lines: [String],
                                     language: String) async throws -> [RawVocabEntry] {
        let system = Prompts.vocabSystemPrompt(language: language)
        let prompt = Prompts.vocabExtractionPrompt(lines)
        let out = try await generate(engine, system: system, prompt: prompt)
        if let parsed = Prompts.parseVocabJSON(out) { return parsed }
        let retryOut = try await generate(engine, system: system, prompt: prompt + Prompts.vocabRetrySuffix)
        return Prompts.parseVocabJSON(retryOut) ?? []
    }

    /// Case-insensitive whole-word(-prefix) search for `lemma` in `lines`,
    /// matching inflected forms too (e.g. lemma "reluctant" matches
    /// "reluctantly"). Returns -1 if no line matches (e.g. the model
    /// paraphrased a lemma that isn't literally in the subtitle text).
    private static func firstCueIndex(for lemma: String, in lines: [String]) -> Int {
        guard !lemma.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: lemma))\\w*\\b",
                options: .caseInsensitive)
        else { return -1 }
        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, range: range) != nil { return i }
        }
        return -1
    }
}
