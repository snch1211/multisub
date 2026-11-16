//
//  Prompts.swift
//  MultiSub
//
//  Every prompt the engines run, and the parsers for their output. Both the
//  local model and the cloud engines get exactly the same text; `Translator`
//  only decides where it goes.
//
//  Depends on Foundation, `LanguageNames` and nothing engine-specific, so it
//  can be compiled on its own for prompt testing.
//

import Foundation

/// One glossed word or phrase in an annotated subtitle line.
struct Annotation: Codable, Sendable, Equatable, Hashable {
    var term: String
    var gloss: String
}

/// One model-extracted vocabulary candidate before cross-segment
/// deduplication and CEFR correction. Distinct from `VocabWord`: no
/// `cueIndex` yet (computed after merge, against the full episode) and
/// `cefr` is the model's own, unreliable estimate (the word list overrides it).
struct RawVocabEntry: Equatable {
    var word: String
    var lemma: String
    var pos: String
    var cefr: String
    var definitionEn: String
    var translation: String
    var example: String
    var exampleTranslation: String
}

enum Prompts {

    // MARK: - Translation

    static func systemPrompt(language: String) -> String {
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

    static func singlePrompt(_ line: String, language: String, reference: String? = nil,
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

    static func batchPrompt(_ lines: [String], language: String, reference: [String?] = [],
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
            prompt += "\n\(i + 1). \(flatten(line))"
            if i < reference.count, let ref = reference[i], !ref.isEmpty {
                prompt += "\n   [Official] \(flatten(ref))"
            }
        }
        return prompt
    }

    /// Renders a glossary map into the block prepended to translation
    /// prompts. `nil` when there's nothing worth injecting.
    static func glossaryBlock(_ glossary: [String: String]?, language: String) -> String? {
        guard let glossary, !glossary.isEmpty else { return nil }
        let lines = glossary.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
        return "Established \(language) translations for names/terms in this episode — " +
            "use these exactly when they appear, don't invent alternatives:\n" + lines.joined(separator: "\n")
    }

    static func cleanLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseNumbered(_ output: String, expected: Int) -> [String]? {
        var results = [String?](repeating: nil, count: expected)
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let m = numberedLine.firstMatch(in: line, range: range),
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

    private static let numberedLine = try! NSRegularExpression(pattern: #"^\s*(\d+)[.)、]\s*(.*)$"#)

    // MARK: - Glossary extraction

    static func glossarySystemPrompt(language: String) -> String {
        """
        You compare original subtitle dialogue with its official \(language) translation and extract a \
        glossary of proper nouns — character names, place names, organizations, or other recurring terms — \
        together with the exact wording used for them in the official translation. \
        Output ONLY a JSON array like [{"term":"Mike","translation":"麥克"}], no other text, no markdown fence. \
        Skip common words and anything that isn't a proper noun or recurring term. If nothing qualifies, output [].
        """
    }

    static func glossaryExtractionPrompt(_ pairs: [(source: String, reference: String)], language: String) -> String {
        var prompt = "Original subtitle lines paired with their official \(language) translation, from the same episode:\n"
        for (i, pair) in pairs.enumerated() {
            prompt += "\n\(i + 1). \(flatten(pair.source))\n   official: \(flatten(pair.reference))"
        }
        return prompt
    }

    static func parseGlossaryJSON(_ output: String) -> [String: String] {
        guard let data = stripFence(output).data(using: .utf8),
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

    // MARK: - Vocabulary extraction (生詞本)

    static func vocabSystemPrompt(language: String) -> String {
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

    static func vocabExtractionPrompt(_ lines: [String]) -> String {
        var prompt = "Subtitle lines from this segment (for context only - extract vocabulary appearing in them):\n"
        for (i, line) in lines.enumerated() {
            prompt += "\n\(i + 1). \(flatten(line))"
        }
        return prompt
    }

    static let vocabRetrySuffix =
        "\n\n(Your previous output was not valid JSON. Output ONLY the JSON array described above, nothing else.)"

    static func parseVocabJSON(_ output: String) -> [RawVocabEntry]? {
        guard let data = stripFence(output).data(using: .utf8),
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

    // MARK: - Annotate (生字標註)

    /// What each learner level can already handle, in the model's terms.
    /// The level alone ("B1") is too vague for consistent picks.
    static func levelDescriptor(_ level: String) -> String {
        switch level.uppercased() {
        case "A2":
            return "elementary: knows everyday words for people, places, food and routines; " +
                "most other vocabulary, idioms and phrasal verbs are new"
        case "B2":
            return "upper-intermediate: follows most dialogue and knows common idioms; " +
                "only less common words, slang and trickier idioms are worth a gloss"
        case "C1":
            return "advanced: understands nearly everything; only rare words, specialist terms " +
                "and unusual idioms are worth a gloss"
        default:
            return "intermediate: handles everyday conversation and common words; " +
                "less common words, idioms and phrasal verbs are often unknown"
        }
    }

    /// `hasCandidates` is false for sources the word list doesn't cover;
    /// the model then relies on its own sense of the level.
    static func annotateSystemPrompt(sourceLanguage: String, targetLanguage: String, targetLang: String,
                                     level: String, hasCandidates: Bool = true) -> String {
        let level = level.uppercased()
        let article = level.hasPrefix("A") ? "an" : "a"
        let singleWords = hasCandidates
            ? """
            - Then single words \(article) \(level) learner probably hasn't met yet. "Candidates" lists the single words \
            a word list rates above \(level); idioms and phrasal verbs are never listed. A single word that is \
            not a candidate is usually known: pick it only if \(article) \(level) learner may well not know it yet. \
            Skip a candidate that is easy in context.
            """
            : """
            - Then single words \(article) \(level) learner probably hasn't met yet. Most words in everyday dialogue \
            are known at this level: pick a single word only if it is clearly less common.
            """
        let glossRule: String
        if LanguageNames.primarySubtag(targetLang) == "zh" {
            glossRule = "1–6 characters, a bare word or phrase (no trailing 的 or 了)"
        } else if LanguageNames.isCJK(targetLang) {
            glossRule = "1–6 characters"
        } else {
            glossRule = "at most 3 words"
        }
        return """
        You help \(article) \(level) learner of \(sourceLanguage) watch a show with \(sourceLanguage) subtitles. In each \
        line, mark only the words or phrases this learner would likely not understand, and give each a very \
        short \(targetLanguage) gloss: what it means in this line.

        Learner level \(level) — \(levelDescriptor(level)).

        How to pick:
        - First check every line for idioms and phrasal verbs (e.g. "figure out", "run out of", \
        "break the ice"). They are the most useful picks; mark the whole phrase, never a word inside it.
        \(singleWords)
        - A term is an idiom, a phrasal verb or one word. Never add too, so, very or really to a word \
        ("exhausted", not "too exhausted").
        - At most 2 picks per line. Many lines need none.
        - Skip names, places, interjections, numbers, sound cues, and everyday words such as \
        "phone", "leave", "tonight".

        How to write each pick:
        - "term": copied exactly from the line, in the same form ("stumbled", not "stumble").
        - "gloss": the meaning in this line, in \(targetLanguage), \(glossRule). If the Official line has \
        words for this idea, even a loose rendering, copy those words exactly as the gloss instead of a \
        dictionary translation. Write your own only when it has none. Never translate the whole line.

        \(annotateExample(targetLang))
        Output ONLY the JSON array ("i" is the line number), or [] when no line needs a gloss. \
        No markdown fence, no other text.
        """
    }

    /// `context` lines come right before the chunk and are shown read-only,
    /// so a chunk boundary never strands a pronoun or a split sentence.
    /// `candidates` is nil for sources the word list doesn't cover.
    static func annotatePrompt(lines: [String], context: [String], reference: [String?],
                               candidates: [[String]]?, targetLanguage: String) -> String {
        var prompt = ""
        let context = context.map(flatten).filter { !$0.isEmpty }
        if !context.isEmpty {
            prompt += "Earlier lines (context only, do not annotate):\n"
            for line in context { prompt += "- \(line)\n" }
            prompt += "\n"
        }
        let hasReference = reference.contains { ($0?.isEmpty ?? true) == false }
        prompt += hasReference
            ? "Lines to annotate (with the official \(targetLanguage) subtitle shown at the same moment):\n"
            : "Lines to annotate:\n"
        for (i, line) in lines.enumerated() {
            prompt += "\n\(i + 1). \(flatten(line))"
            if i < reference.count, let ref = reference[i], !ref.isEmpty {
                prompt += "\n   Official: \(flatten(ref))"
            }
            if let candidates {
                let list = i < candidates.count ? candidates[i] : []
                prompt += "\n   Candidates: " + (list.isEmpty ? "—" : list.joined(separator: ", "))
            }
        }
        return prompt
    }

    static let annotateRetrySuffix =
        "\n\n(Your previous output was not a valid JSON array. Output ONLY the JSON array described above, nothing else.)"

    /// A worked example from an unrelated scene. For Chinese it also shows
    /// the two habits plain rules didn't get across: taking the gloss from
    /// the official line ("兜圈子", not the dictionary's "拐彎抹角") and
    /// picking a phrase and a word in the same line.
    private static func annotateExample(_ targetLang: String) -> String {
        switch LanguageNames.primarySubtag(targetLang) {
        case "zh":
            let traditional = targetLang.lowercased() != "zh-cn" && !targetLang.lowercased().contains("hans")
            let official1 = traditional ? "稽核過後，她終於承認了。" : "稽核过后，她终于承认了。"
            let official2 = traditional ? "別兜圈子了，快說。" : "别兜圈子了，快说。"
            let gloss1 = traditional ? "承認" : "承认"
            return """
            Example (another show):
            1. She finally owned up to it after the audit.
               Official: \(official1)
            2. Quit beating around the bush and tell me.
               Official: \(official2)
            Output: [{"i":1,"term":"owned up to","gloss":"\(gloss1)"},{"i":1,"term":"audit","gloss":"稽核"},\
            {"i":2,"term":"beating around the bush","gloss":"兜圈子"}]
            """
        case "ja":
            return #"Example output: [{"i":3,"term":"run out of","gloss":"切らす"}]"#
        case "ko":
            return #"Example output: [{"i":3,"term":"run out of","gloss":"다 떨어지다"}]"#
        case "es":
            return #"Example output: [{"i":3,"term":"run out of","gloss":"quedarse sin"}]"#
        case "fr":
            return #"Example output: [{"i":3,"term":"run out of","gloss":"manquer de"}]"#
        case "de":
            return #"Example output: [{"i":3,"term":"run out of","gloss":"ausgehen"}]"#
        default:
            return #"Example output: [{"i":3,"term":"run out of","gloss":"have none left"}]"#
        }
    }

    /// Groups the model's picks by line (`i` is 1-based, as numbered in the
    /// prompt). Tolerates a code fence or prose around the array. Returns nil
    /// only when no JSON array can be found at all, which is the caller's cue
    /// to retry; malformed items inside a valid array are just skipped.
    static func parseAnnotations(_ output: String, lineCount: Int) -> [[Annotation]]? {
        guard let items = extractJSONArray(output) else { return nil }
        var result = [[Annotation]](repeating: [], count: max(lineCount, 0))
        for case let item as [String: Any] in items {
            guard let index = lineNumber(item["i"]).map({ $0 - 1 }),
                  index >= 0, index < lineCount,
                  let term = item["term"] as? String,
                  let gloss = item["gloss"] as? String
            else { continue }
            result[index].append(Annotation(term: term, gloss: gloss))
        }
        return result
    }

    /// Drops every pick that breaks a rule; never repairs one. The term must
    /// occur in its line, the gloss must be short and differ from the term,
    /// at most 2 picks per line, no repeated term within a line.
    static func validateAnnotations(_ raw: [[Annotation]], lines: [String], targetLang: String) -> [[Annotation]] {
        let cjkTarget = LanguageNames.isCJK(targetLang)
        return lines.indices.map { i in
            let picks = i < raw.count ? raw[i] : []
            var seen = Set<String>()
            var kept: [Annotation] = []
            for pick in picks where kept.count < 2 {
                let term = pick.term.trimmingCharacters(in: .whitespacesAndNewlines)
                let gloss = pick.gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty, !gloss.isEmpty,
                      gloss.lowercased() != term.lowercased(),
                      termWordCount(term) <= 6,
                      glossFits(gloss, cjkTarget: cjkTarget),
                      termOccurs(term, in: lines[i]),
                      seen.insert(term.lowercased()).inserted
                else { continue }
                kept.append(Annotation(term: term, gloss: gloss))
            }
            return kept
        }
    }

    private static func glossFits(_ gloss: String, cjkTarget: Bool) -> Bool {
        if cjkTarget { return gloss.count <= 12 }
        return gloss.split(whereSeparator: \.isWhitespace).count <= 4 && gloss.count <= 40
    }

    /// A term longer than this is a translated sentence, not a gloss target.
    private static func termWordCount(_ term: String) -> Int {
        term.split(whereSeparator: \.isWhitespace).count
    }

    /// Case-insensitive. Latin/Greek/Cyrillic terms must sit on word
    /// boundaries (so "art" doesn't match inside "start"); terms in scripts
    /// written without spaces are matched as plain substrings.
    static func termOccurs(_ term: String, in line: String) -> Bool {
        let term = normalizeForMatch(term)
        let line = normalizeForMatch(line)
        guard !term.isEmpty else { return false }
        if !usesSpacedScript(term) {
            return line.range(of: term, options: [.caseInsensitive]) != nil
        }
        let escaped = NSRegularExpression.escapedPattern(for: term)
            .replacingOccurrences(of: " ", with: #"\s+"#)
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{M}\p{N}])"# + escaped + #"(?![\p{L}\p{M}\p{N}])"#,
            options: [.caseInsensitive])
        else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Curly apostrophes and line breaks vary between the model's copy and
    /// the subtitle; neither changes what the term is.
    private static func normalizeForMatch(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func usesSpacedScript(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { scalar in
            guard scalar.properties.isAlphabetic else { return true }
            switch scalar.value {
            case 0x0000...0x024F, 0x1E00...0x1EFF: return true  // Latin
            case 0x0370...0x03FF, 0x1F00...0x1FFF: return true  // Greek
            case 0x0400...0x052F: return true                   // Cyrillic
            default: return false
            }
        }
    }

    private static func lineNumber(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double where d.rounded() == d: return Int(d)
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    // MARK: - Helpers

    /// Subtitle lines can contain internal newlines; prompts number one line per row.
    static func flatten(_ line: String) -> String {
        line.replacingOccurrences(of: "\n", with: " / ")
    }

    /// Models sometimes wrap JSON in a markdown fence despite instructions.
    private static func stripFence(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text.removeFirst(3)
            if text.hasPrefix("json") { text.removeFirst(4) }
            if let closingRange = text.range(of: "```") {
                text = String(text[..<closingRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The first JSON array of objects in `output` (or an empty array),
    /// wherever it sits: inside a fence, after a sentence of prose… Arrays
    /// of plain values are passed over, so prose like "Note [1]:" can't be
    /// mistaken for the answer, and brackets inside strings are skipped so a
    /// gloss containing "[" can't throw the scan off.
    static func extractJSONArray(_ output: String) -> [Any]? {
        func accepted(_ data: Data?) -> [Any]? {
            guard let data, let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  array.isEmpty || array.contains(where: { $0 is [String: Any] })
            else { return nil }
            return array
        }
        let text = stripFence(output)
        if let array = accepted(text.data(using: .utf8)) { return array }
        let chars = Array(text.unicodeScalars)
        var start = chars.startIndex
        while let open = chars[start...].firstIndex(of: "[") {
            var depth = 0
            var inString = false
            var escaped = false
            var end: Int?
            for j in open..<chars.endIndex {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    continue
                }
                if c == "\"" { inString = true }
                else if c == "[" { depth += 1 }
                else if c == "]" {
                    depth -= 1
                    if depth == 0 { end = j; break }
                }
            }
            // An unbalanced '[' in prose ("Note [1 is…") never gets back to
            // depth 0; move on to the next '[' rather than give up on a
            // valid array further along.
            guard let end else { start = open + 1; continue }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: chars[open...end])
            if let array = accepted(String(view).data(using: .utf8)) { return array }
            start = open + 1
        }
        return nil
    }
}
