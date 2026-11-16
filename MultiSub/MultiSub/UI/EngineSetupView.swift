//
//  EngineSetupView.swift
//  MultiSub
//
//  AI engine settings, shared by the onboarding page (step ③) and 一般設定.
//  Its body is a group of Form rows, so the caller decides the Section and
//  header around it and both places get the native grouped-form look.
//
//  The cloud half is a draft: picking a provider, model or key changes
//  nothing until 「儲存並測試」. That first sends one fixed test sentence
//  with exactly what was typed (a client built from the draft, nothing
//  saved yet), and only when it answers saves the key to the shared
//  keychain and the engine to config.json. A typo in the key therefore
//  leaves whatever engine worked before in place, and the user finds out
//  right away instead of on their first episode.
//
//  The first save for a provider also asks, by name, whether subtitle text
//  may be sent there from this Mac (App Review 5.1.2(i)); the answer is
//  recorded in `config.cloudConsent`, without which `Translator` won't use
//  that provider at all.
//

import SwiftUI

/// Which half of the engine settings the segmented control shows.
enum EngineSetupTab: Hashable {
    case cloud, local
}

/// What 「儲存並測試」 is about to test and, if the test passes, save.
private struct CloudCandidate: Equatable {
    let provider: CloudProvider
    /// "" means the provider's default (see `modelToStore`).
    let model: String
    let baseURL: String
    /// Empty when the user kept the saved key.
    let typedKey: String

    var settings: CloudSettings { CloudSettings(provider: provider, model: model, baseURL: baseURL) }
}

/// The line under the engine controls.
private enum EngineFeedback: Equatable {
    case running(String)
    case success(String, detail: String?)
    case info(String)
    case failure(String)
}

@MainActor
struct EngineSetupView: View {
    /// Picker tag for "type a model id yourself".
    private static let otherModelTag = "__other__"

    @Environment(ConfigStore.self) private var configStore
    @Environment(ModelDownloadManager.self) private var downloadManager
    @Environment(AppRouter.self) private var router

    /// The onboarding page shows a pointer to 一般設定 for other model sizes;
    /// 一般設定 itself lists them right below.
    private let showsLocalModelHint: Bool
    /// Called with every fresh status read, so the onboarding page can tick
    /// its step without reading the keychain itself.
    private let onStatusChange: ((EngineStatus) -> Void)?

    @State private var tab: EngineSetupTab = .cloud
    @State private var didChooseInitialTab = false
    @State private var didLoadDraft = false
    @State private var status: EngineStatus?
    @State private var feedback: EngineFeedback?

    // Cloud draft.
    @State private var provider: CloudProvider = .anthropic
    @State private var modelChoice = ""
    @State private var customModel = ""
    @State private var baseURL = ""
    @State private var keyDraft = ""
    @State private var hasSavedKey = false
    @State private var replacingKey = false
    @State private var fullModelList: [String]?
    @State private var loadingModels = false
    @State private var showRemoveKeyConfirm = false
    /// Waiting on the consent alert.
    @State private var pendingConsent: CloudCandidate?
    /// Providers the user agreed to in this view whose save hasn't gone
    /// through yet (the test failed), so fixing a typo and retrying doesn't
    /// ask again. The lasting record is `config.cloudConsent`, written only
    /// together with a successful save.
    @State private var consentGiven: Set<CloudProvider> = []
    /// The saved provider has a key (or a custom server) but no recorded
    /// consent, which is why nothing is active. Read from the keychain in
    /// `refreshStatus`, not on every render.
    @State private var savedProviderAwaitingConsent: CloudProvider?

    /// Measured on disk once downloaded; before that the size comes from
    /// `downloadManager.sizeEstimates`.
    @State private var localDiskSize: Int64?
    @State private var showLocalDownloadConfirm = false

    init(showsLocalModelHint: Bool = false, onStatusChange: ((EngineStatus) -> Void)? = nil) {
        self.showsLocalModelHint = showsLocalModelHint
        self.onStatusChange = onStatusChange
    }

    var body: some View {
        Group {
            statusRow
            Picker("設定方式", selection: $tab) {
                Text("API Key（推薦，免下載）").tag(EngineSetupTab.cloud)
                Text("本機模型（離線）").tag(EngineSetupTab.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            switch tab {
            case .cloud: cloudRows
            case .local: localRows
            }

            if let feedback {
                FeedbackRow(feedback: feedback)
            }
        }
    }

    // MARK: - Status

    /// Lifecycle modifiers live on this always-present row instead of on the
    /// Group: a modifier on a Group is applied to every child, which would
    /// run each task once per row. A grouped Form can also unload a row that
    /// scrolls out of view and run its `.task` again when it comes back, so
    /// the task only does what is safe to repeat (the draft loads once), and
    /// nothing that must happen relies on this row's `onChange` (see
    /// `startLocalDownload`).
    private var statusRow: some View {
        LabeledContent("目前使用") {
            StatusDot(color: status?.active == nil ? .orange : .green, text: statusText)
                .foregroundStyle(status?.active == nil ? .secondary : .primary)
        }
        .task {
            if !didLoadDraft {
                didLoadDraft = true
                loadDraft(from: configStore.config.cloud)
            }
            consumeRequestedTab()
            await refreshStatus()
            if !didChooseInitialTab {
                didChooseInitialTab = true
                tab = initialTab()
            }
        }
        // Disk only. The Hugging Face estimate is asked for by the local
        // model row itself, so it isn't fetched while the cloud half is shown.
        .task(id: localModelID) { measureLocalModel() }
        .onChange(of: configStore.config) { oldValue, newValue in
            // The popup's `set-engine` or our own save; adopt the saved cloud
            // settings unless the user is in the middle of typing a key.
            if oldValue.cloud != newValue.cloud, keyDraft.isEmpty { loadDraft(from: newValue.cloud) }
            Task { await refreshStatus() }
        }
        .onChange(of: router.requestedEngineTab) { _, _ in consumeRequestedTab() }
        .onChange(of: tab) { _, _ in feedback = nil }
        .onChange(of: downloadManager.isDownloading(localModelID)) { wasDownloading, isDownloading in
            // Display only: the downloaded size and the status line.
            guard wasDownloading, !isDownloading, Translator.isModelDownloaded(localModelID) else { return }
            measureLocalModel()
            Task { await refreshStatus() }
        }
    }

    private var statusText: String {
        guard let status else { return "檢查中…" }
        switch status.active {
        case "cloud":
            return "\(status.providerName) · \(status.model)"
        case "local":
            return "本機模型 · \(ModelCatalog.displayName(for: status.localModelId))"
        default:
            if status.configured != .local, let provider = savedProviderAwaitingConsent {
                return "還沒同意把字幕送到 \(provider.consentRecipient)，按「儲存並測試」確認"
            }
            switch status.configured {
            case .local: return "本機模型還沒下載"
            case .cloud: return "API Key 還沒設定好"
            case .auto: return "尚未設定"
            }
        }
    }

    private func refreshStatus() async {
        let config = configStore.config
        let fresh = await Translator.engineStatus(config: config)
        status = fresh
        hasSavedKey = SecretStore.hasAPIKey(for: provider)
        // Someone who saved a key before consent existed (or through an
        // older popup) sees why it isn't used instead of "not set up".
        let saved = config.cloud
        savedProviderAwaitingConsent = fresh.active == nil
            && !config.hasCloudConsent(for: saved.provider)
            && Translator.cloudClient(for: saved) != nil
            ? saved.provider : nil
        onStatusChange?(fresh)
    }

    /// Opens on whatever is in use, else on the recommended API Key half.
    private func initialTab() -> EngineSetupTab {
        if let active = status?.active { return active == "local" ? .local : .cloud }
        if configStore.config.engine == .local { return .local }
        return .cloud
    }

    private func consumeRequestedTab() {
        guard let requested = router.requestedEngineTab else { return }
        router.requestedEngineTab = nil
        tab = requested
        didChooseInitialTab = true
    }

    private var isBusy: Bool {
        if loadingModels { return true }
        if case .running = feedback { return true }
        return false
    }

    // MARK: - Cloud

    @ViewBuilder
    private var cloudRows: some View {
        Picker("AI 服務", selection: providerBinding) {
            ForEach(CloudProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }

        if provider.needsBaseURL {
            // `verbatim:` so the example URL isn't rendered as a Markdown link.
            TextField("API 網址", text: $baseURL, prompt: Text(verbatim: "http://localhost:1234/v1"))
        }

        keyRow

        LabeledContent("模型") {
            HStack(spacing: 8) {
                Picker("模型", selection: $modelChoice) {
                    ForEach(provider.recommended) { option in
                        Text("\(option.id) · \(option.label)").tag(option.id)
                    }
                    if !extraModels.isEmpty {
                        Divider()
                        ForEach(extraModels, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    Divider()
                    Text("其他…").tag(Self.otherModelTag)
                }
                .labelsHidden()
                .fixedSize()
                Button("載入完整清單") { loadFullModelList() }
                    .disabled(isBusy)
            }
        }

        if modelChoice == Self.otherModelTag {
            TextField("模型 ID", text: $customModel,
                      prompt: Text(provider == .custom ? "例如 qwen3-8b" : provider.defaultModel))
        }

        // The privacy policy promises the provider is named before any
        // subtitle text goes to it.
        Text(sendDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        HStack {
            if let keyURL = provider.keyURL, !hasSavedKey || replacingKey {
                Link(destination: keyURL) {
                    Label("取得 API Key", systemImage: "arrow.up.forward.square")
                }
            }
            Spacer()
            Button("儲存並測試") { saveAndTest() }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
        }
        .alert(consentTitle, isPresented: consentAlertShown, presenting: pendingConsent) { candidate in
            Button("同意並測試") {
                consentGiven.insert(candidate.provider)
                testThenSave(candidate)
            }
            Button("取消", role: .cancel) {}
        } message: { candidate in
            Text(consentMessage(for: candidate))
        }
    }

    private var sendDisclosure: String {
        "儲存後，要翻譯或標註的字幕文字會從這台 Mac 直接送到 \(provider.consentRecipient)，不經過 MultiSub。"
    }

    private var consentAlertShown: Binding<Bool> {
        Binding(get: { pendingConsent != nil }, set: { if !$0 { pendingConsent = nil } })
    }

    private var consentTitle: String {
        "把字幕文字送到 \(pendingConsent?.provider.consentRecipient ?? provider.consentRecipient)？"
    }

    /// Names the recipient again (with the address itself for a custom
    /// server), since this is the one place the user agrees to it.
    private func consentMessage(for candidate: CloudCandidate) -> String {
        let recipient = candidate.provider == .custom
            ? "你填的 API 網址（\(candidate.baseURL)）"
            : candidate.provider.consentRecipient
        var message = "之後翻譯或標註時，字幕文字會從這台 Mac 直接送到 \(recipient)，不經過 MultiSub。"
        if candidate.provider != .custom {
            message += "資料怎麼處理，以這個服務的隱私權政策為準。"
        }
        message += "\n\n同意後會先送一句固定的測試句，測試成功才會儲存。"
        return message
    }

    @ViewBuilder
    private var keyRow: some View {
        if hasSavedKey && !replacingKey {
            LabeledContent("API Key") {
                HStack(spacing: 12) {
                    // Never shows the saved key, not even masked: knowing it
                    // exists is all the UI needs.
                    StatusDot(color: .green, text: "已儲存")
                    Button("更換") { replacingKey = true }
                    Button("移除", role: .destructive) { showRemoveKeyConfirm = true }
                }
            }
            .confirmationDialog("移除 \(provider.displayName) 的 API Key？", isPresented: $showRemoveKeyConfirm) {
                Button("移除", role: .destructive) { removeKey() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("移除後要重新貼上，才能再用這個 AI 服務。")
            }
        } else {
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    SecureField("API Key", text: $keyDraft, prompt: Text(provider.keyPlaceholder))
                        .labelsHidden()
                    if replacingKey {
                        Button("取消") {
                            replacingKey = false
                            keyDraft = ""
                        }
                    }
                }
            }
        }
    }

    /// Fetched ids that aren't already in the recommended list.
    private var extraModels: [String] {
        guard let fullModelList else { return [] }
        let recommended = Set(provider.recommended.map(\.id))
        return fullModelList.filter { !recommended.contains($0) }
    }

    /// Switching provider goes through here rather than `.onChange(of:)`,
    /// so `loadDraft` can set provider and model together without this reset
    /// firing afterwards and throwing the loaded model away.
    private var providerBinding: Binding<CloudProvider> {
        Binding(
            get: { provider },
            set: { newProvider in
                guard newProvider != provider else { return }
                let saved = configStore.config.cloud
                provider = newProvider
                keyDraft = ""
                replacingKey = false
                fullModelList = nil
                feedback = nil
                hasSavedKey = SecretStore.hasAPIKey(for: newProvider)
                if newProvider == saved.provider {
                    loadDraft(from: saved)
                } else {
                    setModelDraft("", for: newProvider)
                }
            }
        )
    }

    private func loadDraft(from settings: CloudSettings) {
        provider = settings.provider
        baseURL = settings.baseURL
        setModelDraft(settings.model, for: settings.provider)
        hasSavedKey = SecretStore.hasAPIKey(for: settings.provider)
    }

    /// An empty `model` means the provider's default.
    private func setModelDraft(_ model: String, for provider: CloudProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? provider.defaultModel : trimmed
        if provider.recommended.contains(where: { $0.id == effective }) {
            modelChoice = effective
            customModel = ""
        } else {
            modelChoice = Self.otherModelTag
            customModel = effective
        }
    }

    /// What to store in `config.cloud.model`. The provider default is stored
    /// as "" so a later app version's better default applies automatically.
    private var modelToStore: String {
        let chosen = modelChoice == Self.otherModelTag
            ? customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : modelChoice
        return chosen == provider.defaultModel ? "" : chosen
    }

    private func saveAndTest() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelToStore

        if provider.needsBaseURL && trimmedBaseURL.isEmpty {
            feedback = .failure("請輸入 API 網址。")
            return
        }
        if model.isEmpty && provider.defaultModel.isEmpty {
            feedback = .failure("請輸入模型 ID。")
            return
        }
        if provider.keyRequired && key.isEmpty && !hasSavedKey {
            feedback = .failure("請先貼上 API Key。")
            return
        }

        let candidate = CloudCandidate(provider: provider, model: model,
                                       baseURL: provider.needsBaseURL ? trimmedBaseURL : "",
                                       typedKey: key)
        if configStore.config.hasCloudConsent(for: provider) || consentGiven.contains(provider) {
            testThenSave(candidate)
        } else {
            pendingConsent = candidate
        }
    }

    /// Tests the candidate with a client of its own, then saves key, engine,
    /// settings and consent together. Nothing is written before the test
    /// passes, so a failure leaves the previous engine exactly as it was.
    private func testThenSave(_ candidate: CloudCandidate) {
        let key = candidate.typedKey.isEmpty ? SecretStore.apiKey(for: candidate.provider) : candidate.typedKey
        let client = CloudLLMClient(provider: candidate.provider, model: candidate.model,
                                    baseURL: candidate.baseURL, apiKey: key)
        feedback = .running("測試中…")
        Task {
            let result: (latencyMs: Int, sample: String)
            do {
                result = try await Translator.testEngine(client: client)
            } catch {
                feedback = .failure(error.localizedDescription + "\n設定沒有儲存。")
                await refreshStatus()
                return
            }

            if !candidate.typedKey.isEmpty {
                do {
                    try SecretStore.setAPIKey(candidate.typedKey, for: candidate.provider)
                } catch {
                    feedback = .failure(error.localizedDescription)
                    return
                }
                // The user may have switched provider while the test ran;
                // that draft isn't theirs to clear.
                if provider == candidate.provider {
                    keyDraft = ""
                    replacingKey = false
                }
            }
            configStore.update {
                $0.engine = .cloud
                $0.cloud = candidate.settings
                if !$0.hasCloudConsent(for: candidate.provider) {
                    $0.recordCloudConsent(for: candidate.provider)
                }
            }
            consentGiven.remove(candidate.provider)
            let seconds = String(format: "%.1f", Double(result.latencyMs) / 1000)
            feedback = .success("已儲存，可以用了，回應時間 \(seconds) 秒", detail: "「\(result.sample)」")
            await refreshStatus()
        }
    }

    private func removeKey() {
        SecretStore.deleteAPIKey(for: provider)
        hasSavedKey = false
        replacingKey = false
        feedback = nil
        Task { await refreshStatus() }
    }

    private func loadFullModelList() {
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? SecretStore.apiKey(for: provider) : typed
        if provider.keyRequired && (key ?? "").isEmpty {
            feedback = .failure("先貼上 API Key，才能載入模型清單。")
            return
        }
        if provider.needsBaseURL && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            feedback = .failure("請先輸入 API 網址。")
            return
        }
        let requestedProvider = provider
        let client = CloudLLMClient(provider: provider, model: "", baseURL: baseURL, apiKey: key)
        loadingModels = true
        feedback = .running("載入模型清單…")
        Task {
            defer { loadingModels = false }
            do {
                let ids = try await client.listModels()
                // The user may have switched provider while this was loading.
                guard requestedProvider == provider else { return }
                fullModelList = ids
                feedback = .info("找到 \(ids.count) 個模型，已加進選單。")
            } catch {
                guard requestedProvider == provider else { return }
                feedback = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - Local

    private var localModelID: String { configStore.config.modelID }

    @ViewBuilder
    private var localRows: some View {
        Text("在這台 Mac 上用 Gemma 模型翻譯，不需要網路，也不用 API Key。模型只要下載一次。")
            .font(.callout)
            .foregroundStyle(.secondary)

        ModelRow(
            modelID: localModelID,
            label: localModelLabel,
            dotColor: localDotColor,
            isDownloaded: Translator.isModelDownloaded(localModelID),
            onDelete: nil,
            onDownload: { requestLocalDownload() }
        )
        .alert(ModelMemoryAdvisor.confirmationTitle(sizeKnown: localModelSize != nil),
               isPresented: $showLocalDownloadConfirm) {
            Button("仍要下載", role: .destructive) { startLocalDownload() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(ModelMemoryAdvisor.confirmationMessage(sizeKnown: localModelSize != nil))
        }

        if Translator.isModelDownloaded(localModelID) {
            HStack {
                Spacer()
                // From what actually runs, not `config.engine`: under auto
                // with no key the local model is already in use, and
                // offering to switch to it would contradict the status row.
                Button(localIsActive ? "測試本機模型" : "改用本機模型並測試") {
                    useLocalAndTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }

        if showsLocalModelHint {
            Text("想換其他大小的模型，可以到「一般設定」的「本機模型」下載。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var localIsActive: Bool { status?.active == "local" }

    /// Disk size once downloaded, else the Hugging Face estimate if known.
    private var localModelSize: Int64? {
        Translator.isModelDownloaded(localModelID)
            ? localDiskSize
            : downloadManager.sizeEstimates[localModelID]?.bytes
    }

    private var localModelLabel: String {
        let name = ModelCatalog.displayName(for: localModelID)
        if let localModelSize { return "\(name) · \(ModelCatalog.formatBytes(localModelSize))" }
        if Translator.isModelDownloaded(localModelID) { return name }
        return "\(name) · \(downloadManager.sizePlaceholder(for: localModelID))"
    }

    private var localDotColor: Color {
        if let localModelSize {
            switch ModelMemoryAdvisor.tier(diskBytes: localModelSize) {
            case .blocked: return .red
            case .warning: return .orange
            case .ok: break
            }
        }
        return Translator.isModelDownloaded(localModelID) ? .green : .secondary
    }

    private func measureLocalModel() {
        localDiskSize = Translator.isModelDownloaded(localModelID)
            ? ModelCatalog.directorySize(modelID: localModelID)
            : nil
    }

    /// The row enables 下載 only once the size is known; a model too big
    /// for this Mac (or, defensively, of unknown size) asks first, the same
    /// way 一般設定 does. The configured model is usually the small default,
    /// but it can be any size picked in 一般設定 and deleted since.
    private func requestLocalDownload() {
        if ModelMemoryAdvisor.needsConfirmation(diskBytes: localModelSize) {
            showLocalDownloadConfirm = true
        } else {
            startLocalDownload()
        }
    }

    /// Downloading the model from here means "use it": once the files are
    /// in, the engine switches to local, unless the engine setting changed
    /// while it downloaded (e.g. the user saved an API key meanwhile), which
    /// is the newer decision.
    private func startLocalDownload() {
        let store = configStore
        let engineAtStart = store.config.engine
        downloadManager.start(modelID: localModelID) {
            store.reload()
            guard store.config.engine == engineAtStart, engineAtStart != .local else { return }
            store.update { $0.engine = .local }
        }
    }

    private func useLocalAndTest() {
        // Already running locally (e.g. auto without a key): just test, and
        // leave auto alone so a key saved later still takes over.
        if !localIsActive, configStore.config.engine != .local {
            configStore.update { $0.engine = .local }
        }
        // Only the first run is slow; later runs reuse the loaded model.
        runTest(note: "載入模型並測試中，第一次約需 10–30 秒…")
    }

    // MARK: - Test

    private func runTest(note: String) {
        feedback = .running(note)
        Task {
            do {
                let result = try await Translator.shared.testEngine()
                let seconds = String(format: "%.1f", Double(result.latencyMs) / 1000)
                feedback = .success("可以用了，回應時間 \(seconds) 秒", detail: "「\(result.sample)」")
            } catch {
                feedback = .failure(error.localizedDescription)
            }
            await refreshStatus()
        }
    }
}

/// The line under the engine controls: progress, a test result or an error.
@MainActor
private struct FeedbackRow: View {
    let feedback: EngineFeedback

    var body: some View {
        switch feedback {
        case .running(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .foregroundStyle(.secondary)
            }
        case .success(let title, let detail):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .info(let text):
            Label(text, systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .failure(let text):
            Label {
                Text(text)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}
