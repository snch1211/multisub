//
//  LanguageNames.swift
//  MultiSub
//

import Foundation

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

    // MARK: - Default second language

    /// Codes the extension offers as a second language, in picker order:
    /// `LANGUAGES` in extension/shared.js and `SubtitleChoices.languages` in
    /// the app list the same ones.
    static let supportedCodes = ["zh-TW", "zh-CN", "en", "ja", "ko", "es", "fr", "de", "pt", "vi", "th", "id"]

    /// The second language when the system's preferred language isn't one of
    /// `supportedCodes`. Same as FALLBACK_TARGET_LANG in shared.js.
    static let fallbackTargetLang = "zh-TW"

    /// Chinese, plus the Chinese languages macOS lists on their own (yue
    /// Cantonese, wuu Shanghainese), each with the code its tag maps to when
    /// it names neither a script nor a region: CLDR's likely subtags (zh →
    /// zh-Hans-CN, yue → yue-Hant-HK, wuu → wuu-Hans-CN). Same as
    /// CHINESE_DEFAULTS in shared.js.
    private static let chineseDefaults = ["zh": "zh-CN", "yue": "zh-TW", "wuu": "zh-CN"]

    /// Maps one BCP 47 tag ("zh-Hant-TW", "ja-JP", "en_US") to a code in
    /// `supportedCodes`, or nil when we don't offer that language. Chinese
    /// (see `chineseDefaults`) goes by its script subtag when there is one
    /// (zh-Hans-HK is Simplified), else by its region (TW, HK and MO are
    /// Traditional; CN, SG and MY Simplified), else by `chineseDefaults`.
    /// Every other language matches on its primary subtag, so pt-BR is pt
    /// and es-419 is es. Extensions ("-u-...", "-x-...") and ICU keywords
    /// ("@...") are ignored.
    ///
    /// yue and wuu count as Chinese because Safari's `navigator.language`
    /// (what the extension sees) already folds them into zh-*: a Mac set to
    /// Cantonese (Simplified) reports "yue-Hans-CN" in
    /// `Locale.preferredLanguages` but "zh-CN" to web pages. Mapping them
    /// here lands both sides on one code.
    ///
    /// Must behave exactly like `supportedLanguageFor` in extension/shared.js
    /// (nil here is '' there): the app and the extension each work out the
    /// default second language on their own and must arrive at the same one.
    /// shared.test.js holds the cases.
    static func supportedLanguage(for tag: String) -> String? {
        let base = tag.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var parts = base.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        if let singleton = parts.firstIndex(where: { $0.count == 1 }) {
            parts = Array(parts[..<singleton])
        }
        guard let primary = parts.first else { return nil }
        if let chineseDefault = chineseDefaults[primary] {
            let rest = parts.dropFirst()
            if rest.contains("hant") { return "zh-TW" }
            if rest.contains("hans") { return "zh-CN" }
            if rest.contains(where: { $0 == "tw" || $0 == "hk" || $0 == "mo" }) { return "zh-TW" }
            if rest.contains(where: { $0 == "cn" || $0 == "sg" || $0 == "my" }) { return "zh-CN" }
            return chineseDefault
        }
        return supportedCodes.contains(primary) ? primary : nil
    }

    /// The default second language from the system's preferred languages,
    /// most preferred first: the first one decides, else
    /// `fallbackTargetLang`. Only the first, because Safari's
    /// `navigator.languages` (what the extension sees) holds just that one;
    /// looking further down the list here would let the app and the
    /// extension pick different defaults. Same as `defaultTargetLang` in
    /// shared.js.
    static func defaultTargetLang(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        preferredLanguages.first.flatMap(supportedLanguage(for:)) ?? fallbackTargetLang
    }

    // MARK: - Tags

    /// Primary subtag, lowercased: "en-US" → "en", "zh-Hant" → "zh".
    static func primarySubtag(_ code: String) -> String {
        let lower = code.lowercased()
        return String(lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(lower))
    }

    /// Netflix reports track languages as "en", "en-US", "en-GB"…
    static func isEnglish(_ code: String) -> Bool { primarySubtag(code) == "en" }

    /// Languages written without spaces between words (or, for Korean, with
    /// particles glued to words), where length is counted in characters
    /// rather than words.
    static func isCJK(_ code: String) -> Bool {
        ["zh", "ja", "ko"].contains(primarySubtag(code))
    }
}
