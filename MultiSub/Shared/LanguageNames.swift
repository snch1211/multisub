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
