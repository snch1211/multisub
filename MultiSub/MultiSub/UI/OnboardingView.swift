//
//  OnboardingView.swift
//  MultiSub
//
//  「開始使用」: one scrollable page that walks a new user from a fresh
//  install to subtitles on Netflix. Each step shows its live state (the
//  extension's enabled flag is polled while the page is visible), so the
//  page doubles as a checklist when the user comes back later to see why
//  something isn't working.
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
enum SubtitleChoices {
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
    }

    static let defaultTargetLang = "zh-TW"
    static let defaultLevel = "B1"

    static let languages: [Option] = [
        Option(id: "zh-TW", label: "繁體中文"),
        Option(id: "zh-CN", label: "简体中文"),
        Option(id: "en", label: "English"),
        Option(id: "ja", label: "日本語"),
        Option(id: "ko", label: "한국어"),
        Option(id: "es", label: "Español"),
        Option(id: "fr", label: "Français"),
        Option(id: "de", label: "Deutsch"),
        Option(id: "pt", label: "Português"),
        Option(id: "vi", label: "Tiếng Việt"),
        Option(id: "th", label: "ไทย"),
        Option(id: "id", label: "Bahasa Indonesia"),
    ]

    static let levels: [Option] = [
        Option(id: "A2", label: "A2 初級"),
        Option(id: "B1", label: "B1 中級"),
        Option(id: "B2", label: "B2 中高級"),
        Option(id: "C1", label: "C1 高級"),
    ]
}

@MainActor
struct OnboardingView: View {
    @Environment(ConfigStore.self) private var configStore

    @State private var extensionState: SafariExtensionState = .checking
    @State private var engineReady = false

    private var prefs: SharedPrefs? { configStore.config.prefs }
    private var mode: SubtitleMode? { prefs?.mode.flatMap(SubtitleMode.init(rawValue:)) }
    private var needsEngine: Bool { mode?.needsEngine ?? false }
    private var targetLang: String { prefs?.targetLang ?? SubtitleChoices.defaultTargetLang }
    private var level: String { prefs?.annotateLevel ?? SubtitleChoices.defaultLevel }

    /// The last step counts as done only when the steps before it are, so
    /// its check never sits above 「還有步驟沒完成」. `onboardingCompleted`
    /// alone just means the button was pressed once (AppRouter uses it to
    /// pick the launch tab).
    private var stepDone: [Bool] {
        var steps = [extensionState.isEnabled, mode != nil]
        if needsEngine { steps.append(engineReady) }
        steps.append(readyToWatch && configStore.config.onboardingCompleted)
        return steps
    }

    /// The first unfinished step gets the accent badge; later ones stay gray.
    private var currentStep: Int? {
        stepDone.firstIndex(of: false).map { $0 + 1 }
    }

    /// Everything this page can check. Safari's per-site access to
    /// netflix.com isn't among them (it only reports the checkbox), so the
    /// page never promises subtitles outright; see `websiteAccessRow`.
    private var readyToWatch: Bool {
        extensionState.isEnabled && mode != nil && (!needsEngine || engineReady)
    }

    var body: some View {
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
            } header: {
                stepHeader(2, "選擇字幕模式")
            } footer: {
                Text(modeFooter)
            }

            if needsEngine {
                Section {
                    EngineSetupView(showsLocalModelHint: true) { status in
                        engineReady = status.active != nil
                    }
                } header: {
                    stepHeader(3, "設定 AI 引擎")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key 只存在這台 Mac 的鑰匙圈裡。用 API Key 時，字幕文字只會送到你選的 AI 服務。")
                        if let url = MultiSubLinks.privacyPolicy {
                            Link("隱私權政策", destination: url)
                        }
                    }
                }
            }

            Section {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(readyToWatch ? "這頁的步驟都完成了" : "還有步驟沒完成")
                            .font(.headline)
                        Text(readyToWatch
                             ? "打開任一部影片試試。字幕沒出現的話，點 Safari 工具列的 MultiSub 按鈕，允許存取 netflix.com。之後也可以從這個按鈕切換模式。"
                             : "也可以先打開 Netflix 看看，之後再回來這裡完成設定。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        finish()
                    } label: {
                        Label("在 Safari 開啟 Netflix", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.vertical, 4)
            } header: {
                stepHeader(needsEngine ? 4 : 3, "完成")
            }
        }
        .formStyle(.grouped)
        .task {
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
            Text("在 Netflix 同時看兩種語言的字幕，或幫較難的單字標上意思。\n照著下面幾步設定就能開始。")
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

    private func stepHeader(_ number: Int, _ title: String) -> some View {
        StepHeader(number: number, title: title,
                   isDone: stepDone.indices.contains(number - 1) && stepDone[number - 1],
                   isCurrent: currentStep == number)
    }

    private var modeFooter: String {
        switch mode {
        case .netflix?: return "片子沒有你選的第二語言字幕時，可以改用 AI 翻譯。之後隨時能從 Safari 工具列的 MultiSub 按鈕切換模式。"
        case .some: return "之後隨時能從 Safari 工具列的 MultiSub 按鈕切換模式。"
        case nil: return "選一種模式，之後隨時能從 Safari 工具列的 MultiSub 按鈕切換。"
        }
    }

    /// The known languages, plus the saved one if the extension stored a code
    /// this list doesn't have (so the picker never holds an invalid tag).
    private var languageOptions: [SubtitleChoices.Option] {
        let known = SubtitleChoices.languages
        guard !known.contains(where: { $0.id == targetLang }) else { return known }
        return known + [SubtitleChoices.Option(id: targetLang, label: targetLang)]
    }

    // MARK: - Writes

    private var targetLangBinding: Binding<String> {
        Binding(get: { targetLang }, set: { newValue in setPrefs { $0.targetLang = newValue } })
    }

    private var levelBinding: Binding<String> {
        Binding(get: { level }, set: { newValue in setPrefs { $0.annotateLevel = newValue } })
    }

    /// Writes a complete prefs set stamped now, so the extension adopts it on
    /// its next `ping` (newest `updatedAt` wins). Unset fields are filled with
    /// what the page shows, so the extension never adopts a half-empty set.
    private func setPrefs(_ change: (inout SharedPrefs) -> Void) {
        configStore.update { config in
            var prefs = config.prefs ?? SharedPrefs()
            change(&prefs)
            if prefs.targetLang == nil { prefs.targetLang = SubtitleChoices.defaultTargetLang }
            if prefs.annotateLevel == nil { prefs.annotateLevel = SubtitleChoices.defaultLevel }
            prefs.updatedAt = SharedPrefs.nowMs
            config.prefs = prefs
        }
    }

    private func finish() {
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
