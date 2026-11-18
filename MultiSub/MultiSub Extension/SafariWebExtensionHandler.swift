//
//  SafariWebExtensionHandler.swift
//  MultiSub Extension
//
//  Receives native messages from the web extension (background.js) and runs
//  them on the shared Translator actor, which sends each request to the
//  local Gemma model or the user's cloud engine (see docs/ARCHITECTURE.md
//  §5.2 for every action's request and reply). The Translator is a
//  singleton so the local model stays loaded for as long as Safari keeps
//  this extension process alive.
//
//  Requests can be handled concurrently, so this class keeps no state of
//  its own. The AI engine (provider, model, API key, consent) is set up in
//  the app only: no action here changes it or reads an API key back, so the
//  extension can use the engine but never configure it.
//

import AppKit
import SafariServices
import os.log

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MultiSub.Extension", category: "native")

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let action = message["action"] as? String ?? ""
        let lineCount = (message["lines"] as? [Any])?.count ?? 0
        // Debug level: not persisted, but `log stream --level debug` shows
        // the request flow when diagnosing "subtitles don't load" reports.
        logger.debug("native \(action, privacy: .public) lines=\(lineCount, privacy: .public)")

        Task {
            let reply: [String: Any]
            switch action {
            case "ping":
                reply = await handlePing(message)
            case "translate":
                reply = await handleTranslate(message)
            case "extract-glossary":
                reply = await handleExtractGlossary(message)
            case "annotate":
                reply = await handleAnnotate(message)
            case "set-prefs":
                reply = handleSetPrefs(message)
            case "unload":
                reply = await handleUnload()
            case "open-app":
                reply = await handleOpenApp(message)
            case "save-transcript":
                reply = await handleSaveTranscript(message)
            case "vocab-status":
                reply = handleVocabStatus(message)
            default:
                reply = ["ok": false, "error": "unknown-action"]
            }
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    // MARK: - ping

    private func handlePing(_ message: [String: Any]) async -> [String: Any] {
        // Idle-unload has no reliable internal timer in this process (see
        // Translator.checkIdleUnload's doc comment) — piggyback the check on
        // every ping instead, since a ping arriving at all proves the process
        // is currently awake to run it.
        await Translator.shared.checkIdleUnload()
        let config = MultiSubConfig.load()
        let engine = await Translator.engineStatus(config: config)

        // background.js attaches a fresh cache index to every ping request;
        // persist it so the app's cache-management tab can read it (see
        // CacheSync's doc comment in Stores.swift for why this indirection is
        // necessary).
        if let rawEntries = message["cacheIndex"] as? [[String: Any]] {
            let entries: [CacheEntry] = rawEntries.compactMap { dict in
                guard let movieId = dict["movieId"] as? String,
                      let targetLang = dict["targetLang"] as? String,
                      let sourceLang = dict["sourceLang"] as? String,
                      let lineCount = dict["lineCount"] as? Int,
                      let bytes = dict["bytes"] as? Int,
                      let savedAt = dict["savedAt"] as? Double
                else { return nil }
                // Title fields are best-effort (see CacheEntry's doc comment)
                // — absent/non-string/non-int just decodes to nil.
                return CacheEntry(movieId: movieId, targetLang: targetLang, sourceLang: sourceLang,
                                  lineCount: lineCount, bytes: bytes, savedAt: savedAt,
                                  seriesTitle: dict["seriesTitle"] as? String,
                                  episodeTitle: dict["episodeTitle"] as? String,
                                  seasonNumber: dict["seasonNumber"] as? Int)
            }
            CacheSync.writeIndex(entries)
        }

        var reply: [String: Any] = [
            "ok": true,
            "modelId": config.modelID,
            "modelDownloaded": engine.localModelDownloaded,
            "modelLoaded": engine.localModelLoaded,
            // Piggyback the overlay style so background.js's periodic ping
            // picks up app-side edits without a dedicated round trip.
            "styles": Self.jsonDict(config.styles),
            "engine": engine.dictionary,
        ]
        // Left out until either side has set a preference.
        if let prefs = config.prefs { reply["prefs"] = Self.prefsDict(prefs) }
        // The reverse direction — a delete the app queued since our last
        // ping. Consuming it here (not just reading) means it's applied at
        // most once even if this reply is somehow lost; background.js is
        // responsible for actually removing the storage.local keys.
        if let pending = CacheSync.consumePendingDelete() {
            reply["cacheDeleteRequest"] = Self.jsonDict(pending)
        }
        return reply
    }

    // MARK: - AI work

    private func handleTranslate(_ message: [String: Any]) async -> [String: Any] {
        guard let lines = message["lines"] as? [String], !lines.isEmpty else {
            return ["ok": false, "error": "bad-request"]
        }
        let targetLang = message["targetLang"] as? String ?? "zh-TW"
        // Per-line official reference text, null where a line has none.
        // Native messaging decodes JSON null as NSNull, hence `as? String`.
        let reference: [String?]? = (message["reference"] as? [Any])?.map { $0 as? String }
        // Episode-wide term glossary, takes precedence over `reference`.
        let glossary = message["glossary"] as? [String: String]
        do {
            let translations = try await Translator.shared.translate(
                lines: lines, targetLang: targetLang, reference: reference, glossary: glossary)
            return ["ok": true, "translations": translations]
        } catch {
            return Self.errorReply(error, action: "translate")
        }
    }

    private func handleExtractGlossary(_ message: [String: Any]) async -> [String: Any] {
        guard let pairsRaw = message["pairs"] as? [[String: Any]], !pairsRaw.isEmpty else {
            return ["ok": false, "error": "bad-request"]
        }
        let pairs: [(source: String, reference: String)] = pairsRaw.compactMap { p in
            guard let source = p["source"] as? String, let reference = p["reference"] as? String else { return nil }
            return (source, reference)
        }
        guard !pairs.isEmpty else { return ["ok": false, "error": "bad-request"] }
        let targetLang = message["targetLang"] as? String ?? "zh-TW"
        do {
            let glossary = try await Translator.shared.extractGlossary(pairs: pairs, targetLang: targetLang)
            return ["ok": true, "glossary": glossary]
        } catch {
            return Self.errorReply(error, action: "extract-glossary")
        }
    }

    private func handleAnnotate(_ message: [String: Any]) async -> [String: Any] {
        guard let lines = message["lines"] as? [String], !lines.isEmpty else {
            return ["ok": false, "error": "bad-request"]
        }
        let context = (message["context"] as? [Any])?.compactMap { $0 as? String } ?? []
        let reference: [String?] = (message["reference"] as? [Any])?.map { $0 as? String } ?? []
        let sourceLang = message["sourceLang"] as? String ?? "en"
        let targetLang = message["targetLang"] as? String ?? "zh-TW"
        let level = message["level"] as? String ?? "B1"
        do {
            let annotations = try await Translator.shared.annotate(
                lines: lines, context: context, reference: reference,
                sourceLang: sourceLang, targetLang: targetLang, level: level)
            return ["ok": true,
                    "annotations": annotations.map { $0.map { ["term": $0.term, "gloss": $0.gloss] } }]
        } catch {
            return Self.errorReply(error, action: "annotate")
        }
    }

    // MARK: - Settings

    /// Newest `updatedAt` wins, so a popup change and an app change made
    /// around the same time settle on the later one. Fields the request
    /// leaves out keep their stored value. Replies with whichever prefs won,
    /// so the caller can adopt them when its own copy was older.
    private func handleSetPrefs(_ message: [String: Any]) -> [String: Any] {
        guard let raw = message["prefs"] as? [String: Any],
              let updatedAt = (raw["updatedAt"] as? NSNumber)?.doubleValue
        else { return ["ok": false, "error": "bad-request"] }
        let incoming = SharedPrefs(mode: raw["mode"] as? String,
                                   targetLang: raw["targetLang"] as? String,
                                   annotateLevel: raw["annotateLevel"] as? String,
                                   updatedAt: updatedAt)
        let config = MultiSubConfig.update { config in
            let stored = config.prefs
            guard updatedAt > (stored?.updatedAt ?? -1) else { return }
            config.prefs = SharedPrefs(mode: incoming.mode ?? stored?.mode,
                                       targetLang: incoming.targetLang ?? stored?.targetLang,
                                       annotateLevel: incoming.annotateLevel ?? stored?.annotateLevel,
                                       updatedAt: updatedAt)
        }
        var reply: [String: Any] = ["ok": true]
        if let prefs = config.prefs { reply["prefs"] = Self.prefsDict(prefs) }
        return reply
    }

    // MARK: - Lifecycle / app hand-off

    private func handleUnload() async -> [String: Any] {
        await Translator.shared.unload()
        return ["ok": true]
    }

    /// Wakes/launches the host app and routes it to a specific panel via its
    /// registered `multisub://` URL scheme (`MultiSub/Info.plist`). Takes a
    /// `destination`/`movieId` (defaulting to the original `styles`
    /// destination so the popup's button works unchanged) so the same action
    /// can also route to `multisub://vocab?movieId=...`, which starts
    /// organizing that episode in the app. `NSWorkspace.open` returning
    /// `false` covers "app not installed / scheme not registered with
    /// LaunchServices" — surfaced to popup.js as `open-failed`.
    ///
    /// Opening a URL from this process usually doesn't bring the app to the
    /// front (cooperative activation: Safari is the active app, not us), so
    /// nothing may depend on the user seeing the app's window; the popup
    /// follows the work through `vocab-status` instead.
    private func handleOpenApp(_ message: [String: Any]) async -> [String: Any] {
        let destination = message["destination"] as? String ?? "styles"
        var components = URLComponents()
        components.scheme = "multisub"
        components.host = destination
        let vocabMovieId = destination == "vocab" ? (message["movieId"] as? String) : nil
        if let vocabMovieId {
            components.queryItems = [URLQueryItem(name: "movieId", value: vocabMovieId)]
        }
        var opened = false
        if let url = components.url {
            opened = await MainActor.run { NSWorkspace.shared.open(url) }
        }
        guard opened else {
            // `save-transcript` already marked the episode handed off; left
            // as is, the popup would show it waiting for the app.
            if let vocabMovieId { VocabStatusStore.markOpenFailed(movieId: vocabMovieId) }
            return ["ok": false, "error": VocabStatusStore.openFailedCode]
        }
        return ["ok": true]
    }

    /// content.js's "整理本集單字" button. Stages the transcript in the
    /// shared container; the app picks it up when routed to
    /// `multisub://vocab?movieId=...` (see `PendingTranscriptStore`). Also
    /// marks the episode handed off in `VocabStatusStore`, so the popup shows
    /// it right away and not an earlier run's result.
    ///
    /// Also unloads this process's (the Safari extension's) local model
    /// here, at the user's request: the app is about to run
    /// `extractVocabulary` in its own process (app-side execution was chosen
    /// specifically so extraction doesn't share memory/GPU with the
    /// extension's real-time translation), so at the moment the user commits
    /// to running extraction there's no more reason for *this* process to
    /// keep its copy resident, and doing so would mean two multi-GB model
    /// instances loaded at once. This reuses the same `unload()` the
    /// settings toggle uses; the extension's next local request reloads
    /// lazily as usual.
    ///
    /// Unconditionally unloading here is *not* safe the way the toggle-off
    /// unload is. Toggling off is paired with background.js bumping every
    /// in-flight episode's generation, so no further batches get sent — a
    /// mid-flight batch just finishes on its already-captured container and
    /// nothing more is asked of the model. `save-transcript` has no such
    /// coordination: background.js keeps sending the *next* batch for the
    /// episode the user is still watching, regardless of whether they also
    /// clicked "整理本集單字". Unloading out from under that live loop forces
    /// the next batch's `loadModel` to reload the multi-GB model from disk
    /// mid-episode — slow enough to surface as translation errors/stalls.
    /// Skipping the unload while the translator reports busy trades a
    /// temporary two-models-resident memory spike for not disrupting the
    /// episode already in progress; the idle-unload path (`checkIdleUnload`,
    /// piggybacked on `ping`) reclaims it once the episode finishes and the
    /// extension goes idle.
    private func handleSaveTranscript(_ message: [String: Any]) async -> [String: Any] {
        guard let movieId = message["movieId"] as? String, VocabStatusStore.isValidMovieId(movieId),
              let seriesTitle = message["seriesTitle"] as? String,
              let sourceLang = message["sourceLang"] as? String,
              let targetLang = message["targetLang"] as? String,
              let lines = message["lines"] as? [String], !lines.isEmpty
        else { return ["ok": false, "error": "bad-request"] }
        let transcript = PendingTranscript(
            movieId: movieId, seriesTitle: seriesTitle,
            episodeTitle: message["episodeTitle"] as? String,
            seasonNumber: message["seasonNumber"] as? Int,
            sourceLang: sourceLang, targetLang: targetLang, lines: lines)
        PendingTranscriptStore.save(transcript)
        VocabStatusStore.markHandedOff(movieId: movieId, title: transcript.displayTitle)
        if await !Translator.shared.isBusy {
            await Translator.shared.unload()
        }
        return ["ok": true]
    }

    /// Where 「整理本集單字」 stands for one episode, for the popup:
    /// `state` is `queued` (handed off or waiting its turn), `running` with
    /// `done`/`total` segments, `done` with `wordCount`, `failed` with
    /// `code` and the app's `message`, or `none` when nothing was asked for
    /// recently. An entry the app stopped refreshing reads as `failed`
    /// (`VocabStatusStore.effective`).
    private func handleVocabStatus(_ message: [String: Any]) -> [String: Any] {
        guard let movieId = message["movieId"] as? String, VocabStatusStore.isValidMovieId(movieId) else {
            return ["ok": false, "error": "bad-request"]
        }
        guard let status = VocabStatusStore.current(movieId: movieId) else {
            return ["ok": true, "movieId": movieId, "state": "none"]
        }
        var reply: [String: Any] = [
            "ok": true,
            "movieId": movieId,
            "state": status.state.rawValue,
            "accepted": status.accepted,
            "done": status.done,
            "total": status.total,
            // Milliseconds, like JS `Date.now()`.
            "updatedAt": (status.updatedAt.timeIntervalSince1970 * 1000).rounded(),
        ]
        if let wordCount = status.wordCount { reply["wordCount"] = wordCount }
        if let code = status.code { reply["code"] = code }
        if let text = status.message { reply["message"] = text }
        if let title = status.title { reply["title"] = title }
        return reply
    }

    // MARK: - Helpers

    /// `{ok:false, error:<code>, detail:<message>}` with the codes the
    /// extension shows to the user. Messages from `CloudLLMError` are
    /// already scrubbed of anything key-like.
    private static func errorReply(_ error: Error, action: String) -> [String: Any] {
        if let error = error as? TranslatorError {
            return ["ok": false, "error": error.code, "detail": error.localizedDescription]
        }
        if let error = error as? CloudLLMError {
            logger.error("\(action, privacy: .public) failed: \(error.code, privacy: .public)")
            return ["ok": false, "error": error.code, "detail": error.message]
        }
        // In practice an `unload` (MultiSub switched off) or a model switch
        // that arrived while this request waited for the local model to
        // load. The code stays `<action>-failed`, which background.js
        // retries; the default description would be English.
        if error is CancellationError {
            return ["ok": false, "error": "\(action)-failed", "detail": "這次要求被中止了，請再試一次。"]
        }
        logger.error("\(action, privacy: .public) failed: \(String(describing: error))")
        return ["ok": false, "error": "\(action)-failed", "detail": error.localizedDescription]
    }

    private static func prefsDict(_ prefs: SharedPrefs) -> [String: Any] {
        var d: [String: Any] = ["updatedAt": prefs.updatedAt]
        if let mode = prefs.mode { d["mode"] = mode }
        if let targetLang = prefs.targetLang { d["targetLang"] = targetLang }
        if let annotateLevel = prefs.annotateLevel { d["annotateLevel"] = annotateLevel }
        return d
    }

    /// Encodes a Codable value into the plist-compatible `[String: Any]`
    /// shape `NSExtensionItem.userInfo` requires (a raw `Data` blob from
    /// `JSONEncoder` alone isn't a valid reply value here).
    private static func jsonDict<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
