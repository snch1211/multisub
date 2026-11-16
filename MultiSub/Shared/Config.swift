//
//  Config.swift
//  MultiSub
//
//  config.json in the shared container: the one settings file both the host
//  app and the Safari extension read and write.
//

import Foundation

/// User-adjustable overlay subtitle style, edited in the host app and
/// consumed by `overlay.css`/`content.js` via CSS variables (delivered in
/// every `ping` reply). Defaults match the values `overlay.css` used to
/// hardcode, so upgrading doesn't change the look for existing users until
/// they open the style panel.
struct SubtitleStyle: Codable, Equatable {
    var textColor: String = SubtitleStyle.defaultTextColor
    var backgroundColor: String = SubtitleStyle.defaultBackgroundColor
    var backgroundOpacity: Double = SubtitleStyle.defaultBackgroundOpacity
    var outlineEnabled: Bool = SubtitleStyle.defaultOutlineEnabled
    var outlineColor: String = SubtitleStyle.defaultOutlineColor
    /// Final CSS `font-family` value, stored verbatim — the app's font
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

/// Which AI engine runs translation and annotation.
enum EngineKind: String, Codable, CaseIterable, Sendable {
    /// Cloud if a key is saved for the selected provider, else the local
    /// model if it's downloaded, else not ready.
    case auto
    /// MLX + Gemma on this Mac.
    case local
    /// The user's own API key (BYOK).
    case cloud
}

/// The cloud half of the engine settings. The API key itself is never here;
/// it lives in the shared keychain (`SecretStore`).
struct CloudSettings: Codable, Equatable, Sendable {
    var provider: CloudProvider = .anthropic
    /// Empty means the provider's default model.
    var model: String = ""
    /// Only used by `.custom` (an OpenAI-compatible server).
    var baseURL: String = ""

    init() {}

    init(provider: CloudProvider, model: String = "", baseURL: String = "") {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
    }

    enum CodingKeys: String, CodingKey { case provider, model, baseURL }

    // An unknown provider (written by a newer build) falls back to the
    // default instead of failing the whole config.
    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? container.decodeIfPresent(CloudProvider.self, forKey: .provider)) ?? .anthropic
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
        baseURL = (try? container.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
    }

    /// The model actually requested.
    var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }
}

/// Preferences both the extension (`storage.local.settings`) and the app
/// can change. Whoever wrote last wins, decided by `updatedAt`, so the
/// popup and the app's onboarding never silently undo each other.
struct SharedPrefs: Codable, Equatable, Sendable {
    /// "netflix" | "translate" | "annotate"
    var mode: String?
    /// e.g. "zh-TW"
    var targetLang: String?
    /// "A2" | "B1" | "B2" | "C1"
    var annotateLevel: String?
    /// Milliseconds since epoch, like JS `Date.now()`.
    var updatedAt: Double = 0

    init(mode: String? = nil, targetLang: String? = nil, annotateLevel: String? = nil, updatedAt: Double = 0) {
        self.mode = mode
        self.targetLang = targetLang
        self.annotateLevel = annotateLevel
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case mode, targetLang, annotateLevel, updatedAt }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try? container.decodeIfPresent(String.self, forKey: .mode)
        targetLang = try? container.decodeIfPresent(String.self, forKey: .targetLang)
        annotateLevel = try? container.decodeIfPresent(String.self, forKey: .annotateLevel)
        updatedAt = (try? container.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? 0
    }

    /// Now, in the same unit as `updatedAt`.
    static var nowMs: Double { (Date().timeIntervalSince1970 * 1000).rounded() }
}

struct MultiSubConfig: Codable, Equatable {
    var modelID: String = MultiSubConfig.defaultModelID
    /// Minutes of inactivity before `Translator` auto-unloads the local
    /// model to free memory. `<= 0` disables auto-unload.
    var idleUnloadMinutes: Int = MultiSubConfig.defaultIdleUnloadMinutes
    /// Overlay subtitle style, single source of truth (app writes, extension
    /// reads via `ping`'s `styles` field).
    var styles: SubtitleStyle = SubtitleStyle()
    var engine: EngineKind = .auto
    var cloud: CloudSettings = CloudSettings()
    /// Nil until either side has set a mode / language / level.
    var prefs: SharedPrefs?
    var onboardingCompleted: Bool = false
    /// Cloud provider rawValue → when (ms since epoch) the user confirmed
    /// that subtitle text may be sent there directly from this Mac. App
    /// Review 5.1.2(i) wants that consent, naming the recipient, before the
    /// first request, so `Translator.resolveEngine` treats a provider with
    /// no entry as not ready. Recorded by the app's confirmation alert or by
    /// `set-engine` with `consent: true`; never removed by switching away,
    /// so switching back doesn't ask again.
    var cloudConsent: [String: Double] = [:]

    static let defaultModelID = "mlx-community/gemma-4-e4b-it-4bit"
    static let defaultIdleUnloadMinutes = 15

    init() {}

    func hasCloudConsent(for provider: CloudProvider) -> Bool {
        cloudConsent[provider.rawValue] != nil
    }

    mutating func recordCloudConsent(for provider: CloudProvider, at timestamp: Double = SharedPrefs.nowMs) {
        cloudConsent[provider.rawValue] = timestamp
    }

    // Custom decode so config.json files written before a key existed still
    // decode instead of failing wholesale and silently reverting everything
    // (modelID included) to defaults. New keys use `try?` so a value from a
    // newer build that this one doesn't understand only resets that key.
    enum CodingKeys: String, CodingKey {
        case modelID, idleUnloadMinutes, styles, engine, cloud, prefs, onboardingCompleted, cloudConsent
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? Self.defaultModelID
        idleUnloadMinutes = try container.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes)
            ?? Self.defaultIdleUnloadMinutes
        styles = try container.decodeIfPresent(SubtitleStyle.self, forKey: .styles) ?? SubtitleStyle()
        engine = (try? container.decodeIfPresent(EngineKind.self, forKey: .engine)) ?? .auto
        cloud = (try? container.decodeIfPresent(CloudSettings.self, forKey: .cloud)) ?? CloudSettings()
        prefs = try? container.decodeIfPresent(SharedPrefs.self, forKey: .prefs)
        onboardingCompleted = (try? container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)) ?? false
        cloudConsent = (try? container.decodeIfPresent([String: Double].self, forKey: .cloudConsent)) ?? [:]
    }

    static func load() -> MultiSubConfig {
        load(from: MultiSubPaths.configFile)
    }

    /// Writes this whole value. Prefer `update` for changes: the app and the
    /// extension both write config.json, and a whole-value save from a stale
    /// copy undoes whatever the other process wrote in between.
    func save() {
        let url = MultiSubPaths.configFile
        Self.coordinatedWrite(at: url) { writeURL in write(to: writeURL) }
    }

    /// Loads config.json fresh, applies `mutate`, and writes it back, all
    /// inside one coordinated write so the app and the extension can't
    /// interleave a read-modify-write. Returns the value written.
    @discardableResult
    static func update(_ mutate: (inout MultiSubConfig) -> Void) -> MultiSubConfig {
        let url = MultiSubPaths.configFile
        var result = MultiSubConfig()
        coordinatedWrite(at: url) { writeURL in
            var config = load(from: writeURL)
            mutate(&config)
            config.write(to: writeURL)
            result = config
        }
        return result
    }

    // MARK: - File access

    private static func load(from url: URL) -> MultiSubConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(MultiSubConfig.self, from: data)
        else { return MultiSubConfig() }
        return config
    }

    private func write(to url: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Serializes writers in this process (native messages can be handled
    /// concurrently) and, through NSFileCoordinator, across the app and the
    /// extension. If coordination itself fails the body still runs: a
    /// best-effort write beats dropping the user's change.
    private static let writeLock = NSLock()

    private static func coordinatedWrite(at url: URL, _ body: (URL) -> Void) {
        writeLock.lock()
        defer { writeLock.unlock() }
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forMerging, error: &coordinationError
        ) { writeURL in
            body(writeURL)
        }
        // On a coordination error the accessor above never ran.
        if coordinationError != nil { body(url) }
    }
}
