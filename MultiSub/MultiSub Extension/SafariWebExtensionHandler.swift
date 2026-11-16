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
//  its own. API keys arrive in `set-engine` and go straight to the keychain,
//  or in `test-engine` / `list-models` for that one request only (a key
//  typed but not saved yet); they are never logged or sent back to
//  JavaScript.
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
            case "set-engine":
                reply = await handleSetEngine(message)
            case "test-engine":
                reply = await handleTestEngine(message)
            case "list-models":
                reply = await handleListModels(message)
            case "get-engine-options":
                reply = await handleGetEngineOptions()
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

    /// Every field is optional and only what's present changes. `apiKey`:
    /// absent leaves the saved key alone, an empty string deletes it,
    /// anything else replaces it (for `provider`, or the saved provider when
    /// the request names none).
    ///
    /// `consent: true` records the user's consent to send subtitle text to
    /// that provider (the popup's confirmation step). A request that would
    /// leave `engine` on `cloud` for a provider with no recorded consent,
    /// and doesn't carry `consent: true`, is refused with
    /// `consent-required` before anything (key included) is written, so the
    /// caller can ask and send the same request again. `auto` needs no
    /// consent here because `Translator.resolveEngine` skips an unconsented
    /// provider, and a request that only deletes the key isn't asked either.
    private func handleSetEngine(_ message: [String: Any]) async -> [String: Any] {
        var engine: EngineKind?
        if let raw = message["engine"] as? String {
            guard let kind = EngineKind(rawValue: raw) else {
                return ["ok": false, "error": "bad-request", "detail": "未知的引擎：\(raw)"]
            }
            engine = kind
        }
        var provider: CloudProvider?
        if let raw = message["provider"] as? String {
            guard let p = CloudProvider(rawValue: raw) else {
                return ["ok": false, "error": "bad-request", "detail": "未知的 AI 服務：\(raw)"]
            }
            provider = p
        }
        let model = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (message["baseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let consent = message["consent"] as? Bool ?? false
        let apiKey = message["apiKey"] as? String
        let savesKey = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let current = MultiSubConfig.load()
        let keyProvider = provider ?? current.cloud.provider
        if keyProvider.needsBaseURL, let baseURL, !baseURL.isEmpty, !Self.isValidBaseURL(baseURL) {
            return ["ok": false, "error": "bad-request", "detail": "API 網址格式不正確，請以 http:// 或 https:// 開頭。"]
        }

        let configuresCloud = engine != nil || provider != nil || model != nil || baseURL != nil || savesKey
        if configuresCloud, (engine ?? current.engine) == .cloud, !consent,
           !current.hasCloudConsent(for: keyProvider) {
            // A Latin provider name gets a space after 傳給; the custom
            // recipient is Chinese and doesn't.
            let recipient = keyProvider == .custom ? keyProvider.consentRecipient : " " + keyProvider.consentRecipient
            return ["ok": false, "error": "consent-required",
                    "detail": "使用前要先同意把字幕文字從這台 Mac 直接傳給\(recipient)。"]
        }

        if let apiKey {
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SecretStore.deleteAPIKey(for: keyProvider)
            } else {
                do {
                    try SecretStore.setAPIKey(apiKey, for: keyProvider)
                } catch {
                    logger.error("set-engine: saving the key failed")
                    return ["ok": false, "error": "keychain-failed", "detail": error.localizedDescription]
                }
            }
        }

        let config = MultiSubConfig.update { config in
            if let engine { config.engine = engine }
            if let provider {
                // A model id from another provider would only fail; fall
                // back to the new provider's default unless one was given.
                if provider != config.cloud.provider, model == nil { config.cloud.model = "" }
                config.cloud.provider = provider
            }
            if let model { config.cloud.model = model }
            if let baseURL { config.cloud.baseURL = baseURL }
            // After the provider change above, so consent goes to the
            // provider this write leaves selected.
            if consent { config.recordCloudConsent(for: config.cloud.provider) }
        }
        return ["ok": true, "engine": await Translator.engineStatus(config: config).dictionary]
    }

    /// Without `provider`: tests the engine as saved. With `provider`
    /// (plus optional `model`, `baseURL`, `apiKey`): tests those settings
    /// without saving anything, so the popup can test before it saves and a
    /// failed test leaves the working engine alone. An empty or missing
    /// `apiKey` uses the key saved for that provider; missing `model` /
    /// `baseURL` fall back to the saved ones when the provider is the saved
    /// provider.
    private func handleTestEngine(_ message: [String: Any]) async -> [String: Any] {
        do {
            let result: (latencyMs: Int, sample: String)
            if message["provider"] != nil {
                switch Self.candidate(message) {
                case .invalid(let reply): return reply
                case .client(let client): result = try await Translator.shared.testEngine(client: client)
                }
            } else {
                result = try await Translator.shared.testEngine()
            }
            return ["ok": true, "latencyMs": result.latencyMs, "sample": result.sample]
        } catch {
            return Self.errorReply(error, action: "test-engine")
        }
    }

    /// Uses `apiKey` from the request when it has one (a key typed but not
    /// saved yet; it's used for this one request and never stored),
    /// otherwise the key saved for `provider`. A custom server takes
    /// `baseURL` from the request (or the saved one when absent).
    private func handleListModels(_ message: [String: Any]) async -> [String: Any] {
        guard let raw = message["provider"] as? String, let provider = CloudProvider(rawValue: raw) else {
            return ["ok": false, "error": "bad-request"]
        }
        let config = MultiSubConfig.load()
        let baseURL = (message["baseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (provider == config.cloud.provider ? config.cloud.baseURL : "")
        if provider.needsBaseURL, baseURL.isEmpty {
            return ["ok": false, "error": "bad-request", "detail": "請先填寫 API 網址。"]
        }
        let key = Self.requestKey(message, provider: provider)
        if provider.keyRequired, key == nil {
            return ["ok": false, "error": "engine-not-ready", "detail": "還沒儲存這個 AI 服務的 API Key。"]
        }
        do {
            let client = CloudLLMClient(provider: provider, model: "", baseURL: baseURL, apiKey: key)
            return ["ok": true, "models": try await client.listModels()]
        } catch {
            return Self.errorReply(error, action: "list-models")
        }
    }

    private enum Candidate {
        case client(CloudLLMClient)
        /// The error reply to send instead.
        case invalid([String: Any])
    }

    /// The unsaved settings in a `test-engine` request, checked the same
    /// way `set-engine` and the app check them before saving.
    private static func candidate(_ message: [String: Any]) -> Candidate {
        guard let raw = message["provider"] as? String, let provider = CloudProvider(rawValue: raw) else {
            let raw = message["provider"].map { String(describing: $0) } ?? ""
            return .invalid(["ok": false, "error": "bad-request", "detail": "未知的 AI 服務：\(raw)"])
        }
        let saved = MultiSubConfig.load().cloud
        let sameProvider = provider == saved.provider
        let model = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (sameProvider ? saved.model : "")
        let baseURL = (message["baseURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (sameProvider ? saved.baseURL : "")
        if provider.needsBaseURL {
            if baseURL.isEmpty {
                return .invalid(["ok": false, "error": "bad-request", "detail": "請先填寫 API 網址。"])
            }
            if !isValidBaseURL(baseURL) {
                return .invalid(["ok": false, "error": "bad-request",
                                 "detail": "API 網址格式不正確，請以 http:// 或 https:// 開頭。"])
            }
        }
        if model.isEmpty, provider.defaultModel.isEmpty {
            return .invalid(["ok": false, "error": "bad-request", "detail": "請輸入模型 ID。"])
        }
        let key = requestKey(message, provider: provider)
        if provider.keyRequired, key == nil {
            return .invalid(["ok": false, "error": "engine-not-ready", "detail": "請先貼上 API Key。"])
        }
        return .client(CloudLLMClient(provider: provider, model: model, baseURL: baseURL, apiKey: key))
    }

    /// The request's own `apiKey` when it's non-empty, else the saved key.
    /// Never written anywhere.
    private static func requestKey(_ message: [String: Any], provider: CloudProvider) -> String? {
        if let typed = (message["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !typed.isEmpty {
            return typed
        }
        guard let saved = SecretStore.apiKey(for: provider), !saved.isEmpty else { return nil }
        return saved
    }

    /// `hasConsent` lets the popup go straight from a passing test to its
    /// confirmation step; `set-engine` still checks consent on its own.
    private func handleGetEngineOptions() async -> [String: Any] {
        let config = MultiSubConfig.load()
        let providers: [[String: Any]] = CloudProvider.allCases.map { p in
            var d: [String: Any] = [
                "id": p.rawValue,
                "name": p.displayName,
                "defaultModel": p.defaultModel,
                "recommended": p.recommended.map { ["id": $0.id, "label": $0.label] },
                "keyPlaceholder": p.keyPlaceholder,
                "needsBaseURL": p.needsBaseURL,
                "keyRequired": p.keyRequired,
                "hasKey": SecretStore.hasAPIKey(for: p),
                "hasConsent": config.hasCloudConsent(for: p),
            ]
            if let url = p.keyURL { d["keyURL"] = url.absoluteString }
            return d
        }
        return ["ok": true, "providers": providers, "engine": await Translator.engineStatus(config: config).dictionary]
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
    /// can also route to `multisub://vocab?movieId=...`. `NSWorkspace.open`
    /// returning `false` covers "app not installed / scheme not registered
    /// with LaunchServices" — surfaced to popup.js as `open-failed`.
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

    /// content.js's "整理本集單字" button. Stages the transcript in the
    /// shared container; the app picks it up when routed to
    /// `multisub://vocab?movieId=...` (see `PendingTranscriptStore`).
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

    private static func isValidBaseURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return false }
        return true
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
