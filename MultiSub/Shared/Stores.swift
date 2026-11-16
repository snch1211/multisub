//
//  Stores.swift
//  MultiSub
//
//  Small file-backed stores in the shared container: the extension's cache
//  index mirrored for the app, vocabulary files, and transcripts staged for
//  vocabulary extraction. Shared between the host app and the Safari
//  extension.
//

import Foundation

// Cache management lives in the app, but the actual translation/glossary
// cache lives in the Safari extension's own `browser.storage.local` — a
// storage system neither the app nor the appex can read directly (unlike
// `config.json`'s shared container). So this is a one-way-at-a-time bridge
// over files in the shared container, piggybacked on the existing `ping`
// native message:
//   - extension → app: background.js computes a fresh index on every ping
//     request and `handlePing` writes it here via `CacheSync.writeIndex`.
//   - app → extension: the app queues a delete request via
//     `CacheSync.queueDelete`; `handlePing` picks it up on the *next* ping
//     and returns it in the response, then consumes (deletes) the request
//     file so it isn't reapplied. The app's view is therefore only as fresh
//     as the last ping — no faster mechanism exists (the app has no channel
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
    /// Real show/episode title for the app's cache-management tab (it used
    /// to show the bare `movieId`) and for grouping entries by series. All
    /// optional — background.js writes these from a separate,
    /// fire-and-forget private-player-API lookup (`episode-title` port
    /// message) that isn't guaranteed to have arrived yet, unlike
    /// `movieId`/`lineCount`/etc. which come from the translation cache
    /// entry itself.
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

    /// Called by the app. Also returns when the index was last written, so
    /// the app can show the user how stale the snapshot is.
    static func loadIndex() -> (entries: [CacheEntry], syncedAt: Date?) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: indexFile),
              let entries = try? JSONDecoder().decode([CacheEntry].self, from: data)
        else { return ([], nil) }
        let syncedAt = (try? fm.attributesOfItem(atPath: indexFile.path)[.modificationDate]) as? Date
        return (entries, syncedAt)
    }

    /// Called by the app to queue a delete; consumed by the extension's next `ping`.
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

/// One extracted vocabulary entry. `VocabFile` wraps an array of these and
/// is written to the shared container.
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
    /// `Translator.firstCueIndex`). Not currently surfaced in the UI (there
    /// is no player to jump to), kept for future use.
    var cueIndex: Int
}

/// One episode's worth of extracted vocabulary, persisted as
/// `vocab/<movieId>.json` in the shared container. No version field on
/// purpose — this is a one-shot, user-triggered artifact; a future schema
/// change can just fail to decode an old file wholesale (`VocabStore.loadAll`
/// silently skips it) rather than needing migration logic, since re-running
/// the extraction regenerates it.
struct VocabFile: Codable {
    var movieId: String
    /// `seriesTitle` is the show/movie name alone (grouping key for the
    /// app's "生詞本" source list), `episodeTitle` the specific episode's
    /// name (nil for movies). Split out of an earlier single `title` field;
    /// `displayTitle` reconstructs the combined form for anywhere that just
    /// wants one string to show.
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

/// Storage for `VocabFile`s in the shared container's `vocab/` directory.
/// Both read (app startup scan) and write (after `extractVocabulary`, and
/// edits from the "生詞本" tab) go through here.
enum VocabStore {
    static var vocabRoot: URL { MultiSubPaths.sharedRoot.appendingPathComponent("vocab", isDirectory: true) }

    private static func fileURL(movieId: String) -> URL {
        // movieId is a Netflix-assigned numeric id, never user-controlled
        // free text, so no path-escaping concerns beyond staying inside
        // vocabRoot.
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

/// The episode transcript content.js hands off via the `save-transcript`
/// native action, staged here until the app's "生詞本" confirm flow
/// (`multisub://vocab`) picks it up and runs `extractVocabulary`.
struct PendingTranscript: Codable {
    var movieId: String
    /// Same series/episode/season split as `VocabFile`.
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

    /// Called by the appex's `handleSaveTranscript`. A pending transcript for
    /// the same movieId is overwritten outright — the user tapping
    /// "整理本集單字" again always means "use the current text," not "keep
    /// the old one."
    static func save(_ transcript: PendingTranscript) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(transcript) else { return }
        try? data.write(to: fileURL(movieId: transcript.movieId), options: .atomic)
    }

    /// Called by the app when routed to `multisub://vocab?movieId=...`.
    static func load(movieId: String) -> PendingTranscript? {
        guard let data = try? Data(contentsOf: fileURL(movieId: movieId)) else { return nil }
        return try? JSONDecoder().decode(PendingTranscript.self, from: data)
    }

    /// Called by the app once extraction finishes (success or not worth
    /// retrying automatically) so a stale pending file doesn't linger.
    static func delete(movieId: String) {
        try? FileManager.default.removeItem(at: fileURL(movieId: movieId))
    }
}
