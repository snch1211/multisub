//
//  TranslatorCore.swift
//  MultiSub
//
//  Shared between the host app and the Safari extension.
//  Runs the local Gemma model via MLX and translates subtitle lines.
//

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Security
import Tokenizers

enum MultiSubPaths {
    /// S0 (PLAN.md Phase S): the shared App Group uses a Team-ID-prefixed name.
    /// macOS authorizes it purely by code-signature verification (any App ID
    /// signed by the same team gets it automatically), unlike the old
    /// portal-registered `group.*` name, which requires the App Group
    /// capability to be attached to *every* App ID's provisioning profile
    /// individually — on a free Personal Team that attachment silently failed
    /// for the Safari extension's App ID, which is what caused the recurring
    /// "「MultiSub」想要取用其他 App 的資料" TCC prompt.
    ///
    /// R2c: derived at run time from this process's own signed entitlement
    /// rather than hardcoded, so the source carries no literal Team ID. The App
    /// and the extension are signed with the same team, so both derive the
    /// identical string and the shared container path stays stable.
    static let appGroupID: String? = derivedAppGroupID()

    /// Reads `com.apple.security.application-groups` from our own code
    /// signature and returns the Team-ID-prefixed group (i.e. the entry that
    /// isn't the legacy `group.*` name). Nil only if the entitlement is somehow
    /// unreadable, in which case `sharedRoot` falls back to Application Support.
    private static func derivedAppGroupID() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let raw = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil),
              let groups = raw as? [String]
        else { return nil }
        return groups.first { !$0.hasPrefix("group.") }
    }

    /// Pre-S0 group ID. Kept in both `.entitlements` files (not just here) so
    /// `migrateLegacyContainerOnce` below retains sandbox read access to the
    /// old container long enough to move existing users' model cache across.
    /// Not used for anything else.
    static let legacyAppGroupID = "group.com.seanhuang.multisub"

    /// Both targets are sandboxed, so the model and config live in the shared
    /// App Group container, visible to the app and the Safari extension alike.
    static var sharedRoot: URL {
        _ = migrateLegacyContainerOnce
        let fm = FileManager.default
        let base: URL
        if let groupID = appGroupID,
           let group = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            base = group.appendingPathComponent("MultiSub", isDirectory: true)
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MultiSub", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// One-time move from the legacy `group.*` container into the new
    /// Team-ID-prefixed one, so existing users don't lose their ~5GB model
    /// cache. Runs at most once per process via `static let` laziness. Safe
    /// if both the app and the extension process race to migrate at launch:
    /// whichever loses finds the source already gone and `moveItem` throws,
    /// which is silently ignored since the data already landed in the new
    /// container via the winner.
    private static let migrateLegacyContainerOnce: Void = {
        let fm = FileManager.default
        guard let legacyGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: legacyAppGroupID) else { return }
        let legacyBase = legacyGroup.appendingPathComponent("MultiSub", isDirectory: true)
        guard fm.fileExists(atPath: legacyBase.path) else { return }

        guard let newAppGroupID = appGroupID,
              let newGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: newAppGroupID) else { return }
        let newBase = newGroup.appendingPathComponent("MultiSub", isDirectory: true)
        guard !fm.fileExists(atPath: newBase.path) else { return }

        try? fm.createDirectory(at: newGroup, withIntermediateDirectories: true)
        try? fm.moveItem(at: legacyBase, to: newBase)
    }()

    static var modelsRoot: URL { sharedRoot.appendingPathComponent("models", isDirectory: true) }
    static var configFile: URL { sharedRoot.appendingPathComponent("config.json") }
}

/// D1: user-adjustable overlay subtitle style, edited in the host App and
/// consumed by `overlay.css`/`content.js` via CSS variables (see
/// CLAUDE.md's message-protocol contract, `ping`). Defaults match the values
/// `overlay.css` had hardcoded before D1, so upgrading doesn't change the
/// look for existing users until they open the style panel.
struct SubtitleStyle: Codable, Equatable {
    var textColor: String = SubtitleStyle.defaultTextColor
    var backgroundColor: String = SubtitleStyle.defaultBackgroundColor
    var backgroundOpacity: Double = SubtitleStyle.defaultBackgroundOpacity
    var outlineEnabled: Bool = SubtitleStyle.defaultOutlineEnabled
    var outlineColor: String = SubtitleStyle.defaultOutlineColor
    /// Final CSS `font-family` value, stored verbatim — the App's font
    /// picker maps its few named options directly to complete CSS strings,
    /// so content.js never has to translate an id back into a value.
    var fontFamily: String = SubtitleStyle.defaultFontFamily
    var lineHeight: Double = SubtitleStyle.defaultLineHeight
    var boldEnabled: Bool = SubtitleStyle.defaultBoldEnabled

    static let defaultTextColor = "#ffffff"
    static let defaultBackgroundColor = "#000000"
    static let defaultBackgroundOpacity = 0.5
    static let defaultOutlineEnabled = true
    static let defaultOutlineColor = "#000000"
    static let defaultFontFamily = "\"Netflix Sans\", \"Helvetica Neue\", \"PingFang TC\", \"Noto Sans TC\", sans-serif"
    static let defaultLineHeight = 1.35
    static let defaultBoldEnabled = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case textColor, backgroundColor, backgroundOpacity, outlineEnabled, outlineColor, fontFamily, lineHeight, boldEnabled
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textColor = try container.decodeIfPresent(String.self, forKey: .textColor) ?? Self.defaultTextColor
        backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor) ?? Self.defaultBackgroundColor
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? Self.defaultBackgroundOpacity
        outlineEnabled = try container.decodeIfPresent(Bool.self, forKey: .outlineEnabled) ?? Self.defaultOutlineEnabled
        outlineColor = try container.decodeIfPresent(String.self, forKey: .outlineColor) ?? Self.defaultOutlineColor
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? Self.defaultFontFamily
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? Self.defaultLineHeight
        boldEnabled = try container.decodeIfPresent(Bool.self, forKey: .boldEnabled) ?? Self.defaultBoldEnabled
    }
}

struct MultiSubConfig: Codable {
    var modelID: String = MultiSubConfig.defaultModelID
    /// Minutes of translation inactivity before `Translator` auto-unloads the
    /// model to free memory (M2). `<= 0` disables auto-unload.
    var idleUnloadMinutes: Int = MultiSubConfig.defaultIdleUnloadMinutes
    /// D1: overlay subtitle style, single source of truth (App writes,
    /// extension reads via `ping`'s `styles` field).
    var styles: SubtitleStyle = SubtitleStyle()

    static let defaultModelID = "mlx-community/gemma-4-e4b-it-4bit"
    static let defaultIdleUnloadMinutes = 15

    init() {}

    // Custom decode so existing config.json files written before
    // `idleUnloadMinutes`/`styles` existed still decode instead of failing
    // wholesale and silently reverting modelID to the default too.
    enum CodingKeys: String, CodingKey { case modelID, idleUnloadMinutes, styles }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? Self.defaultModelID
        idleUnloadMinutes = try container.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes)
            ?? Self.defaultIdleUnloadMinutes
        styles = try container.decodeIfPresent(SubtitleStyle.self, forKey: .styles) ?? SubtitleStyle()
    }

    static func load() -> MultiSubConfig {
        guard let data = try? Data(contentsOf: MultiSubPaths.configFile),
              let config = try? JSONDecoder().decode(MultiSubConfig.self, from: data)
        else { return MultiSubConfig() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: MultiSubPaths.configFile, options: .atomic)
        }
    }
}

// D4: cache management lives in the App, but the actual translation/glossary
// cache lives in the Safari extension's own `browser.storage.local` — a
// storage system neither the App nor the appex can read directly (unlike
// `config.json`'s shared container). So this is a one-way-at-a-time bridge
// over files in the shared container, piggybacked on the existing `ping`
// native message (see CLAUDE.md's message-protocol contract):
//   - extension → App: background.js computes a fresh index on every ping
//     request and `handlePing` writes it here via `CacheSync.writeIndex`.
//   - App → extension: the App queues a delete request via
//     `CacheSync.queueDelete`; `handlePing` picks it up on the *next* ping
//     and returns it in the response, then consumes (deletes) the request
//     file so it isn't reapplied. The App's view is therefore only as fresh
//     as the last ping — no faster mechanism exists (the App has no channel
//     to wake the extension on demand) — and a queued delete only actually
//     takes effect once Safari happens to ping again (typically within
//     60s while a Netflix tab is open, or 2s while the popup is open; not
//     at all if Safari isn't running). This tradeoff was discussed with and
//     accepted by the user (2026-07-05) in exchange for a native table UI.
struct CacheGroupKey: Codable, Hashable {
    var movieId: String
    var targetLang: String
    var sourceLang: String
}

struct CacheEntry: Codable {
    var movieId: String
    var targetLang: String
    var sourceLang: String
    var lineCount: Int
    var bytes: Int
    /// Milliseconds since epoch (matches JS `Date.now()`, the source of this value).
    var savedAt: Double
    /// 2026-07-06: real show/episode title for the App's cache-management
    /// tab (previously showed the bare `movieId`) and for grouping entries
    /// by series. All optional/nilable — background.js writes these from a
    /// separate, fire-and-forget private-player-API lookup (`episode-title`
    /// port message) that isn't guaranteed to have arrived yet, unlike
    /// `movieId`/`lineCount`/etc. which come from the translation cache
    /// entry itself. See CLAUDE.md's `ping` protocol entry.
    var seriesTitle: String?
    var episodeTitle: String?
    var seasonNumber: Int?
}

struct CacheDeleteRequest: Codable {
    var clearAll: Bool
    var groups: [CacheGroupKey]
}

enum CacheSync {
    static var indexFile: URL { MultiSubPaths.sharedRoot.appendingPathComponent("cache-index.json") }
    static var deleteRequestFile: URL { MultiSubPaths.sharedRoot.appendingPathComponent("cache-delete-request.json") }

    static func writeIndex(_ entries: [CacheEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexFile, options: .atomic)
    }

    /// Called by the App. Also returns when the index was last written, so
    /// the App can show the user how stale the snapshot is.
    static func loadIndex() -> (entries: [CacheEntry], syncedAt: Date?) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: indexFile),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return ([], nil) }
        let syncedAt = (try? fm.attributesOfItem(atPath: indexFile.path)[.modificationDate]) as? Date
        return (entries, syncedAt)
    }

    /// Called by the App to queue a delete; consumed by the extension's next `ping`.
    static func queueDelete(_ request: CacheDeleteRequest) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        try? data.write(to: deleteRequestFile, options: .atomic)
    }

    /// Called by `handlePing`: returns and clears any pending delete request.
    static func consumePendingDelete() -> CacheDeleteRequest? {
        guard let data = try? Data(contentsOf: deleteRequestFile),
              let request = try? JSONDecoder().decode(CacheDeleteRequest.self, from: data)
        else { return nil }
        try? FileManager.default.removeItem(at: deleteRequestFile)
        return request
    }
}

enum LanguageNames {
    /// Map extension language codes to names the model understands well.
    static func name(for code: String) -> String {
        switch code {
        case "zh-TW": return "Traditional Chinese (Taiwan)"
        case "zh-CN": return "Simplified Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "pt": return "Portuguese"
        case "vi": return "Vietnamese"
        case "th": return "Thai"
        case "id": return "Indonesian"
        default: return code
        }
    }
}

// V2 (PLAN.md Phase V): one extracted vocabulary entry. Schema fixed by
// docs/vocab-design.md §6; V3 wraps an array of these into a `VocabFile` and
// writes it to the shared container.
struct VocabWord: Codable, Equatable {
    var word: String
    var lemma: String
    var pos: String
    var cefr: String
    var definitionEn: String
    var translation: String
    var example: String
    var exampleTranslation: String
    /// Index into the `lines` array passed to `extractVocabulary` where this
    /// lemma first appears, or -1 if no line matched (see
    /// `Translator.firstCueIndex`). Not currently surfaced in the UI (V3 has
    /// no player to jump to), kept for future use.
    var cueIndex: Int
}

/// V3 (PLAN.md Phase V): one episode's worth of extracted vocabulary,
/// persisted as `vocab/<movieId>.json` in the shared container. No version
/// field on purpose (see vocab-design.md §6) — this is a one-shot, user-
/// triggered artifact; a future schema change can just fail to decode an old
/// file wholesale (`VocabStore.loadAll` silently skips it) rather than
/// needing migration logic, since re-running the extraction regenerates it.
struct VocabFile: Codable {
    var movieId: String
    /// 2026-07-06: split out of the single `title` field the schema
    /// originally had (vocab-design.md's V1 draft) — `seriesTitle` is the
    /// show/movie name alone (grouping key for the App's "生詞本" source
    /// list), `episodeTitle` the specific episode's name (nil for movies).
    /// `displayTitle` reconstructs the old combined form for anywhere that
    /// just wants one string to show.
    var seriesTitle: String
    var episodeTitle: String?
    var seasonNumber: Int?
    var sourceLang: String
    var targetLang: String
    var createdAt: Date
    var words: [VocabWord]

    var displayTitle: String {
        guard let episodeTitle, !episodeTitle.isEmpty else { return seriesTitle }
        return "\(seriesTitle) - \(episodeTitle)"
    }
}

/// Storage for `VocabFile`s in the shared container's `vocab/` directory
/// (vocab-design.md §6). Both read (App startup scan) and write (after V2's
/// `extractVocabulary`, and edits from the "生詞本" tab) go through here.
enum VocabStore {
    static var vocabRoot: URL { MultiSubPaths.sharedRoot.appendingPathComponent("vocab", isDirectory: true) }

    private static func fileURL(movieId: String) -> URL {
        // movieId is a Netflix-assigned numeric id (see CLAUDE.md's message
        // protocol), never user-controlled free text, so no path-escaping
        // concerns beyond staying inside vocabRoot.
        vocabRoot.appendingPathComponent("\(movieId).json")
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Scans `vocab/` for every episode's file. Files that fail to decode
    /// (corrupt, or a future incompatible schema) are silently skipped rather
    /// than crashing the whole list — see the "no version field" rationale above.
    static func loadAll() -> [VocabFile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: vocabRoot, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(VocabFile.self, from: data)
            }
    }

    static func save(_ file: VocabFile) {
        let fm = FileManager.default
        try? fm.createDirectory(at: vocabRoot, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: fileURL(movieId: file.movieId), options: .atomic)
    }

    static func delete(movieId: String) {
        try? FileManager.default.removeItem(at: fileURL(movieId: movieId))
    }
}

/// V4 (PLAN.md Phase V): the episode transcript content.js hands off via the
/// `save-transcript` native action (see CLAUDE.md's protocol table),
/// staged here until the App's "生詞本" confirm flow (`multisub://vocab`)
/// picks it up and runs V2's `extractVocabulary`.
struct PendingTranscript: Codable {
    var movieId: String
    /// See `VocabFile`'s matching fields — same 2026-07-06 split of a single
    /// `title` into series/episode/season.
    var seriesTitle: String
    var episodeTitle: String?
    var seasonNumber: Int?
    var sourceLang: String
    var targetLang: String
    var lines: [String]

    var displayTitle: String {
        guard let episodeTitle, !episodeTitle.isEmpty else { return seriesTitle }
        return "\(seriesTitle) - \(episodeTitle)"
    }
}

enum PendingTranscriptStore {
    static var root: URL { MultiSubPaths.sharedRoot.appendingPathComponent("vocab-pending", isDirectory: true) }

    private static func fileURL(movieId: String) -> URL { root.appendingPathComponent("\(movieId).json") }

    /// Called by appex's `handleSaveTranscript`. A pending transcript for the
    /// same movieId is overwritten outright — the user tapping "整理本集單字"
    /// again always means "use the current text," not "keep the old one"
    /// (vocab-design.md §3).
    static func save(_ transcript: PendingTranscript) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(transcript) else { return }
        try? data.write(to: fileURL(movieId: transcript.movieId), options: .atomic)
    }

    /// Called by the App when routed to `multisub://vocab?movieId=...`.
    static func load(movieId: String) -> PendingTranscript? {
        guard let data = try? Data(contentsOf: fileURL(movieId: movieId)) else { return nil }
        return try? JSONDecoder().decode(PendingTranscript.self, from: data)
    }

    /// Called by the App once extraction finishes (success or not worth
    /// retrying automatically) so a stale pending file doesn't linger.
    static func delete(movieId: String) {
        try? FileManager.default.removeItem(at: fileURL(movieId: movieId))
    }
}

enum TranslatorError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded: return "model-not-ready"
        }
    }
}

actor Translator {
    static let shared = Translator()

    private var container: ModelContainer?
    private var loadedModelID: String?
    private var lastUsedAt: Date?
    // Counts in-flight `translate`/`extractGlossary` calls (see their `defer`
    // blocks). Lets `unload()` callers that aren't the M1 toggle-off path
    // (which is safe by design — background.js stops issuing further batches
    // once it flips settings.enabled off) check whether unloading right now
    // would pull the container out from under an active episode translation.
    private var activeRequests = 0

    var isLoaded: Bool { container != nil }
    /// C3: read-only App-side accessor so `GeneralSettingsView` can tell
    /// which specific model a deletion candidate would be pulling out from
    /// under, instead of only knowing *that* something is loaded.
    var currentlyLoadedModelID: String? { loadedModelID }
    var isBusy: Bool { activeRequests > 0 }

    // MARK: - Model presence / download

    /// Mirrors the Hugging Face cache layout used by `HubCache`:
    /// `<modelsRoot>/models--<org>--<name>/snapshots/<commit>/…`
    nonisolated static func isModelDownloaded(_ modelID: String) -> Bool {
        let repoDir = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let snapshots = MultiSubPaths.modelsRoot
            .appendingPathComponent(repoDir, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else {
            return false
        }
        for snapshot in dirs {
            let files = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
            if files.contains("config.json"),
               files.contains(where: { $0.hasSuffix(".safetensors") }) {
                return true
            }
        }
        return false
    }

    private nonisolated func hubClient() -> HubClient {
        HubClient(cache: HubCache(cacheDirectory: MultiSubPaths.modelsRoot))
    }

    /// Downloads (if needed) and loads the model. Progress is reported in [0, 1].
    func loadModel(modelID: String, allowDownload: Bool,
                   progress: (@Sendable (Double) -> Void)? = nil) async throws {
        markUsed()
        if loadedModelID == modelID, container != nil { return }
        if !allowDownload && !Self.isModelDownloaded(modelID) {
            throw TranslatorError.modelNotDownloaded
        }
        // Release the previous model before loading a new one.
        container = nil
        loadedModelID = nil
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hubClient()),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: modelID)
        ) { prog in
            progress?(prog.fractionCompleted)
        }
        container = loaded
        loadedModelID = modelID
    }

    // MARK: - Memory management (M1/M2)

    /// Releases the loaded model container and clears MLX's cached buffers,
    /// freeing the multi-GB footprint. The `ChatSession` used per request
    /// (see `respond`) holds no persistent reference, so dropping
    /// `container` is enough to let ARC deallocate the weights; `clearCache`
    /// additionally returns MLX's recycled buffer pool to the system rather
    /// than leaving it around for reuse. Safe to call when nothing is loaded
    /// — the next `translate`/`extractGlossary` call reloads lazily.
    func unload() {
        container = nil
        loadedModelID = nil
        Memory.clearCache()
    }

    /// Records model activity. Called from `loadModel`, so every
    /// `translate`/`extractGlossary` call resets the idle clock — including
    /// cache-hit calls that skip the actual (re)load.
    private func markUsed() {
        lastUsedAt = Date()
    }

    /// Unloads the model if it's been idle past the configured threshold.
    /// `idleUnloadMinutes` is a global policy (M5) — both the appex and the
    /// host App load this same model singleton, and both are expected to
    /// call this.
    ///
    /// The two callers drive it very differently, though. The appex is an
    /// `NSExtensionRequestHandling` host, and empirically the OS suspends
    /// the whole process between native-message requests (confirmed via
    /// `sample`: every thread parked, RSS never dropped after 10+ idle
    /// minutes with a 1-minute threshold) — an internal `Task.sleep`-based
    /// timer was tried there (M2) and doesn't work. So the appex only runs
    /// this opportunistically whenever *something* wakes the process:
    /// `handlePing` calls it on every `ping`, and content.js pings
    /// periodically (independent of the popup) specifically to drive this.
    /// This constraint is specific to the appex host — it does NOT apply to
    /// the App target, which is a normal GUI process the OS doesn't suspend
    /// between requests, so the App drives this with a real 60s timer
    /// (`AppDelegate`).
    func checkIdleUnload() {
        guard container != nil, let lastUsedAt else { return }
        let minutes = MultiSubConfig.load().idleUnloadMinutes
        guard minutes > 0 else { return }
        if Date().timeIntervalSince(lastUsedAt) >= TimeInterval(minutes * 60) {
            unload()
        }
    }

    // MARK: - Translation

    /// Translates subtitle lines into the target language. `targetLang` is a
    /// BCP-47-ish code from the extension (e.g. "zh-TW").
    ///
    /// `reference` (T3 stage 1), when provided, is the official
    /// target-language subtitle aligned to each line (same count as `lines`,
    /// `nil` entries where there's no official text for that line). It's
    /// used only to steer name/proper-noun translation toward Netflix's own
    /// wording — never as a source to copy verbatim. A mismatched count is
    /// treated as no reference at all rather than risking misaligned
    /// guidance.
    ///
    /// `glossary` (T3 stage 2), when non-empty, is an episode-wide
    /// term → official-translation map (see `extractGlossary`). It
    /// supersedes `reference` when both are given: it's cheaper per batch
    /// (one block vs. per-line text) and, unlike `reference`, still helps
    /// lines with no directly-aligned official cue (e.g. CC-only text).
    func translate(lines: [String], targetLang: String, reference: [String?]? = nil,
                   glossary: [String: String]? = nil) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let modelID = MultiSubConfig.load().modelID
        try await loadModel(modelID: modelID, allowDownload: false)
        guard let container else { throw TranslatorError.modelNotDownloaded }

        let language = LanguageNames.name(for: targetLang)
        let system = systemPrompt(language: language)
        let glossaryBlock = Self.glossaryBlock(glossary, language: language)
        // Normalize to a flat, always-matching-length array so downstream
        // prompt builders never deal with a missing/mismatched reference.
        // Suppressed entirely once a glossary block is in play.
        let ref: [String?] = (glossaryBlock == nil && reference?.count == lines.count)
            ? reference! : Array(repeating: nil, count: lines.count)

        if lines.count == 1 {
            let out = try await respond(container: container, system: system,
                                        prompt: singlePrompt(lines[0], language: language, reference: ref[0],
                                                             glossaryBlock: glossaryBlock))
            return [cleanLine(out)]
        }

        let batchOut = try await respond(container: container, system: system,
                                         prompt: batchPrompt(lines, language: language, reference: ref,
                                                             glossaryBlock: glossaryBlock))
        if let parsed = parseNumbered(batchOut, expected: lines.count) {
            return parsed
        }
        // Fallback: translate line by line if the model didn't keep the format.
        var results: [String] = []
        results.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            let out = try await respond(container: container, system: system,
                                        prompt: singlePrompt(line, language: language, reference: ref[i],
                                                             glossaryBlock: glossaryBlock))
            results.append(cleanLine(out))
        }
        return results
    }

    // MARK: - Glossary extraction (T3 stage 2)

    /// Compares original/official-translation subtitle pairs and extracts a
    /// proper-noun glossary (character names, places, etc.) with the exact
    /// wording used in the official translation. Meant to be called on
    /// chunks of an episode's aligned pairs (see PLAN.md T3); results are
    /// merged and cached by the caller.
    func extractGlossary(pairs: [(source: String, reference: String)], targetLang: String) async throws -> [String: String] {
        guard !pairs.isEmpty else { return [:] }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let modelID = MultiSubConfig.load().modelID
        try await loadModel(modelID: modelID, allowDownload: false)
        guard let container else { throw TranslatorError.modelNotDownloaded }

        let language = LanguageNames.name(for: targetLang)
        let out = try await respond(container: container, system: glossarySystemPrompt(language: language),
                                    prompt: glossaryExtractionPrompt(pairs, language: language))
        return Self.parseGlossaryJSON(out)
    }

    // MARK: - Vocabulary extraction (V2, PLAN.md Phase V / docs/vocab-design.md §5)

    /// Extracts notable English vocabulary from an episode's source-language
    /// subtitle lines, for the "生詞本" feature. Runs entirely in the host
    /// App (see vocab-design.md §1) — the caller is responsible for verifying
    /// `sourceLang` is English before calling this (vocab-design.md §4); this
    /// function assumes it and does not re-check, since by the time lines
    /// reach here they're already just plain subtitle text with no language
    /// tag attached.
    ///
    /// `progress` reports segment completion in [0, 1] (there is no
    /// finer-grained progress within a single model call).
    func extractVocabulary(lines: [String], targetLang: String,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [VocabWord] {
        guard !lines.isEmpty else { return [] }
        // M5: this can run for many segments over a long stretch of wall
        // time (each segment is its own model call) — `isBusy` must stay
        // true for the whole extraction, not just `loadModel`, or the App's
        // 60s idle-unload timer could yank the model out mid-extraction.
        activeRequests += 1
        defer { activeRequests -= 1 }
        let modelID = MultiSubConfig.load().modelID
        try await loadModel(modelID: modelID, allowDownload: false)
        guard let container else { throw TranslatorError.modelNotDownloaded }

        let language = LanguageNames.name(for: targetLang)
        let segments = stride(from: 0, to: lines.count, by: Self.vocabSegmentSize).map {
            Array(lines[$0..<min($0 + Self.vocabSegmentSize, lines.count)])
        }

        // Dedup by lemma, first occurrence wins (vocab-design.md §5.3,
        // 2026-07-04 rewrite). The original design copied T3 glossary's
        // cross-segment vote-tallying scheme (require >=2 segments to agree
        // on the exact same output before trusting a lemma), reasoning that
        // it was the same "model cross-wires fields in a multi-item
        // response" risk as glossary extraction. Real-episode testing
        // showed that assumption was wrong: unlike glossary's target value
        // (an official translation string, which the model tends to
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

        for (index, segment) in segments.enumerated() {
            // M5: refresh the idle clock on every segment, not just once at
            // the top of the function — a long episode's extraction can
            // outlast the idle threshold on its own otherwise.
            markUsed()
            let entries = (try? await extractVocabSegment(container: container, lines: segment, language: language)) ?? []
            for entry in entries {
                let lemma = entry.lemma.lowercased()
                guard !lemma.isEmpty, !Self.isFilteredWord(lemma) else { continue }
                if seen[lemma] == nil { seen[lemma] = entry }
            }
            progress?(Double(index + 1) / Double(segments.count))
        }

        return seen.values.map { entry in
            let corrected = Self.cefrWordlist[entry.lemma.lowercased()] ?? entry.cefr
            return VocabWord(word: entry.word, lemma: entry.lemma, pos: entry.pos, cefr: corrected,
                              definitionEn: entry.definitionEn, translation: entry.translation,
                              example: entry.example, exampleTranslation: entry.exampleTranslation,
                              cueIndex: Self.firstCueIndex(for: entry.lemma, in: lines))
        }
    }

    /// ~40 lines/segment, matching T3 glossary's `GLOSSARY_SEGMENT_SIZE`
    /// (extension/background.js) — same "bounded prompt per call" tradeoff.
    private static let vocabSegmentSize = 40

    /// Runs one segment through the model, retrying once on unparseable
    /// output (mirrors the retry conventions used elsewhere in this file).
    /// Returns `[]` — not an error — if both attempts fail to parse; a bad
    /// segment shouldn't abort the whole episode (vocab-design.md §5.1).
    private func extractVocabSegment(container: ModelContainer, lines: [String],
                                     language: String) async throws -> [RawVocabEntry] {
        let system = vocabSystemPrompt(language: language)
        let prompt = vocabExtractionPrompt(lines)
        let out = try await respond(container: container, system: system, prompt: prompt)
        if let parsed = Self.parseVocabJSON(out) { return parsed }
        let retryPrompt = prompt + "\n\n(Your previous output was not valid JSON. Output ONLY the JSON array described above, nothing else.)"
        let retryOut = try await respond(container: container, system: system, prompt: retryPrompt)
        return Self.parseVocabJSON(retryOut) ?? []
    }

    private func vocabSystemPrompt(language: String) -> String {
        """
        You are a language-learning assistant. Given consecutive subtitle lines from a TV show/movie in \
        English, extract notable vocabulary worth studying for a learner targeting CEFR levels A1-C2. For \
        each word/phrase worth noting, output its dictionary form (lemma), part of speech, a rough CEFR \
        level estimate, an English-English definition, its \(language) translation, an original example \
        sentence, and that example's \(language) translation.

        The example sentence is the part learners actually study from, so it needs to stand on its own:
        - Write your OWN sentence. Do NOT copy or lightly edit the subtitle line - subtitle lines are \
          often clipped mid-sentence, informal reactions, or closed-caption stage directions (e.g. \
          "[door creaks]", "Yeah.", "gonna be late, come on") and make poor teaching examples verbatim.
        - It must be a complete, grammatical sentence with a clear subject and verb - never a fragment, \
          a single word, or a bare interjection.
        - It doesn't need to be long, but it needs to carry enough context to show how the word is \
          actually used without the reader needing to see the original scene - a bare-minimum clause \
          like "He was reluctant." fails this even though it's grammatical.
        - You may borrow the topic/tone of the surrounding subtitle lines as inspiration, but the wording \
          must be yours.

        Skip: function words (articles, pronouns, prepositions, basic conjunctions), A1-level everyday \
        vocabulary, and proper nouns (names, places - those belong in a glossary, not a vocabulary list).

        Output ONLY a JSON array like:
        [{"word":"reluctant","lemma":"reluctant","pos":"adjective","cefr":"B2",
          "definitionEn":"unwilling and hesitant","translation":"...",
          "example":"Despite the pressure from his colleagues, he was reluctant to sign the contract.",
          "exampleTranslation":"..."}]
        No markdown fence, no other text. If nothing in this segment qualifies, output [].
        """
    }

    private func vocabExtractionPrompt(_ lines: [String]) -> String {
        var prompt = "Subtitle lines from this segment (for context only - extract vocabulary appearing in them):\n"
        for (i, line) in lines.enumerated() {
            let flat = line.replacingOccurrences(of: "\n", with: " / ")
            prompt += "\n\(i + 1). \(flat)"
        }
        return prompt
    }

    /// One model-extracted vocabulary candidate before cross-segment
    /// deduplication and CEFR correction. Distinct from `VocabWord`: no
    /// `cueIndex` yet (computed after merge, against the full episode) and
    /// `cefr` is the model's own (unreliable, see vocab-design.md §5.5) estimate.
    private struct RawVocabEntry: Equatable {
        var word: String
        var lemma: String
        var pos: String
        var cefr: String
        var definitionEn: String
        var translation: String
        var example: String
        var exampleTranslation: String
    }

    private static func parseVocabJSON(_ output: String) -> [RawVocabEntry]? {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap JSON in a markdown fence despite instructions.
        if text.hasPrefix("```") {
            text.removeFirst(3)
            if text.hasPrefix("json") { text.removeFirst(4) }
            if let closingRange = text.range(of: "```") {
                text = String(text[..<closingRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var result: [RawVocabEntry] = []
        for entry in arr {
            guard let word = (entry["word"] as? String)?.trimmingCharacters(in: .whitespaces), !word.isEmpty,
                  let lemma = (entry["lemma"] as? String)?.trimmingCharacters(in: .whitespaces), !lemma.isEmpty,
                  let pos = (entry["pos"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let cefr = (entry["cefr"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let definitionEn = (entry["definitionEn"] as? String)?.trimmingCharacters(in: .whitespaces), !definitionEn.isEmpty,
                  let translation = (entry["translation"] as? String)?.trimmingCharacters(in: .whitespaces), !translation.isEmpty,
                  let example = (entry["example"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let exampleTranslation = (entry["exampleTranslation"] as? String)?.trimmingCharacters(in: .whitespaces)
            else { continue }
            result.append(RawVocabEntry(word: word, lemma: lemma, pos: pos, cefr: cefr.uppercased(),
                                        definitionEn: definitionEn, translation: translation,
                                        example: example, exampleTranslation: exampleTranslation))
        }
        return result
    }

    /// Case-insensitive whole-word(-prefix) search for `lemma` in `lines`,
    /// matching inflected forms too (e.g. lemma "reluctant" matches
    /// "reluctantly") — see vocab-design.md §5.6. Returns -1 if no line
    /// matches (e.g. the model paraphrased a lemma that isn't literally in
    /// the subtitle text).
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

    // MARK: - Static wordlists (vocab-design.md §5.4/§5.5)

    /// Function-word / A1-level safety-net filter, applied to surviving
    /// lemmas *after* cross-segment merging. vocab-design.md §5.4 frames this
    /// as a pre-filter of the model's input to save tokens; in practice
    /// stripping words out of subtitle sentences before sending them would
    /// mangle the sentences the model needs for context/examples, so this
    /// filters the model's *output* instead. Token savings still come from
    /// the system prompt's explicit "skip these" instruction (which this
    /// list doesn't duplicate to the model); this is a guardrail for when
    /// the model doesn't fully comply.
    private static func isFilteredWord(_ lemma: String) -> Bool {
        stopwords.contains(lemma)
    }

    private static let stopwords: Set<String> = loadWordSet(resource: "stopwords-en")

    /// Real, properly-licensed A1-C2 data (2026-07-04, replacing the initial
    /// self-authored placeholder after user review — vocab-design.md §5.5 /
    /// §9 open item #4 resolved): A1-B2 from "The CEFR-J Wordlist" v1.5
    /// (Yukio Tono, Tokyo University of Foreign Studies — usable for
    /// research and commercial purposes with attribution), C1-C2 from the
    /// "Octanove Vocabulary Profile for C1/C2" v1.0 (Octanove Labs — CC
    /// BY-SA 4.0). Both from
    /// https://github.com/openlanguageprofiles/olp-en-cefrj. Full citation
    /// and processing notes (slash-variant expansion, lower-level-wins on
    /// POS-sense conflicts) are in the resource file's own header comment —
    /// see `cefr-wordlist-en.txt`. Format: `word<TAB>LEVEL`, one per line;
    /// lines without exactly one tab (including the `#`-commented header)
    /// are silently skipped by the `parts.count == 2` guard below.
    private static let cefrWordlist: [String: String] = {
        guard let url = Bundle.main.url(forResource: "cefr-wordlist-en", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces).uppercased()
        }
        return result
    }()

    private static func loadWordSet(resource: String) -> Set<String> {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func respond(container: ModelContainer, system: String, prompt: String) async throws -> String {
        var parameters = GenerateParameters()
        parameters.temperature = 0.0
        parameters.maxTokens = 2048
        // A fresh session per request: subtitle batches are independent and we
        // don't want history to accumulate KV cache across an episode.
        let session = ChatSession(container, instructions: system, generateParameters: parameters)
        return try await session.respond(to: prompt)
    }

    private func systemPrompt(language: String) -> String {
        """
        You are a professional subtitle translator. Translate movie/TV subtitles into \(language). \
        Keep the tone natural and conversational, matching how native speakers talk. \
        Render names the way they are commonly rendered in \(language). \
        Some lines are prefixed with a speaker tag in brackets, e.g. "[Name]" or "-[Name]" — a captioning \
        convention (from closed-caption/SDH tracks) marking who's speaking, not part of the sentence grammar. \
        Preserve this convention in your output: keep the same bracket/dash format around the name (translated \
        into \(language) if you know its established form), then translate only the dialogue naturally after \
        it. Do NOT restructure it into a narrated attribution with invented punctuation — the tag is a label, \
        not a sentence. For example, translating into Chinese: "[Dustin] You really think she's psycho?" should \
        become "[達斯汀] 你真的覺得她有病嗎？", never "塵氏：「你真的認為她是瘋子？」". \
        Output ONLY the translation with no explanations, notes, or quotation marks beyond what's in the source.
        """
    }

    private func singlePrompt(_ line: String, language: String, reference: String? = nil,
                               glossaryBlock: String? = nil) -> String {
        var prompt = ""
        if let glossaryBlock { prompt += glossaryBlock + "\n\n" }
        prompt += "Translate this subtitle line into \(language):\n\n\(line)"
        if let reference, !reference.isEmpty {
            prompt += "\n\n[Official] The official \(language) subtitle for this moment — " +
                "match its names/proper nouns only, don't copy its phrasing: \(reference)"
        }
        return prompt
    }

    private func batchPrompt(_ lines: [String], language: String, reference: [String?] = [],
                              glossaryBlock: String? = nil) -> String {
        let hasReference = reference.contains { ($0?.isEmpty ?? true) == false }
        var prompt = ""
        if let glossaryBlock { prompt += glossaryBlock + "\n\n" }
        prompt += """
        Translate the following \(lines.count) subtitle lines into \(language). \
        The lines are consecutive dialogue from the same scene, so use context across lines. \
        Reply with exactly \(lines.count) numbered lines in the same order, one translation per line, \
        and nothing else. If a line is a sound effect or music mark, translate it appropriately.
        """
        if hasReference {
            prompt += " Some lines are followed by an [Official] line: the official \(language) subtitle " +
                "for that moment. Use it only to match its established names and proper-noun translations — " +
                "translate everything else naturally and idiomatically in your own words, don't copy its phrasing."
        }
        prompt += "\n"
        for (i, line) in lines.enumerated() {
            // Subtitle lines can contain internal newlines; flatten for numbering.
            let flat = line.replacingOccurrences(of: "\n", with: " / ")
            prompt += "\n\(i + 1). \(flat)"
            if i < reference.count, let ref = reference[i], !ref.isEmpty {
                prompt += "\n   [Official] \(ref.replacingOccurrences(of: "\n", with: " / "))"
            }
        }
        return prompt
    }

    /// Renders a glossary map into the block prepended to translation
    /// prompts. `nil` when there's nothing worth injecting.
    private static func glossaryBlock(_ glossary: [String: String]?, language: String) -> String? {
        guard let glossary, !glossary.isEmpty else { return nil }
        let lines = glossary.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
        return "Established \(language) translations for names/terms in this episode — " +
            "use these exactly when they appear, don't invent alternatives:\n" + lines.joined(separator: "\n")
    }

    private func glossarySystemPrompt(language: String) -> String {
        """
        You compare original subtitle dialogue with its official \(language) translation and extract a \
        glossary of proper nouns — character names, place names, organizations, or other recurring terms — \
        together with the exact wording used for them in the official translation. \
        Output ONLY a JSON array like [{"term":"Mike","translation":"麥克"}], no other text, no markdown fence. \
        Skip common words and anything that isn't a proper noun or recurring term. If nothing qualifies, output [].
        """
    }

    private func glossaryExtractionPrompt(_ pairs: [(source: String, reference: String)], language: String) -> String {
        var prompt = "Original subtitle lines paired with their official \(language) translation, from the same episode:\n"
        for (i, pair) in pairs.enumerated() {
            let src = pair.source.replacingOccurrences(of: "\n", with: " / ")
            let ref = pair.reference.replacingOccurrences(of: "\n", with: " / ")
            prompt += "\n\(i + 1). \(src)\n   official: \(ref)"
        }
        return prompt
    }

    private static func parseGlossaryJSON(_ output: String) -> [String: String] {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap JSON in a markdown fence despite instructions.
        if text.hasPrefix("```") {
            text.removeFirst(3)
            if text.hasPrefix("json") { text.removeFirst(4) }
            if let closingRange = text.range(of: "```") {
                text = String(text[..<closingRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        var result: [String: String] = [:]
        for entry in arr {
            guard let term = (entry["term"] as? String)?.trimmingCharacters(in: .whitespaces), !term.isEmpty,
                  let translation = (entry["translation"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !translation.isEmpty
            else { continue }
            result[term] = translation
        }
        return result
    }

    // MARK: - Output parsing

    private func cleanLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseNumbered(_ output: String, expected: Int) -> [String]? {
        var results = [String?](repeating: nil, count: expected)
        let pattern = try! NSRegularExpression(pattern: #"^\s*(\d+)[.)、]\s*(.*)$"#)
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let m = pattern.firstMatch(in: line, range: range),
                  let numRange = Range(m.range(at: 1), in: line),
                  let textRange = Range(m.range(at: 2), in: line),
                  let num = Int(line[numRange])
            else { continue }
            let idx = num - 1
            guard idx >= 0 && idx < expected else { continue }
            let text = line[textRange]
                .replacingOccurrences(of: " / ", with: "\n")
                .replacingOccurrences(of: #"\s*／\s*"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if results[idx] == nil { results[idx] = text }
        }
        let filled = results.compactMap { $0 }
        guard filled.count == expected else { return nil }
        return filled
    }
}
