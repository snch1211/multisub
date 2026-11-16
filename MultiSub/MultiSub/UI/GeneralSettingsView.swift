//
//  GeneralSettingsView.swift
//  MultiSub
//
//  一般設定: Safari extension status, the AI engine (shared with onboarding),
//  local model management, a test translation through whichever engine is
//  in use, memory, and (direct builds only) software updates.
//

import AppKit
import SwiftUI

@MainActor
struct GeneralSettingsView: View {
    /// A selection or download waiting on the memory confirmation.
    private enum PendingMemoryAction {
        case select(String)
        case download(String)

        var modelID: String {
            switch self {
            case .select(let id), .download(let id): return id
            }
        }
    }

    @Environment(ConfigStore.self) private var configStore
    @Environment(ModelDownloadManager.self) private var downloadManager
    #if !APP_STORE
    // The Mac App Store build updates through the App Store and must not
    // ship a self-updater, so everything about it is compiled out there.
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(UpdateDownloadManager.self) private var updateDownloadManager
    #endif

    @State private var extensionState: SafariExtensionState = .checking

    @State private var selectedModelID = ""
    @State private var extraModelEntries: [ModelCatalogEntry] = []
    /// Measured on disk, downloaded models only. Sizes of the others come
    /// from `downloadManager.sizeEstimates` (Hugging Face).
    @State private var diskSizes: [String: Int64] = [:]
    /// Collapsed by default: the rows inside are what ask Hugging Face for
    /// sizes, and opening 一般設定 alone shouldn't contact it.
    @State private var showsDownloadableModels = false
    /// Polled periodically (see the `.task` loop below) rather than read
    /// synchronously, since `Translator` is an actor — this is a display
    /// snapshot of "which model is actually resident in memory right now",
    /// distinct from `configStore.config.modelID` ("which model the user
    /// picked"). Only the former earns the "使用中" label.
    @State private var loadedModelID: String?
    @State private var pendingMemoryAction: PendingMemoryAction?
    @State private var showForceConfirm = false
    @State private var deleteBlockedMessage = ""
    @State private var showDeleteBlocked = false

    @State private var idleUnloadMinutes = MultiSubConfig.defaultIdleUnloadMinutes

    @State private var testInput = "I can't believe you did that behind my back."
    @State private var testOutput = " "
    @State private var testRunning = false

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }

    var body: some View {
        Form {
            Section("Safari 延伸功能") {
                SafariExtensionRow(state: extensionState)
            }

            Section {
                EngineSetupView()
            } header: {
                Text("AI 引擎")
            } footer: {
                Text("「AI 翻譯雙語字幕」、「生字標註」和生詞本都用這裡的引擎。用 API Key 時，字幕文字會送到你選的 AI 服務。本機模型完全在這台 Mac 上執行。")
            }

            Section {
                // Selecting a model here only ever writes `config.json` — it
                // never starts a download itself (see `ModelDownloadManager`'s
                // doc comment for why download and selection are kept fully
                // independent). Plain Text rows, not a colored-dot Label:
                // AppKit renders a pull-down menu's item images as template
                // icons (verified by running the app — every dot came out
                // flat black regardless of the color set here), so the tier
                // signal has to live in the text itself.
                // Only models that actually work right now (downloaded,
                // whether via the picker below or dropped in manually) are
                // selectable here — an undownloaded catalog entry belongs in
                // the list below with a "下載" button, not in this picker.
                Picker("選用模型", selection: $selectedModelID) {
                    ForEach(downloadedEntries) { entry in
                        Text(rowLabel(for: entry)).tag(entry.id)
                    }
                }

                HStack {
                    Button("在 Finder 中打開模型資料夾") { openModelsFolderInFinder() }
                    Button("重新整理", systemImage: "arrow.clockwise") { refreshAll() }
                        .labelStyle(.iconOnly)
                }

                ForEach(sizeSorted(downloadedEntries)) { entry in
                    modelRow(for: entry)
                }

                let downloadable = sizeSorted(downloadableEntries)
                if !downloadable.isEmpty {
                    DisclosureGroup("可下載的模型（\(downloadable.count) 個）", isExpanded: $showsDownloadableModels) {
                        ForEach(downloadable) { entry in
                            modelRow(for: entry)
                        }
                    }
                }
            } header: {
                Text("本機模型")
            } footer: {
                Text("模型越大通常翻譯品質越好，但需要更多記憶體與下載時間。下載完成後存在本機，翻譯時不會重新下載。模型下載自 Hugging Face（MLX 格式），也可以自行在模型資料夾放入符合 MLX 格式的權重。展開「可下載的模型」或在「AI 引擎」查看還沒下載的本機模型時，才會向 Hugging Face 查詢模型大小，查到大小後才能下載。\n此裝置實體記憶體 \(ModelCatalog.formatBytes(Int64(ProcessInfo.processInfo.physicalMemory)))。紅燈表示模型磁碟大小超出建議上限（仍可強制選用），橘燈是警告。")
            }
            .alert(ModelMemoryAdvisor.confirmationTitle(sizeKnown: pendingSizeKnown), isPresented: $showForceConfirm) {
                Button(pendingIsDownload ? "仍要下載" : "仍要使用", role: .destructive) {
                    switch pendingMemoryAction {
                    case .select(let id): commitSelection(id)
                    case .download(let id): downloadManager.start(modelID: id)
                    case nil: break
                    }
                    pendingMemoryAction = nil
                }
                Button("取消", role: .cancel) { pendingMemoryAction = nil }
            } message: {
                Text(ModelMemoryAdvisor.confirmationMessage(sizeKnown: pendingSizeKnown))
            }
            .alert("無法刪除模型", isPresented: $showDeleteBlocked) {
                Button("好", role: .cancel) {}
            } message: {
                Text(deleteBlockedMessage)
            }

            Section {
                TextField("測試輸入", text: $testInput)
                Button("測試翻譯（\(testLanguageLabel)）") { runTest() }
                    .disabled(testRunning)
                LabeledContent("測試輸出") {
                    Text(testOutput)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            } header: {
                Text("測試翻譯")
            } footer: {
                Text("用目前的 AI 引擎，翻成你選的第二語言。")
            }

            Section {
                // Commit is driven entirely by `.onChange(of: idleUnloadMinutes)`
                // below — it fires on both the Stepper's taps and the
                // TextField's commit (the `value:format:` binding only
                // updates on blur/return, never per keystroke), so this
                // doesn't need its own focus-loss/onSubmit handling.
                Stepper(value: $idleUnloadMinutes, in: -1...999) {
                    TextField("閒置卸載時間（分鐘）", value: $idleUnloadMinutes, format: .number)
                }
            } header: {
                Text("記憶體")
            } footer: {
                Text("本機模型閒置超過這段時間，就會從記憶體卸載。App 與 Safari 延伸功能都適用，填 0 或負數表示不自動卸載。")
            }

            #if !APP_STORE
            Section {
                LabeledContent("目前版本") { Text(updateChecker.currentVersion) }
                StatusDot(color: updateStatusColor, text: updateStatusText)
                if let lastCheckedAt = updateChecker.lastCheckedAt {
                    Text("上次檢查：\(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("檢查更新") { Task { await updateChecker.check() } }
                        .disabled(updateChecker.status == .checking)
                    if case .updateAvailable(let version, let htmlURL, let downloadURL) = updateChecker.status,
                       !updateDownloadManager.isDownloading {
                        Button("開始更新") { startUpdate(version: version, htmlURL: htmlURL, downloadURL: downloadURL) }
                    }
                }
                if let downloadState = updateDownloadManager.state {
                    if downloadState.failed {
                        Text("下載失敗：\(downloadState.errorDescription ?? "")")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if downloadState.completedFileURL != nil {
                        Text("下載完成，已打開安裝檔。請把 App 拖進「應用程式」資料夾取代舊版，第一次打開新版時，到「系統設定 › 隱私權與安全性」選「仍要打開」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            ProgressView(value: downloadState.progress)
                            Text(downloadState.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("軟體更新")
            } footer: {
                Text("檢查更新會連線 GitHub Releases 公開 API，只帶一般 HTTP 連線資訊，不含任何個人或使用資料。")
            }
            #endif

            Section("關於") {
                LabeledContent("版本", value: Self.versionText)
                if let url = MultiSubLinks.privacyPolicy {
                    Link("隱私權政策", destination: url)
                }
                if let url = MultiSubLinks.sourceCode {
                    Link("原始碼（GitHub）", destination: url)
                }
                if let url = MultiSubLinks.issues {
                    Link("回報問題", destination: url)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: idleUnloadMinutes) { _, _ in commitIdleUnload() }
        .onChange(of: selectedModelID) { oldValue, newValue in handleModelSelection(oldValue: oldValue, newValue: newValue) }
        // Follow changes that arrive through `ConfigStore.reload()` (the app
        // becoming active) or another view, not only this view's own edits.
        .onChange(of: configStore.config.modelID) { _, newValue in selectedModelID = newValue }
        .onChange(of: configStore.config.idleUnloadMinutes) { _, newValue in idleUnloadMinutes = newValue }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from Safari's settings: show the new state right away.
            Task { extensionState = await SafariExtensionState.fetch() }
        }
        .task {
            selectedModelID = configStore.config.modelID
            idleUnloadMinutes = configStore.config.idleUnloadMinutes
            extensionState = await SafariExtensionState.fetch()
            refreshAll()
            // A download started earlier (here or from the engine row) keeps
            // its progress visible after switching tabs and back.
            if downloadableEntries.contains(where: { downloadManager.downloads[$0.id] != nil }) {
                showsDownloadableModels = true
            }
            // Lightweight periodic display refresh: picks up model files
            // that finished downloading, got deleted from Finder, or were
            // loaded/unloaded by `Translator` for reasons this view didn't
            // directly cause (idle-unload, a vocab-extraction run, etc.).
            // Disk only: Hugging Face is asked by the rows themselves.
            while !Task.isCancelled {
                await refreshLoadedModelState()
                refreshDiskSizes()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Idle-unload field commit

    /// `value:format:.number` already refuses non-numeric keystrokes and
    /// reverts a cleared field to the bound value on blur, so — unlike the
    /// old AppKit `String`-backed field — there's no separate "invalid input"
    /// case left to handle here.
    private func commitIdleUnload() {
        guard idleUnloadMinutes != configStore.config.idleUnloadMinutes else { return }
        let minutes = idleUnloadMinutes
        configStore.update { $0.idleUnloadMinutes = minutes }
    }

    // MARK: - Model management

    private var allEntries: [ModelCatalogEntry] { ModelCatalog.entries + extraModelEntries }

    /// The picker only offers models that actually work right now.
    private var downloadedEntries: [ModelCatalogEntry] {
        allEntries.filter { Translator.isModelDownloaded($0.id) }
    }

    /// The rows under 「可下載的模型」.
    private var downloadableEntries: [ModelCatalogEntry] {
        allEntries.filter { !Translator.isModelDownloaded($0.id) }
    }

    /// Smallest first; unknown sizes (still being estimated) sort last
    /// rather than arbitrarily among the known ones.
    private func sizeSorted(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        entries.sorted { (size(for: $0.id) ?? .max) < (size(for: $1.id) ?? .max) }
    }

    private func modelRow(for entry: ModelCatalogEntry) -> ModelRow {
        ModelRow(
            modelID: entry.id,
            label: rowLabel(for: entry),
            dotColor: dotColor(for: entry),
            isDownloaded: Translator.isModelDownloaded(entry.id),
            onDelete: { deleteModel(entry) },
            onDownload: { requestDownload(entry) }
        )
    }

    /// Disk size once downloaded, else the Hugging Face estimate if known.
    private func size(for modelID: String) -> Int64? {
        Translator.isModelDownloaded(modelID)
            ? diskSizes[modelID]
            : downloadManager.sizeEstimates[modelID]?.bytes
    }

    private var pendingIsDownload: Bool {
        if case .download? = pendingMemoryAction { return true }
        return false
    }

    private var pendingSizeKnown: Bool {
        pendingMemoryAction.map { size(for: $0.modelID) != nil } ?? true
    }

    /// Fires on every `selectedModelID` change, including the initial
    /// `.task`-driven assignment from `configStore.config.modelID` (a no-op
    /// here, since that's already the committed value). A blocked-tier pick
    /// reverts `selectedModelID` back to `oldValue` immediately — which
    /// re-enters this method with a no-op newValue — instead of committing;
    /// `commitSelection` runs only after the user confirms the alert.
    private func handleModelSelection(oldValue: String, newValue: String) {
        guard newValue != configStore.config.modelID else { return }
        // The picker only lists downloaded models; measure one that arrived
        // since the last poll so the decision isn't made on a missing size.
        if Translator.isModelDownloaded(newValue), diskSizes[newValue] == nil {
            diskSizes[newValue] = ModelCatalog.directorySize(modelID: newValue)
        }
        if ModelMemoryAdvisor.needsConfirmation(diskBytes: size(for: newValue)) {
            pendingMemoryAction = .select(newValue)
            showForceConfirm = true
            selectedModelID = oldValue
            return
        }
        commitSelection(newValue)
    }

    /// Selection is independent of download state by design (see
    /// `ModelDownloadManager`): this always just writes `config.json`,
    /// whether or not `id` happens to be downloaded yet.
    private func commitSelection(_ id: String) {
        selectedModelID = id
        configStore.update { $0.modelID = id }
    }

    /// The row only enables 下載 once the size is known; an unknown size
    /// still asks first rather than counting as "fits".
    private func requestDownload(_ entry: ModelCatalogEntry) {
        if ModelMemoryAdvisor.needsConfirmation(diskBytes: size(for: entry.id)) {
            pendingMemoryAction = .download(entry.id)
            showForceConfirm = true
            return
        }
        downloadManager.start(modelID: entry.id)
    }

    private func refreshLoadedModelState() async {
        loadedModelID = await Translator.shared.currentlyLoadedModelID
    }

    /// Re-scans `models/` for manually-installed extras (in case the user
    /// dropped a model in via "在 Finder 中打開模型資料夾") and force-remeasures
    /// every downloaded entry's size — the explicit "重新整理" action. The
    /// periodic `.task` loop calls `refreshDiskSizes()` (not forced) instead,
    /// since re-walking every downloaded model's directory tree with
    /// `FileManager` every 5 seconds regardless of whether anything changed
    /// would be wasted work on multi-GB model folders. With the downloadable
    /// list open, it also asks Hugging Face again for sizes that failed.
    private func refreshAll() {
        extraModelEntries = ModelCatalog.discoverExtraModels()
        refreshDiskSizes(force: true)
        if showsDownloadableModels {
            for entry in downloadableEntries where downloadManager.sizeEstimates[entry.id] == .failed {
                downloadManager.retrySizeEstimate(modelID: entry.id)
            }
        }
    }

    /// Measures downloaded models on disk (no network). `force` re-measures
    /// one whose size is already known; otherwise only entries whose
    /// downloaded state just changed do any work.
    private func refreshDiskSizes(force: Bool = false) {
        for entry in allEntries {
            guard Translator.isModelDownloaded(entry.id) else {
                // Deleted (here or in Finder): a later re-download is measured afresh.
                diskSizes[entry.id] = nil
                continue
            }
            if force || diskSizes[entry.id] == nil {
                diskSizes[entry.id] = ModelCatalog.directorySize(modelID: entry.id)
            }
        }
    }

    /// Nil while the size is unknown.
    private func tier(for modelID: String) -> ModelMemoryTier? {
        size(for: modelID).map { ModelMemoryAdvisor.tier(diskBytes: $0) }
    }

    private func dotColor(for entry: ModelCatalogEntry) -> Color {
        switch tier(for: entry.id) {
        case .blocked?: return .red
        case .warning?: return .orange
        case .ok?, nil: return Translator.isModelDownloaded(entry.id) ? .green : .secondary
        }
    }

    private func rowLabel(for entry: ModelCatalogEntry) -> String {
        var parts = [entry.displayName]
        if let size = size(for: entry.id) {
            parts.append(ModelCatalog.formatBytes(size))
        } else if Translator.isModelDownloaded(entry.id) {
            parts.append("計算大小中…")
        } else {
            parts.append(downloadManager.sizePlaceholder(for: entry.id))
        }
        switch tier(for: entry.id) {
        case .ok?, nil: break
        case .warning?: parts.append("警告")
        case .blocked?: parts.append("阻擋")
        }
        // Only a model `Translator` actually has resident in memory right
        // now earns "使用中" — `config.modelID` alone (even if its files
        // have since been deleted) only earns "已選用". Fixes the earlier
        // bug where a deleted-but-still-configured model displayed as
        // permanently "使用中" with no way to re-download it.
        if entry.id == loadedModelID {
            parts.append("使用中")
        } else if entry.id == configStore.config.modelID {
            parts.append("已選用")
        }
        return parts.joined(separator: " — ")
    }

    /// Deleting the currently-selected (`config.modelID`) entry is allowed —
    /// the guard is against pulling out a model that's actually loaded in
    /// memory or mid-request right now, not against which one `config.json`
    /// happens to name. Checked at tap time (an alert explains why, rather
    /// than a proactively-disabled button) to avoid polling `Translator`'s
    /// actor-isolated state continuously just to keep a button's enabled
    /// state current.
    private func deleteModel(_ entry: ModelCatalogEntry) {
        Task {
            if await Translator.shared.isBusy {
                deleteBlockedMessage = "此模型正在翻譯或建立生詞本，請稍後再試。"
                showDeleteBlocked = true
                return
            }
            if await Translator.shared.currentlyLoadedModelID == entry.id {
                deleteBlockedMessage = "此模型目前已載入記憶體中，請先等待閒置卸載或切換到其他模型後再刪除。"
                showDeleteBlocked = true
                return
            }
            let repoDir = "models--" + entry.id.replacingOccurrences(of: "/", with: "--")
            let root = MultiSubPaths.modelsRoot.appendingPathComponent(repoDir, isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            diskSizes[entry.id] = nil
            extraModelEntries.removeAll { $0.id == entry.id }
        }
    }

    private func openModelsFolderInFinder() {
        NSWorkspace.shared.open(MultiSubPaths.modelsRoot)
    }

    // MARK: - Software update

    #if !APP_STORE

    private var updateStatusText: String {
        switch updateChecker.status {
        case .idle: return "尚未檢查"
        case .checking: return "檢查中…"
        case .upToDate: return "已是最新版"
        case .updateAvailable(let version, _, _): return "有新版 v\(version) 可用"
        case .failed(let message): return message
        }
    }

    private var updateStatusColor: Color {
        switch updateChecker.status {
        case .idle, .checking: return .secondary
        case .upToDate: return .green
        case .updateAvailable: return .orange
        case .failed: return .red
        }
    }

    /// Downloads the release's DMG inside the app when it has one. A release
    /// published without a DMG (e.g. the upload step failed) opens the
    /// release page instead of leaving the user on a download that can never
    /// finish.
    private func startUpdate(version: String, htmlURL: URL, downloadURL: URL?) {
        guard let downloadURL else {
            NSWorkspace.shared.open(htmlURL)
            return
        }
        updateDownloadManager.start(from: downloadURL, suggestedFileName: "MultiSub-\(version).dmg")
    }
    #endif

    // MARK: - Test translation

    /// The user's second language, or the default the extension also uses.
    private var testTargetLang: String {
        (configStore.config.prefs ?? SharedPrefs()).effectiveTargetLang
    }

    private var testLanguageLabel: String {
        SubtitleChoices.languages.first { $0.id == testTargetLang }?.label ?? testTargetLang
    }

    private func runTest() {
        let text = testInput
        guard !text.isEmpty else { return }
        testRunning = true
        // Only the local engine has a slow first call (loading the model).
        if case .local(let modelID)? = try? Translator.resolveEngine(config: configStore.config),
           modelID != loadedModelID {
            testOutput = "翻譯中…（第一次要先載入模型，約 10–30 秒）"
        } else {
            testOutput = "翻譯中…"
        }

        let targetLang = testTargetLang
        Task {
            do {
                let start = Date()
                let result = try await Translator.shared.translate(lines: [text], targetLang: targetLang)
                let elapsed = Date().timeIntervalSince(start)
                testOutput = (result.first ?? "") + String(format: " （%.1f 秒）", elapsed)
                testRunning = false
                await refreshLoadedModelState()
            } catch {
                testOutput = "失敗：\(error.localizedDescription)"
                testRunning = false
            }
        }
    }
}
