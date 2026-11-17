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

    /// A custom server's address the way consent compares it: scheme and
    /// host lowercased, the port only when it isn't the scheme's default,
    /// the path without trailing slashes, no credentials, query or
    /// fragment. Nil unless it's an http(s) URL with a host. For an address
    /// `baseURLProblem` accepts, the WHATWG URL parser finds the same server.
    static func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.encodedHost?.lowercased(), !host.isEmpty
        else { return nil }
        var normalized = scheme + "://" + host
        if let port = components.port, port != (scheme == "https" ? 443 : 80) {
            normalized += ":\(port)"
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return normalized + path
    }

    /// Why `raw` can't be a custom server's address, as the message to
    /// show, or nil when it can.
    ///
    /// Besides being an http(s) URL with a host, the address must be one
    /// that Foundation, which records the consent and sends the requests,
    /// and a WHATWG URL parser (the popup's, back when it named the server
    /// in a consent step), or someone reading it in the app's consent
    /// alert, can't take for two different servers. WHATWG reads a
    /// backslash as "/" and drops tabs and line breaks, where Foundation
    /// escapes them: `http://localhost:1234\@evil.example/v1` is localhost
    /// to WHATWG (and to most readers) and evil.example here. So the host
    /// is ASCII letters, digits, ".", "-" and "_" or a bracketed IPv6
    /// address, with an optional port (no credentials, percent escapes or
    /// international names), and the whole address has no backslash,
    /// whitespace or control character. A host WHATWG reads as an IPv4
    /// address (its last label a number) must be written the plain way,
    /// 192.168.1.20: WHATWG turns 0x7f.1 or 2130706433 into 127.0.0.1,
    /// while Foundation asks DNS for that name.
    static func baseURLProblem(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://"),
              ["http", "https"].contains(trimmed[..<schemeEnd.lowerBound].lowercased())
        else { return "API 網址格式不正確，請以 http:// 或 https:// 開頭。" }
        let authority = trimmed[schemeEnd.upperBound...].prefix { !"/?#".contains($0) }
        let unsafe = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: unsafe.contains),
              isPlainAuthority(authority),
              let url = URL(string: trimmed), url.host?.isEmpty == false,
              normalizedBaseURL(trimmed) != nil
        else {
            return "API 網址格式不正確。主機名稱請用英文字母、數字、點或連字號，網址裡不要有帳號密碼（@）、反斜線或空白。"
        }
        return nil
    }

    /// `host` or `host:port`, the host ASCII letters, digits, ".", "-" and
    /// "_" or a bracketed IPv6 address, the port at most 65535.
    private static func isPlainAuthority(_ authority: Substring) -> Bool {
        let host: Substring
        var port: Substring = ""
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return false }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let rest = authority[authority.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":" else { return false }
                port = rest.dropFirst()
            }
            guard !host.isEmpty,
                  host.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") })
            else { return false }
        } else {
            if let colon = authority.firstIndex(of: ":") {
                host = authority[..<colon]
                port = authority[authority.index(after: colon)...]
            } else {
                host = authority
            }
            guard !host.isEmpty,
                  host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }),
                  !endsInNumber(host) || isDottedDecimalIPv4(host)
            else { return false }
        }
        guard port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return port.isEmpty || (Int(port).map { $0 <= 65535 } ?? false)
    }

    /// WHATWG's "ends in a number": the last label (before a trailing dot)
    /// is decimal digits or "0x" and hex digits, which sends the host
    /// through its IPv4 parser.
    private static func endsInNumber(_ host: Substring) -> Bool {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last?.isEmpty == true { labels.removeLast() }
        guard let last = labels.last?.lowercased(), !last.isEmpty else { return false }
        if last.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        return last.hasPrefix("0x") && last.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Four decimal numbers up to 255, no leading zeros: what both parsers
    /// read as the same IPv4 address.
    private static func isDottedDecimalIPv4(_ host: Substring) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || !part.hasPrefix("0"), let value = Int(part)
            else { return false }
            return value <= 255
        }
    }
}

/// Preferences both the extension (`storage.local.settings`) and the app
/// can change. Whoever wrote last wins, decided by `updatedAt`, so the
/// popup and the app's onboarding never silently undo each other.
///
/// A nil field means nobody has chosen it yet, and the `effective…` values
/// fill in the defaults. Defaults are only ever read, never written into
/// `prefs` or stamped with `updatedAt`: a default must not win the sync over
/// a choice made in the extension. shared.js does the same
/// (`DEFAULT_SETTINGS`, `prefsUpdatedAt` 0).
struct SharedPrefs: Codable, Equatable, Sendable {
    /// Netflix's own second-language subtitles: no AI, no setup. Same as
    /// DEFAULT_MODE in shared.js.
    static let defaultMode = "netflix"
    static let defaultAnnotateLevel = "B1"
    /// From the system's preferred languages, as the extension works it out.
    static var defaultTargetLang: String { LanguageNames.defaultTargetLang() }

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

    /// The mode in use: the chosen one, else `defaultMode`. An id this build
    /// doesn't know also counts as unset, as in shared.js's mergeSettings.
    var effectiveMode: String {
        guard let mode, ["netflix", "translate", "annotate"].contains(mode) else { return Self.defaultMode }
        return mode
    }

    var effectiveTargetLang: String {
        guard let targetLang, !targetLang.isEmpty else { return Self.defaultTargetLang }
        return targetLang
    }

    var effectiveAnnotateLevel: String {
        guard let annotateLevel, ["A2", "B1", "B2", "C1"].contains(annotateLevel) else { return Self.defaultAnnotateLevel }
        return annotateLevel
    }
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
    /// Who the user agreed may receive subtitle text directly from this
    /// Mac → when (ms since epoch). App Review 5.1.2(i) wants that consent,
    /// naming the recipient, before the first request, so
    /// `Translator.resolveEngine` treats settings with no entry as not
    /// ready. Keyed by `consentKey(for:baseURL:)`: a provider's rawValue,
    /// except that a custom server's consent belongs to its address, so
    /// agreeing to one server says nothing about the next one typed in.
    /// Recorded by the app's confirmation alert or by `set-engine` with
    /// `consent: true`; never removed by switching away, so switching back
    /// doesn't ask again.
    var cloudConsent: [String: Double] = [:]

    static let defaultModelID = "mlx-community/gemma-4-e4b-it-4bit"
    static let defaultIdleUnloadMinutes = 15

    init() {}

    /// What `cloudConsent` keys a custom server's address with.
    static let customConsentPrefix = "custom:"

    /// The `cloudConsent` key for sending to `provider`: its rawValue, or
    /// for `.custom` the prefix plus `CloudSettings.normalizedBaseURL`.
    /// `baseURL` only matters for `.custom`, and a custom server without a
    /// usable address has no key, so it can't be agreed to.
    static func consentKey(for provider: CloudProvider, baseURL: String) -> String? {
        guard provider == .custom else { return provider.rawValue }
        return CloudSettings.normalizedBaseURL(baseURL).map { customConsentPrefix + $0 }
    }

    func hasCloudConsent(for provider: CloudProvider, baseURL: String) -> Bool {
        guard let key = Self.consentKey(for: provider, baseURL: baseURL) else { return false }
        return cloudConsent[key] != nil
    }

    func hasCloudConsent(for settings: CloudSettings) -> Bool {
        hasCloudConsent(for: settings.provider, baseURL: settings.baseURL)
    }

    mutating func recordCloudConsent(for provider: CloudProvider, baseURL: String,
                                     at timestamp: Double = SharedPrefs.nowMs) {
        guard let key = Self.consentKey(for: provider, baseURL: baseURL) else { return }
        cloudConsent[key] = timestamp
    }

    /// The custom server addresses the user has agreed to, normalized.
    var consentedCustomBaseURLs: [String] {
        cloudConsent.keys
            .filter { $0.hasPrefix(Self.customConsentPrefix) }
            .map { String($0.dropFirst(Self.customConsentPrefix.count)) }
            .sorted()
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
        // Builds before per-address consent kept a custom server's consent
        // under plain "custom". It moves to the address saved in this same
        // file (the one the user has been using), or is dropped when there
        // is none; the next write stores the result, after which there is
        // nothing left to move.
        if let legacy = cloudConsent.removeValue(forKey: CloudProvider.custom.rawValue),
           let key = Self.consentKey(for: .custom, baseURL: cloud.baseURL), cloudConsent[key] == nil {
            cloudConsent[key] = legacy
        }
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
