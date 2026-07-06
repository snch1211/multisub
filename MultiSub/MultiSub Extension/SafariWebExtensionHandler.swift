//
//  SafariWebExtensionHandler.swift
//  MultiSub Extension
//
//  Receives native messages from the web extension and runs subtitle
//  translation on the local Gemma model (via the shared Translator actor).
//  The Translator is a singleton so the model stays loaded for as long as
//  Safari keeps this extension process alive.
//

import AppKit
import SafariServices
import os.log

let logger = Logger(subsystem: "com.seanhuang.multisub.Extension", category: "native")

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let action = message["action"] as? String ?? ""

        Task {
            let reply: [String: Any]
            switch action {
            case "ping":
                reply = await handlePing(message)
            case "translate":
                reply = await handleTranslate(message)
            case "extract-glossary":
                reply = await handleExtractGlossary(message)
            case "unload":
                reply = await handleUnload()
            case "open-app":
                reply = await handleOpenApp(message)
            case "save-transcript":
                reply = await handleSaveTranscript(message)
            default:
                reply = ["ok": false, "error": "unknown-action"]
            }
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    private func handlePing(_ message: [String: Any]) async -> [String: Any] {
        // M2: idle-unload has no reliable internal timer in this process
        // (see Translator.checkIdleUnload doc comment) — piggyback the
        // check on every ping instead, since a ping arriving at all proves
        // the process is currently awake to run it.
        await Translator.shared.checkIdleUnload()
        let config = MultiSubConfig.load()
        let downloaded = Translator.isModelDownloaded(config.modelID)
        let loaded = await Translator.shared.isLoaded

        // D4: background.js attaches a fresh cache index to every ping
        // request; persist it so the App's cache-management tab can read it
        // (see CacheSync's doc comment in TranslatorCore.swift for why this
        // indirection is necessary).
        if let rawEntries = message["cacheIndex"] as? [[String: Any]] {
            let entries: [CacheEntry] = rawEntries.compactMap { dict in
                guard let movieId = dict["movieId"] as? String,
                      let targetLang = dict["targetLang"] as? String,
                      let sourceLang = dict["sourceLang"] as? String,
                      let lineCount = dict["lineCount"] as? Int,
                      let bytes = dict["bytes"] as? Int,
                      let savedAt = dict["savedAt"] as? Double
                else { return nil }
                // 2026-07-06: title fields are best-effort (see CacheEntry's
                // doc comment) — absent/non-string/non-int just decodes to nil.
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
            "modelDownloaded": downloaded,
            "modelLoaded": loaded,
            // D1: piggyback the overlay style so background.js's periodic
            // ping-native (see CLAUDE.md) can pick up App-side edits without
            // a dedicated get-styles round trip.
            "styles": Self.stylesDict(config.styles),
        ]
        // D4: the reverse direction — a delete the App queued since our last
        // ping. Consuming it here (not just reading) means it's applied at
        // most once even if this reply is somehow lost; background.js is
        // responsible for actually removing the storage.local keys.
        if let pending = CacheSync.consumePendingDelete() {
            reply["cacheDeleteRequest"] = Self.deleteRequestDict(pending)
        }
        return reply
    }

    private static func deleteRequestDict(_ request: CacheDeleteRequest) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Encodes `SubtitleStyle` into the plist-compatible `[String: Any]`
    /// shape `NSExtensionItem.userInfo` requires (a raw `Data` blob from
    /// `JSONEncoder` alone isn't a valid reply value here).
    private static func stylesDict(_ styles: SubtitleStyle) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(styles),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// D1: wakes/launches the host app and routes it to a specific panel via
    /// its registered `multisub://` URL scheme (`MultiSub/Info.plist`).
    /// V4 extended this to take a `destination`/`movieId` (defaulting to D1's
    /// original `styles` destination so the existing popup button keeps
    /// working unchanged) so the same action can also route to
    /// `multisub://vocab?movieId=...`. `NSWorkspace.open` returning `false`
    /// covers "app not installed / scheme not registered with LaunchServices"
    /// — surfaced to popup.js as `open-failed` per the message-protocol contract.
    private func handleOpenApp(_ message: [String: Any]) async -> [String: Any] {
        let destination = message["destination"] as? String ?? "styles"
        var components = URLComponents()
        components.scheme = "multisub"
        components.host = destination
        if destination == "vocab", let movieId = message["movieId"] as? String {
            components.queryItems = [URLQueryItem(name: "movieId", value: movieId)]
        }
        guard let url = components.url else {
            return ["ok": false, "error": "open-failed"]
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        return opened ? ["ok": true] : ["ok": false, "error": "open-failed"]
    }

    /// V4: content.js's "整理本集單字" button. Stages the transcript in the
    /// shared container; the App picks it up when routed to
    /// `multisub://vocab?movieId=...` (see `PendingTranscriptStore`).
    ///
    /// Also unloads this process's (the Safari extension's) model here —
    /// user-requested (2026-07-04): the App is about to load its own,
    /// separate copy of the model in its own process to run
    /// `extractVocabulary` (see vocab-design.md §1 — App execution was
    /// chosen specifically so extraction doesn't share memory/GPU with the
    /// extension's real-time translation), so at the exact moment the user
    /// commits to running extraction, there's no more reason for *this*
    /// process to keep its copy resident, and doing so would mean two
    /// multi-GB model instances loaded at once. This reuses M1's existing
    /// `unload()` (same mechanism the settings toggle uses) rather than
    /// inventing a new one; the extension's next `translate` call reloads
    /// lazily as usual, same as any other unload.
    ///
    /// 2026-07-08 bug fix: unconditionally unloading here is *not* safe the
    /// way M1's unload is. M1 (settings.enabled -> false) is paired with
    /// background.js bumping every in-flight episode's generation, so no
    /// further `translate` batches get sent — a mid-flight batch just
    /// finishes on its already-captured container and nothing more is asked
    /// of the model. `save-transcript` has no such coordination:
    /// background.js's `handleEpisode` loop keeps sending the *next*
    /// `translate` batch for the episode the user is still watching,
    /// regardless of whether they also clicked "整理本集單字". Unloading out
    /// from under that live loop forces the next batch's `loadModel` to
    /// reload the multi-GB model from disk mid-episode — slow enough to
    /// surface as translation errors/stalls, which is exactly the "clicking
    /// 整理本集單字 while translating breaks things" failure mode tracked in
    /// PLAN.md's known-issues table. Skipping the unload while the
    /// translator reports busy trades a temporary two-models-resident memory
    /// spike for not disrupting the episode already in progress; the
    /// existing idle-unload path (`checkIdleUnload`, piggybacked on `ping`)
    /// reclaims it once the episode finishes and the extension goes idle.
    private func handleSaveTranscript(_ message: [String: Any]) async -> [String: Any] {
        guard let movieId = message["movieId"] as? String, !movieId.isEmpty,
              let seriesTitle = message["seriesTitle"] as? String,
              let sourceLang = message["sourceLang"] as? String,
              let targetLang = message["targetLang"] as? String,
              let lines = message["lines"] as? [String], !lines.isEmpty
        else { return ["ok": false, "error": "bad-request"] }
        PendingTranscriptStore.save(PendingTranscript(
            movieId: movieId, seriesTitle: seriesTitle,
            episodeTitle: message["episodeTitle"] as? String,
            seasonNumber: message["seasonNumber"] as? Int,
            sourceLang: sourceLang, targetLang: targetLang, lines: lines))
        if await !Translator.shared.isBusy {
            await Translator.shared.unload()
        }
        return ["ok": true]
    }

    private func handleTranslate(_ message: [String: Any]) async -> [String: Any] {
        guard let lines = message["lines"] as? [String], !lines.isEmpty else {
            return ["ok": false, "error": "bad-request"]
        }
        let targetLang = message["targetLang"] as? String ?? "zh-TW"
        // T3 stage 1: per-line official reference text, null where a line
        // has none. Native messaging decodes JSON null as NSNull, hence `as? String`.
        let reference: [String?]? = (message["reference"] as? [Any])?.map { $0 as? String }
        // T3 stage 2: episode-wide term glossary, takes precedence over `reference`.
        let glossary = message["glossary"] as? [String: String]
        do {
            let translations = try await Translator.shared.translate(
                lines: lines, targetLang: targetLang, reference: reference, glossary: glossary)
            return ["ok": true, "translations": translations]
        } catch TranslatorError.modelNotDownloaded {
            return ["ok": false, "error": "model-not-ready"]
        } catch {
            logger.error("translate failed: \(String(describing: error))")
            return ["ok": false, "error": "translate-failed: \(error.localizedDescription)"]
        }
    }

    private func handleUnload() async -> [String: Any] {
        await Translator.shared.unload()
        return ["ok": true]
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
        } catch TranslatorError.modelNotDownloaded {
            return ["ok": false, "error": "model-not-ready"]
        } catch {
            logger.error("extract-glossary failed: \(String(describing: error))")
            return ["ok": false, "error": "extract-glossary-failed: \(error.localizedDescription)"]
        }
    }
}
