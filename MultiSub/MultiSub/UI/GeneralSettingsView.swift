//
//  GeneralSettingsView.swift
//  MultiSub
//
//  Style guide v2 §5.1. Behavior ported from ViewController.buildGeneralTab()
//  and its neighboring methods (refreshExtensionStatus/refreshModelStatus/
//  downloadModel/runTest/controlTextDidEndEditing) — see PLAN.md G2.
//

import AppKit
import SafariServices
import SwiftUI

let extensionBundleIdentifier = "com.seanhuang.multisub.Extension"

@MainActor
struct GeneralSettingsView: View {
    private enum PendingBlockedAction {
        case select(String)
        case download(String)
    }

    @Environment(ConfigStore.self) private var configStore
    @Environment(ModelDownloadManager.self) private var downloadManager
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(UpdateDownloadManager.self) private var updateDownloadManager

    @State private var extensionStatusText = "檢查中…"
    @State private var extensionStatusColor = Color.secondary

    @State private var selectedModelID = ""
    @State private var extraModelEntries: [ModelCatalogEntry] = []
    @State private var modelSizes: [String: Int64] = [:]
    @State private var sizesLoading: Set<String> = []
    /// Polled periodically (see the `.task` loop below) rather than read
    /// synchronously, since `Translator` is an actor — this is a display
    /// snapshot of "which model is actually resident in memory right now",
    /// distinct from `configStore.config.modelID` ("which model the user
    /// picked"). Only the former earns the "使用中" label.
    @State private var loadedModelID: String?
    @State private var pendingBlockedAction: PendingBlockedAction?
    @State private var showForceConfirm = false
    @State private var deleteBlockedMessage = ""
    @State private var showDeleteBlocked = false

    @State private var idleUnloadMinutes = MultiSubConfig.defaultIdleUnloadMinutes

    @State private var testInput = "I can't believe you did that behind my back."
    @State private var testOutput = " "
    @State private var testRunning = false

    var body: some View {
        Form {
            Section("Safari 擴充功能") {
                StatusDot(color: extensionStatusColor, text: extensionStatusText)
                Button("開啟 Safari 擴充功能設定") { openSafariPreferences() }
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
                Picker("翻譯模型", selection: $selectedModelID) {
                    ForEach(downloadedEntries) { entry in
                        Text(rowLabel(for: entry)).tag(entry.id)
                    }
                }

                HStack {
                    Button("在 Finder 中打開模型資料夾") { openModelsFolderInFinder() }
                    Button("重新整理", systemImage: "arrow.clockwise") { refreshAll() }
                        .labelStyle(.iconOnly)
                }

                ForEach(sizeSortedEntries) { entry in
                    ModelRow(
                        label: rowLabel(for: entry),
                        dotColor: dotColor(for: entry),
                        downloadState: downloadManager.downloads[entry.id],
                        isDownloading: downloadManager.isDownloading(entry.id),
                        isDownloaded: Translator.isModelDownloaded(entry.id),
                        onDelete: { deleteModel(entry) },
                        onDownload: { requestDownload(entry) }
                    )
                }
            } header: {
                Text("模型")
            } footer: {
                Text("模型越大通常翻譯品質越好，但需要更多記憶體與下載時間；下載完成後即存在本機，翻譯時不會重新下載。模型下載自 Hugging Face（MLX 格式），也可以自行在模型資料夾放入符合 MLX 格式的權重。\n此裝置實體記憶體 \(Self.formatBytes(Int64(ProcessInfo.processInfo.physicalMemory)))；紅燈表示模型磁碟大小超出建議上限（可強制選用），橘燈為警告。")
            }
            .alert("此模型可能超出裝置記憶體", isPresented: $showForceConfirm) {
                Button("仍要使用", role: .destructive) {
                    switch pendingBlockedAction {
                    case .select(let id): commitSelection(id)
                    case .download(let id): downloadManager.start(modelID: id)
                    case nil: break
                    }
                    pendingBlockedAction = nil
                }
                Button("取消", role: .cancel) { pendingBlockedAction = nil }
            } message: {
                Text("此模型磁碟大小換算約超過裝置實體記憶體的 \(Int(ModelMemoryAdvisor.blockedRatio * 100))%，載入可能導致系統記憶體吃緊或當機。")
            }
            .alert("無法刪除模型", isPresented: $showDeleteBlocked) {
                Button("好", role: .cancel) {}
            } message: {
                Text(deleteBlockedMessage)
            }

            Section("測試翻譯") {
                TextField("測試輸入", text: $testInput)
                Button("測試翻譯（繁中）") { runTest() }
                    .disabled(testRunning)
                LabeledContent("測試輸出") {
                    Text(testOutput)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
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
                Text("翻譯閒置超過此時間會自動釋放模型記憶體；App 與 Safari 擴充功能皆適用；0 或負數停用")
            }

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
                        Text("下載完成，已開啟安裝檔——請將 App 拖進「應用程式」資料夾取代舊版；首次開啟新版需在「系統設定 › 隱私權與安全性」選擇「仍要打開」")
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
                Text("檢查更新會連線 GitHub Releases 公開 API（僅一般 HTTP 連線資訊，不含任何個人或使用資料）；翻譯功能仍完全在本機執行。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: idleUnloadMinutes) { _, _ in commitIdleUnload() }
        .onChange(of: selectedModelID) { oldValue, newValue in handleModelSelection(oldValue: oldValue, newValue: newValue) }
        .task {
            selectedModelID = configStore.config.modelID
            idleUnloadMinutes = configStore.config.idleUnloadMinutes
            refreshExtensionStatus()
            refreshAll()
            // Lightweight periodic display refresh: picks up model files
            // that finished downloading, got deleted from Finder, or were
            // loaded/unloaded by `Translator` for reasons this view didn't
            // directly cause (idle-unload, a vocab-extraction run, etc.).
            while !Task.isCancelled {
                await refreshLoadedModelState()
                refreshModelSizes()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Safari extension status

    private func refreshExtensionStatus() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionBundleIdentifier) { state, error in
            Task { @MainActor in
                if let state {
                    if state.isEnabled {
                        extensionStatusText = "已啟用"
                        extensionStatusColor = .green
                    } else {
                        extensionStatusText = "未啟用 — 請在 Safari 設定中開啟"
                        extensionStatusColor = .orange
                    }
                } else {
                    extensionStatusText = "無法取得（\(error?.localizedDescription ?? "unknown")）"
                    extensionStatusColor = .red
                }
            }
        }
    }

    private func openSafariPreferences() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleIdentifier) { _ in }
    }

    // MARK: - Idle-unload field commit

    /// `value:format:.number` already refuses non-numeric keystrokes and
    /// reverts a cleared field to the bound value on blur, so — unlike the
    /// old AppKit `String`-backed field — there's no separate "invalid input"
    /// case left to handle here.
    private func commitIdleUnload() {
        guard idleUnloadMinutes != configStore.config.idleUnloadMinutes else { return }
        configStore.config.idleUnloadMinutes = idleUnloadMinutes
        configStore.save()
    }

    // MARK: - Model management

    private var allEntries: [ModelCatalogEntry] { ModelCatalog.entries + extraModelEntries }

    /// The picker only offers models that actually work right now.
    private var downloadedEntries: [ModelCatalogEntry] {
        allEntries.filter { Translator.isModelDownloaded($0.id) }
    }

    /// The row list below, smallest first; unknown sizes (still being
    /// estimated) sort last rather than arbitrarily among the known ones.
    private var sizeSortedEntries: [ModelCatalogEntry] {
        allEntries.sorted { (modelSizes[$0.id] ?? .max) < (modelSizes[$1.id] ?? .max) }
    }

    /// Fires on every `selectedModelID` change, including the initial
    /// `.task`-driven assignment from `configStore.config.modelID` (a no-op
    /// here, since that's already the committed value). A blocked-tier pick
    /// reverts `selectedModelID` back to `oldValue` immediately — which
    /// re-enters this method with a no-op newValue — instead of committing;
    /// `commitSelection` runs only after the user confirms the alert.
    private func handleModelSelection(oldValue: String, newValue: String) {
        guard newValue != configStore.config.modelID else { return }
        if tier(for: newValue) == .blocked {
            pendingBlockedAction = .select(newValue)
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
        configStore.config.modelID = id
        configStore.save()
    }

    private func requestDownload(_ entry: ModelCatalogEntry) {
        if tier(for: entry.id) == .blocked {
            pendingBlockedAction = .download(entry.id)
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
    /// periodic `.task` loop calls `refreshModelSizes()` (not forced) instead,
    /// since re-walking every downloaded model's directory tree with
    /// `FileManager` every 5 seconds regardless of whether anything changed
    /// would be wasted work on multi-GB model folders.
    private func refreshAll() {
        extraModelEntries = ModelCatalog.discoverExtraModels()
        refreshModelSizes(force: true)
    }

    /// Kicks off size lookups for every catalog + manually-discovered entry:
    /// measured from disk for already-downloaded models, or (S1's existing
    /// `listFiles`-based size, no network download) estimated for the rest —
    /// needed up front so the list can show a memory-tier light without
    /// waiting for a selection. `force` re-measures a downloaded entry even
    /// if a size is already cached (used by the explicit "重新整理" action);
    /// otherwise an already-known size is left alone, so the periodic poll
    /// only does real work for entries whose downloaded state just changed.
    private func refreshModelSizes(force: Bool = false) {
        for entry in allEntries {
            if Translator.isModelDownloaded(entry.id) {
                if force || modelSizes[entry.id] == nil {
                    modelSizes[entry.id] = Self.modelDirectorySize(modelID: entry.id)
                }
                continue
            }
            guard modelSizes[entry.id] == nil, !sizesLoading.contains(entry.id) else { continue }
            sizesLoading.insert(entry.id)
            Task {
                let size = try? await ModelDownloader.estimatedSize(modelID: entry.id)
                sizesLoading.remove(entry.id)
                if let size { modelSizes[entry.id] = size }
            }
        }
    }

    private func tier(for modelID: String) -> ModelMemoryTier {
        guard let size = modelSizes[modelID] else { return .ok }
        return ModelMemoryAdvisor.tier(diskBytes: size)
    }

    private func dotColor(for entry: ModelCatalogEntry) -> Color {
        switch tier(for: entry.id) {
        case .blocked: return .red
        case .warning: return .orange
        case .ok: return Translator.isModelDownloaded(entry.id) ? .green : .secondary
        }
    }

    private func rowLabel(for entry: ModelCatalogEntry) -> String {
        var parts = [entry.displayName]
        if let size = modelSizes[entry.id] {
            parts.append(Self.formatBytes(size))
        } else {
            parts.append("查詢大小中…")
        }
        switch tier(for: entry.id) {
        case .ok: break
        case .warning: parts.append("警告")
        case .blocked: parts.append("阻擋")
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
            modelSizes[entry.id] = nil
            extraModelEntries.removeAll { $0.id == entry.id }
        }
    }

    private func openModelsFolderInFinder() {
        NSWorkspace.shared.open(MultiSubPaths.modelsRoot)
    }

    /// Mirrors `Translator.isModelDownloaded`'s repo-dir naming so the size
    /// shown always matches what that check just confirmed exists.
    private static func modelDirectorySize(modelID: String) -> Int64 {
        let repoDir = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let root = MultiSubPaths.modelsRoot.appendingPathComponent(repoDir, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    // MARK: - Software update (C7)

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

    /// 方案 B（2026-07-06 使用者拍板）：有 DMG 資產就在 App 內下載；若該次
    /// release 沒附 DMG（例如發佈流程出錯漏傳），退回方案 A 開網頁，而不是
    /// 讓使用者卡在一個永遠不會完成的下載上。
    private func startUpdate(version: String, htmlURL: URL, downloadURL: URL?) {
        guard let downloadURL else {
            NSWorkspace.shared.open(htmlURL)
            return
        }
        updateDownloadManager.start(from: downloadURL, suggestedFileName: "MultiSub-\(version).dmg")
    }

    // MARK: - Test translation

    private func runTest() {
        let text = testInput
        guard !text.isEmpty else { return }
        testRunning = true
        testOutput = "翻譯中…（首次執行需載入模型，約 10–30 秒）"

        Task {
            do {
                let start = Date()
                let result = try await Translator.shared.translate(lines: [text], targetLang: "zh-TW")
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
