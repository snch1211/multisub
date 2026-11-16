//
//  OnboardingView.swift
//  MultiSub
//
//  「開始使用」: the two things only the user can do, as two numbered
//  steps. (1) Turn the extension on in Safari's settings and allow it on
//  netflix.com. (2) Open Netflix in Safari. Nothing else is required:
//  until the user picks something, the mode is Netflix's own second-language
//  subtitles and the second language follows the system language
//  (SharedPrefs' defaults, the same ones shared.js uses). The mode cards,
//  the language picker and the AI engine setup sit in one optional section
//  below, collapsed by default.
//
//  Step 1 shows the extension's live state (polled while the page is
//  visible), so the page doubles as a checklist when the user comes back
//  later to see why something isn't working.
//
//  Built as a grouped Form with a custom header per step rather than custom
//  cards, so it matches 一般設定 and can host EngineSetupView's Form rows
//  unchanged.
//

import SwiftUI

/// The three subtitle modes, mirroring `MODES` in extension/shared.js (same
/// ids, names and descriptions, so the popup and the app read alike).
enum SubtitleMode: String, CaseIterable, Identifiable {
    case netflix, translate, annotate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .netflix: return "Netflix 雙語字幕"
        case .translate: return "AI 翻譯雙語字幕"
        case .annotate: return "生字標註"
        }
    }

    var summary: String {
        switch self {
        case .netflix: return "直接疊上 Netflix 官方的第二語言字幕，不需 AI、免設定"
        case .translate: return "用 AI 翻譯原文字幕，任何片都能雙語"
        case .annotate: return "只顯示原文，在難字後面標上意思，適合學語言"
        }
    }

    var symbol: String {
        switch self {
        case .netflix: return "captions.bubble"
        case .translate: return "translate"
        case .annotate: return "character.book.closed"
        }
    }

    var needsEngine: Bool { self != .netflix }
}

/// Language and level choices, with the codes extension/shared.js uses.
/// The defaults live in `SharedPrefs`.
enum SubtitleChoices {
    struct Option: Identifiable, Hashable {
        let id: String
        /// What the pickers show (each language in its own script).
        let label: String
        /// The name in Traditional Chinese, for sentences such as
        /// 「第二語言是日文」 (`name` in shared.js's LANGUAGES).
        var name: String = ""
    }

    /// Same codes, in the same order, as `LanguageNames.supportedCodes`.
    static let languages: [Option] = [
        Option(id: "zh-TW", label: "繁體中文", name: "繁體中文"),
        Option(id: "zh-CN", label: "简体中文", name: "簡體中文"),
        Option(id: "en", label: "English", name: "英文"),
        Option(id: "ja", label: "日本語", name: "日文"),
        Option(id: "ko", label: "한국어", name: "韓文"),
        Option(id: "es", label: "Español", name: "西班牙文"),
        Option(id: "fr", label: "Français", name: "法文"),
        Option(id: "de", label: "Deutsch", name: "德文"),
        Option(id: "pt", label: "Português", name: "葡萄牙文"),
        Option(id: "vi", label: "Tiếng Việt", name: "越南文"),
        Option(id: "th", label: "ไทย", name: "泰文"),
        Option(id: "id", label: "Bahasa Indonesia", name: "印尼文"),
    ]

    static let levels: [Option] = [
        Option(id: "A2", label: "A2 初級"),
        Option(id: "B1", label: "B1 中級"),
        Option(id: "B2", label: "B2 中高級"),
        Option(id: "C1", label: "C1 高級"),
    ]

    /// 「日文」 for "ja"; the code itself for one this list doesn't have.
    static func languageName(_ code: String) -> String {
        languages.first { $0.id == code }?.name ?? code
    }
}

@MainActor
struct OnboardingView: View {
    @Environment(ConfigStore.self) private var configStore

    @State private var extensionState: SafariExtensionState = .checking
    @State private var engineReady = false
    /// The optional section. Collapsed by default; it opens on its own only
    /// for someone who already picked an AI mode that has no working engine
    /// yet, since that's the one thing still in the way of subtitles.
    @State private var showsOptions = false
    @State private var didChooseInitialExpansion = false

    /// Unset fields read as the defaults (`effective…`); only `setPrefs`
    /// writes, and only what the user changed.
    private var prefs: SharedPrefs { configStore.config.prefs ?? SharedPrefs() }
    private var mode: SubtitleMode { SubtitleMode(rawValue: prefs.effectiveMode) ?? .netflix }
    private var needsEngine: Bool { mode.needsEngine }
    private var targetLang: String { prefs.effectiveTargetLang }
    private var level: String { prefs.effectiveAnnotateLevel }

    /// Step 2 counts as done once Netflix was opened from here
    /// (`onboardingCompleted`, which AppRouter also uses to pick the launch
    /// tab) and nothing it depends on is missing, so its check never shows
    /// while subtitles can't appear.
    private var stepDone: [Bool] {
        [extensionState.isEnabled, readyToWatch && configStore.config.onboardingCompleted]
    }

    /// The first unfinished step gets the accent badge; later ones stay gray.
    private var currentStep: Int? {
        stepDone.firstIndex(of: false).map { $0 + 1 }
    }

    /// Everything this page can check. Safari's per-site access to
    /// netflix.com isn't among them (it only reports the checkbox), so the
    /// page never promises subtitles outright; see `websiteAccessRow`.
    private var readyToWatch: Bool {
        extensionState.isEnabled && (!needsEngine || engineReady)
    }

    /// Scroll target of the AI 引擎 section. On the Section itself: an id on
    /// EngineSetupView would land on each of its rows, and scrollTo then
    /// finds none of them.
    private static let engineSectionID = "engine-setup"

    var body: some View {
        ScrollViewReader { proxy in
            form(scrollProxy: proxy)
        }
    }

    private func form(scrollProxy: ScrollViewProxy) -> some View {
        Form {
            Section {
                SafariExtensionRow(state: extensionState)
                websiteAccessRow
            } header: {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    stepHeader(1, "啟用 Safari 延伸功能")
                }
            } footer: {
                Text("在 Safari 設定的「延伸功能」勾選 MultiSub。")
            }

            Section {
                openNetflixRow(scrollProxy: scrollProxy)
            } header: {
                stepHeader(2, "打開 Netflix")
            }

            Section {
                DisclosureGroup(isExpanded: $showsOptions) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(SubtitleMode.allCases) { option in
                            ModeCard(mode: option, isSelected: mode == option) {
                                setPrefs { $0.mode = option.rawValue }
                            }
                        }
                    }
                    // Equal-height cards: each card fills the row's height, and
                    // the row is as tall as the tallest card's text.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)

                    Picker("第二語言", selection: targetLangBinding) {
                        ForEach(languageOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }

                    if mode == .annotate {
                        Picker("程度", selection: levelBinding) {
                            ForEach(SubtitleChoices.levels) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("想用 AI 翻譯或生字標註？")
                            .font(.headline)
                        Text("也可以在這裡換第二語言，目前是\(SubtitleChoices.languageName(targetLang))。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                if showsOptions {
                    Text(modeFooter)
                }
            }

            // The route to AI engine setup, part of the optional section:
            // shown with it, and only for the modes that need an engine.
            if showsOptions && needsEngine {
                Section {
                    EngineSetupView(showsLocalModelHint: true) { status in
                        engineReady = status.active != nil
                    }
                } header: {
                    Text("AI 引擎")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key 只存在這台 Mac 的鑰匙圈裡。用 API Key 時，字幕文字只會送到你選的 AI 服務。")
                        if let url = MultiSubLinks.privacyPolicy {
                            Link("隱私權政策", destination: url)
                        }
                    }
                }
                .id(Self.engineSectionID)
            }
        }
        .formStyle(.grouped)
        // The popup's mode or engine changes arrive here through
        // ConfigStore.reload() when the app becomes active.
        .onChange(of: configStore.config) { _, _ in refreshEngineReady() }
        .task {
            refreshEngineReady()
            if !didChooseInitialExpansion {
                didChooseInitialExpansion = true
                showsOptions = needsEngine && !engineReady
            }
            // Polled while the page is visible: Safari has no notification
            // for "the user ticked the checkbox", and the user flips over to
            // Safari's settings and back while this page is open.
            while !Task.isCancelled {
                extensionState = await SafariExtensionState.fetch()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    // MARK: - Pieces

    private var hero: some View {
        VStack(spacing: 14) {
            BrandLogoView(scale: 2.4)
                .padding(.bottom, 4)
            Text("歡迎使用 MultiSub")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
            // Two deliberate lines: left to wrap on its own, the second
            // sentence broke mid-word at common window widths.
            Text("在 Netflix 同時看兩種語言的字幕，或幫較難的單字標上意思。\n照著下面兩個步驟就能開始。")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    /// Content scripts only run once Safari grants access to netflix.com,
    /// which happens on Netflix itself, not in Safari's settings, and which
    /// the app can't read back. Without this a freshly enabled extension
    /// shows nothing on Netflix and looks broken.
    private var websiteAccessRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("允許 MultiSub 在 netflix.com 上執行")
                Text("第一次在 netflix.com 用 MultiSub 時，Safari 會詢問網站權限，請選「一律允許」。選「允許一天」的話，隔天就會失效。Safari 沒有詢問的話，點工具列的 MultiSub 按鈕，再按「允許存取」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
    }

    private func openNetflixRow(scrollProxy: ScrollViewProxy) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(watchSummary)
                    .fixedSize(horizontal: false, vertical: true)
                if needsEngine && !engineReady {
                    HStack(spacing: 6) {
                        Label("「\(mode.title)」需要 AI 引擎", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("設定 AI 引擎") { revealEngineSetup(scrollProxy) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button {
                openNetflix()
            } label: {
                Label("在 Safari 打開 Netflix", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }

    /// What happens on Netflix with the current settings, and where to
    /// change them. Netflix mode only has a second line where Netflix offers
    /// an official track in that language (chooseSecondTrack in content.js),
    /// so it says so here, where it's always visible.
    private var watchSummary: String {
        let language = SubtitleChoices.languageName(targetLang)
        let change = "要換語言或模式，可以在下方設定，或點 Safari 工具列的 MultiSub 按鈕。"
        switch mode {
        case .netflix:
            return "播放影片時，雙語字幕會自動出現，第二語言是\(language)。有些片沒有 Netflix 官方的\(language)字幕，這時可以改用 AI 翻譯。" + change
        case .translate:
            return "播放影片時，雙語字幕會自動出現，第二語言是\(language)。" + change
        case .annotate:
            return "播放影片時，難字後面會自動標上\(language)的意思。" + change
        }
    }

    private func stepHeader(_ number: Int, _ title: String) -> some View {
        StepHeader(number: number, title: title,
                   isDone: stepDone.indices.contains(number - 1) && stepDone[number - 1],
                   isCurrent: currentStep == number)
    }

    /// Under the mode cards. Netflix mode's caveat (no official track in the
    /// second language) is in step 2's `watchSummary`, visible with this
    /// section collapsed too.
    private var modeFooter: String { "之後隨時能從 Safari 工具列的 MultiSub 按鈕切換模式。" }

    /// The known languages, plus the saved one if the extension stored a code
    /// this list doesn't have (so the picker never holds an invalid tag).
    private var languageOptions: [SubtitleChoices.Option] {
        let known = SubtitleChoices.languages
        guard !known.contains(where: { $0.id == targetLang }) else { return known }
        return known + [SubtitleChoices.Option(id: targetLang, label: targetLang, name: targetLang)]
    }

    /// Step 2's 「設定 AI 引擎」: opens the optional section if needed and
    /// brings the engine form into view, which usually sits below the fold
    /// under the mode cards. The section only exists once `showsOptions` is
    /// on, so the scroll waits for the next main-queue turn, after that
    /// update has been laid out.
    private func revealEngineSetup(_ proxy: ScrollViewProxy) {
        showsOptions = true
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(Self.engineSectionID, anchor: .top) }
        }
    }

    private func refreshEngineReady() {
        engineReady = (try? Translator.resolveEngine(config: configStore.config)) != nil
    }

    // MARK: - Writes

    private var targetLangBinding: Binding<String> {
        Binding(get: { targetLang }, set: { newValue in setPrefs { $0.targetLang = newValue } })
    }

    private var levelBinding: Binding<String> {
        Binding(get: { level }, set: { newValue in setPrefs { $0.annotateLevel = newValue } })
    }

    /// Records an explicit choice, stamped now, so the extension adopts it on
    /// its next `ping` (newest `updatedAt` wins). Only what the user changed
    /// is written: a field still nil stays nil and keeps meaning "default",
    /// and the extension keeps its own value for a field absent from the
    /// app's prefs. So a default shown on this page can never override a
    /// choice made in the popup.
    private func setPrefs(_ change: (inout SharedPrefs) -> Void) {
        configStore.update { config in
            var prefs = config.prefs ?? SharedPrefs()
            change(&prefs)
            prefs.updatedAt = SharedPrefs.nowMs
            config.prefs = prefs
        }
    }

    private func openNetflix() {
        if !configStore.config.onboardingCompleted {
            configStore.update { $0.onboardingCompleted = true }
        }
        SafariLauncher.openNetflix()
    }
}

/// Numbered badge + step title. Done steps show a green check, the step the
/// user is on shows the accent color, and later steps stay gray.
@MainActor
private struct StepHeader: View {
    let number: Int
    let title: String
    let isDone: Bool
    let isCurrent: Bool

    private var badgeColor: Color {
        if isDone { return .green }
        return isCurrent ? .accentColor : .secondary.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(badgeColor)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(number) 步，\(title)\(isDone ? "，已完成" : "")")
        .accessibilityAddTraits(.isHeader)
    }
}

/// One selectable mode. A plain-styled Button so the whole card is the hit
/// target and keyboard focus/VoiceOver treat it as one control.
@MainActor
private struct ModeCard: View {
    let mode: SubtitleMode
    let isSelected: Bool
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: mode.symbol)
                        .font(.title2)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(height: 26)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(mode.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(mode.needsEngine ? "需要 AI 引擎" : "免設定")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(mode.needsEngine ? Color.secondary : Color.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(mode.needsEngine ? Color.secondary.opacity(0.12) : Color.green.opacity(0.14))
                    )
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                        lineWidth: isSelected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
