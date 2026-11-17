//
//  Lexicon.swift
//  MultiSub
//
//  English word lists and the small amount of morphology built on them:
//  stopwords, CEFR levels, naive lemmatisation, and the annotate-mode
//  candidate filter. Shared between the host app (vocabulary extraction)
//  and the Safari extension (annotate mode); both bundles carry the two
//  resource files.
//

import Foundation

enum Lexicon {
    /// Folder holding `stopwords-en.txt` and `cefr-wordlist-en.txt`. Nil (the
    /// default) reads them from the main bundle; standalone prompt tests
    /// point it at the source Resources folder. Set it before the first
    /// lookup — the lists are loaded once.
    nonisolated(unsafe) static var resourceDirectory: URL?

    static let levels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    static func rank(of level: String) -> Int? {
        levels.firstIndex(of: level.uppercased())
    }

    // MARK: - Word lists

    /// Function words and the most basic vocabulary. Used as a guardrail on
    /// model output (vocabulary extraction) and to drop tokens before they
    /// become annotate candidates. Stripping these out of the subtitle text
    /// itself would mangle the sentences the model needs for context, so the
    /// filter is always applied to words, never to lines.
    static let stopwords: Set<String> = {
        guard let text = loadResource("stopwords-en") else { return [] }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }()

    /// Real, properly-licensed A1–C2 data: A1–B2 from "The CEFR-J Wordlist"
    /// v1.5 (Yukio Tono, Tokyo University of Foreign Studies — usable for
    /// research and commercial purposes with attribution), C1–C2 from the
    /// "Octanove Vocabulary Profile for C1/C2" v1.0 (Octanove Labs — CC
    /// BY-SA 4.0). Both from https://github.com/openlanguageprofiles/olp-en-cefrj.
    /// Full citation and processing notes (slash-variant expansion,
    /// lower-level-wins on POS-sense conflicts) are in the resource file's own
    /// header comment. Format: `word<TAB>LEVEL`, one per line; lines without
    /// exactly one tab (including the `#`-commented header) are skipped.
    static let cefrWordlist: [String: String] = {
        guard let text = loadResource("cefr-wordlist-en") else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces).uppercased()
        }
        return result
    }()

    private static func loadResource(_ name: String) -> String? {
        let url = resourceDirectory.map { $0.appendingPathComponent(name + ".txt") }
            ?? Bundle.main.url(forResource: name, withExtension: "txt")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func isStopword(_ word: String) -> Bool {
        stopwords.contains(word.lowercased())
    }

    // MARK: - Morphology

    /// Possible dictionary forms of an inflected word, most likely first.
    /// Deliberately naive (suffix stripping plus a short irregular-verb
    /// table): it only has to find *a* list entry so common inflections of
    /// easy words aren't mistaken for rare words. Doesn't include `word`.
    static func lemmaCandidates(_ word: String) -> [String] {
        let w = word.lowercased()
        var out: [String] = []
        func add(_ s: String) { if s.count >= 2, s != w, !out.contains(s) { out.append(s) } }
        func drop(_ n: Int) -> String { String(w.dropLast(n)) }
        func undoubled(_ stem: String) -> String? {
            // "stopped" → "stopp" → "stop", "bigger" → "bigg" → "big"
            guard stem.count >= 3, let last = stem.last, stem.dropLast().last == last,
                  !"aeiouyslz".contains(last) else { return nil }
            return String(stem.dropLast())
        }

        if let base = irregular[w] { add(base) }

        if w.hasSuffix("ies"), w.count > 4 { add(drop(3) + "y") }
        if w.hasSuffix("ied"), w.count > 4 { add(drop(3) + "y") }
        if w.hasSuffix("es"), w.count > 3 { add(drop(2)); add(drop(1)) }
        if w.hasSuffix("s"), !w.hasSuffix("ss"), w.count > 3 { add(drop(1)) }
        if w.hasSuffix("ed"), w.count > 4 {
            let stem = drop(2)
            add(stem); add(drop(1))
            if let u = undoubled(stem) { add(u) }
        }
        if w.hasSuffix("ing"), w.count > 4 {
            let stem = drop(3)
            add(stem); add(stem + "e")
            if let u = undoubled(stem) { add(u) }
        }
        if w.hasSuffix("ily"), w.count > 5 { add(drop(3) + "y") }
        if w.hasSuffix("ally"), w.count > 6 { add(drop(4)) }
        if w.hasSuffix("ly"), w.count > 4 { add(drop(2)) }
        if w.hasSuffix("ier"), w.count > 4 { add(drop(3) + "y") }
        if w.hasSuffix("er"), w.count > 4 {
            let stem = drop(2)
            add(stem); add(drop(1))
            if let u = undoubled(stem) { add(u) }
        }
        if w.hasSuffix("iest"), w.count > 5 { add(drop(4) + "y") }
        if w.hasSuffix("est"), w.count > 5 {
            let stem = drop(3)
            add(stem); add(drop(2))
            if let u = undoubled(stem) { add(u) }
        }
        return out
    }

    /// CEFR level of `word` or, when it isn't listed as written, of the
    /// easiest dictionary form found for it. Picking the easiest keeps
    /// annotate conservative: a wrong guess hides a gloss instead of adding a
    /// distracting one.
    static func cefrLevel(for word: String) -> String? {
        let w = word.lowercased()
        if let level = cefrWordlist[w] { return level }
        return lemmaCandidates(w)
            .compactMap { cefrWordlist[$0] }
            .min { (rank(of: $0) ?? 99) < (rank(of: $1) ?? 99) }
    }

    // MARK: - Annotate candidates

    /// Words in one English subtitle line that are probably above
    /// `learnerLevel` (A2, B1, B2 or C1): listed above that level, or not
    /// listed at all and long enough (≥ 5 letters) to look rare. Skips
    /// speaker tags and sound cues in [...] or (...), contractions, tokens
    /// with digits, ALL-CAPS shouting/tags, capitalised words mid-sentence
    /// (names) and stopwords. Returned as written in the line, first
    /// occurrence only.
    static func candidates(in line: String, learnerLevel: String) -> [String] {
        let learnerRank = rank(of: learnerLevel) ?? rank(of: "B1")!
        let text = bracketed.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: " ")
        let ns = text as NSString
        var result: [String] = []
        var seen = Set<String>()
        var previousEnd = 0

        for match in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
            let atSentenceStart = previousEnd == 0 || startsSentence(afterGap: gap)
            previousEnd = match.range.location + match.range.length
            let word = ns.substring(with: match.range)

            guard !word.contains(where: { $0 == "'" || $0 == "\u{2019}" || $0.isNumber }) else { continue }
            guard word.allSatisfy({ $0.isLetter }) else { continue }
            if word.count >= 2, word == word.uppercased() { continue }
            if !atSentenceStart, word.first?.isUppercase == true { continue }
            let lower = word.lowercased()
            guard !isStopword(lower), seen.insert(lower).inserted else { continue }

            if let level = cefrLevel(for: lower) {
                if let r = rank(of: level), r > learnerRank { result.append(word) }
            } else if lower.count >= 5 {
                result.append(word)
            }
        }
        return result
    }

    /// Sentence punctuation, or a line break that starts a new speaker
    /// ("- …"). A bare line break doesn't count: subtitles wrap mid-sentence.
    private static func startsSentence(afterGap gap: String) -> Bool {
        if gap.contains(where: { ".!?…:".contains($0) }) { return true }
        return gap.range(of: #"\n\s*[-–—]"#, options: .regularExpression) != nil
    }

    private static let bracketed = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^)]*\)"#)
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}'’]+"#)

    /// Common irregular forms long enough (≥ 5 letters) to otherwise look
    /// like rare unlisted words.
    private static let irregular: [String: String] = [
        "thought": "think", "brought": "bring", "bought": "buy", "caught": "catch", "taught": "teach",
        "fought": "fight", "sought": "seek", "understood": "understand", "written": "write",
        "begun": "begin", "began": "begin", "broken": "break", "chosen": "choose", "driven": "drive",
        "eaten": "eat", "fallen": "fall", "forgot": "forget", "forgotten": "forget", "gotten": "get",
        "grown": "grow", "hidden": "hide", "heard": "hear", "spoken": "speak", "stolen": "steal",
        "thrown": "throw", "drawn": "draw", "shaken": "shake", "struck": "strike", "sworn": "swear",
        "woken": "wake", "ridden": "ride", "risen": "rise", "taken": "take", "given": "give",
        "known": "know", "shown": "show", "flown": "fly", "slept": "sleep", "spent": "spend",
        "stood": "stand", "built": "build", "meant": "mean", "dealt": "deal", "dreamt": "dream",
        "learnt": "learn", "burnt": "burn", "swept": "sweep", "wept": "weep", "kept": "keep",
        "spoke": "speak", "stole": "steal", "threw": "throw", "drove": "drive", "chose": "choose",
        "broke": "break", "wrote": "write", "froze": "freeze", "frozen": "freeze", "swore": "swear",
        "children": "child", "women": "woman", "people": "person", "teeth": "tooth",
    ]
}
