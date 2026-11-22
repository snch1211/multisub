//
//  PronunciationPlayer.swift
//  MultiSub
//
//  Reads a word or an example sentence aloud for 生詞本, with the voices
//  macOS already ships (AVSpeechSynthesizer). Chosen over a cloud TTS on
//  purpose: it works offline, needs no key or account, and sends nothing
//  off the Mac, so the privacy policy and the App Sandbox entitlements stay
//  as they are.
//
//  One thing plays at a time. `speakingID` names it so the button that
//  started it can show a playing state and act as a stop button.
//

import AVFoundation
import SwiftUI

@Observable
@MainActor
final class PronunciationPlayer: NSObject, AVSpeechSynthesizerDelegate {
    /// English accents the user can pick between. The raw value is the
    /// BCP 47 code the voice is looked up by, and what is stored in
    /// `UserDefaults` under `accentDefaultsKey`.
    enum Accent: String, CaseIterable, Identifiable {
        case american = "en-US"
        case british = "en-GB"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .american: return "美式發音"
            case .british: return "英式發音"
            }
        }
    }

    static let accentDefaultsKey = "vocabPronunciationAccent"

    /// The caller's id for what is being read right now, nil when silent.
    private(set) var speakingID: String?

    /// Created on first use: SwiftUI evaluates a `@State` initial value more
    /// often than it keeps one, and an idle synthesizer is not free.
    @ObservationIgnored private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()

    /// The utterance `speakingID` belongs to. Stopping one utterance to
    /// start another delivers the old one's `didCancel` after the new one
    /// has begun, and that callback must not clear the new one's state.
    @ObservationIgnored private var currentUtterance: ObjectIdentifier?

    /// Language code -> chosen voice. Listing the installed voices is slow
    /// enough to notice on every click; dropped when the set changes.
    @ObservationIgnored private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]
    @ObservationIgnored private var voicesObserver: NSObjectProtocol?

    override init() {
        super.init()
        voicesObserver = NotificationCenter.default.addObserver(
            forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.voiceCache.removeAll() }
        }
    }

    deinit {
        if let voicesObserver { NotificationCenter.default.removeObserver(voicesObserver) }
    }

    /// Reads `text` aloud, or stops if `id` is what is already playing.
    func toggle(_ text: String, id: String, language: String) {
        if speakingID == id {
            stop()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice(for: language)
        currentUtterance = ObjectIdentifier(utterance)
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        guard speakingID != nil else { return }
        currentUtterance = nil
        speakingID = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The most natural voice installed for `language`: a Premium or
    /// Enhanced one if the user has downloaded any (System Settings >
    /// Accessibility > Spoken Content), otherwise the system's own default
    /// for that language. The fallback is not "the first voice in the list"
    /// because that list also holds the novelty voices and the Eloquence
    /// set, which no one wants a vocabulary word read in.
    private func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }
        let wanted = language.lowercased()
        let upgraded = AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let code = voice.language.lowercased()
                guard code == wanted || code.hasPrefix(wanted + "-") else { return false }
                guard voice.quality != .default else { return false }
                return voice.voiceTraits.isDisjoint(with: [.isNoveltyVoice, .isPersonalVoice])
            }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        let chosen = upgraded ?? AVSpeechSynthesisVoice(language: language)
        if let chosen { voiceCache[language] = chosen }
        return chosen
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        utteranceEnded(ObjectIdentifier(utterance))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        utteranceEnded(ObjectIdentifier(utterance))
    }

    private nonisolated func utteranceEnded(_ utterance: ObjectIdentifier) {
        Task { @MainActor in
            guard currentUtterance == utterance else { return }
            currentUtterance = nil
            speakingID = nil
        }
    }
}

/// The speaker button next to a word or sentence. Shows a moving wave
/// while its own text is playing, when a click stops it.
@MainActor
struct PronounceButton: View {
    let text: String
    /// Unique among everything on screen that can be read aloud.
    let id: String
    let language: String
    let player: PronunciationPlayer

    @State private var isHovered = false

    private var isSpeaking: Bool { player.speakingID == id }

    /// Quiet until it is pointed at or playing: there is one of these on
    /// every row of the word table, and the words are what should be read.
    private var style: AnyShapeStyle {
        if isSpeaking { return AnyShapeStyle(.tint) }
        return isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
    }

    var body: some View {
        Button {
            player.toggle(text, id: id, language: language)
        } label: {
            Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                .symbolEffect(.variableColor.iterative, isActive: isSpeaking)
                .foregroundStyle(style)
                // Same width for both symbols, so the text beside the
                // button doesn't shift when playback starts.
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isSpeaking ? "停止" : "播放發音")
        .accessibilityLabel(isSpeaking ? "停止播放" : "播放「\(text)」的發音")
    }
}
