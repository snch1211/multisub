//
//  ModelRow.swift
//  MultiSub
//
//  One model row: GeneralSettingsView's list shows one for every catalog +
//  manually-discovered entry (the ones not downloaded yet under
//  「可下載的模型」), and EngineSetupView shows one for the selected model. A dedicated view struct
//  rather than a body-returning method: view composition (not @ViewBuilder
//  methods/properties) is what actually avoids re-evaluating the whole row's
//  layout unnecessarily.
//

import SwiftUI

@MainActor
struct ModelRow: View {
    @Environment(ModelDownloadManager.self) private var downloadManager

    let modelID: String
    let label: String
    /// The 8pt status dot (`StatusDot`) — purely a
    /// memory-tier signal (ok/warning/blocked), independent of the
    /// "使用中"/"已選用" text baked into `label`: green only once a tier-ok
    /// model is actually downloaded, gray for a not-yet-downloaded tier-ok
    /// model, orange/red for warning/blocked regardless of download state
    /// (so the risk is visible before the user commits the disk space).
    let dotColor: Color
    let isDownloaded: Bool
    /// Not downloaded, but an earlier attempt left files to resume from, in
    /// the model's folder or its partial folder: 下載 then says 繼續下載,
    /// and with `onDelete` set a trash button next to it deletes them. Nil
    /// reads the disk here (`MultiSubPaths.hasModelFiles`); 一般設定 passes
    /// what it measured, so the row agrees with its 下載未完成 note.
    var hasUnfinishedDownload: Bool? = nil
    /// Nil hides the delete button (the engine setup only downloads; deleting
    /// lives in 一般設定's full list) and shows a "已下載" mark instead.
    let onDelete: (() -> Void)?
    let onDownload: () -> Void

    private var downloadState: ModelDownloadManager.DownloadState? { downloadManager.downloads[modelID] }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // `StatusDot` doesn't take a font — its `Text` has none of
                // its own, so `.font()` applied here cascades to it via the
                // environment, same as any other unstyled child Text.
                StatusDot(color: dotColor, text: label)
                    .font(.callout.monospaced())
                if let downloadState {
                    if downloadState.failed {
                        Text("下載失敗：\(downloadState.errorDescription ?? "")")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        HStack {
                            ProgressView(value: downloadState.progress)
                            Text(downloadState.progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            if downloadManager.isDownloading(modelID) {
                EmptyView()
            } else if isDownloaded {
                if let onDelete {
                    Button("刪除模型", systemImage: "trash", role: .destructive, action: onDelete)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                } else {
                    Label("已下載", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                let resumable = hasUnfinishedDownload ?? MultiSubPaths.hasModelFiles(for: modelID)
                if resumable, let onDelete {
                    Button("刪除下載到一半的檔案", systemImage: "trash", role: .destructive, action: onDelete)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("刪除下載到一半的檔案")
                }
                downloadButton(resumable: resumable)
            }
        }
        // Only a row on screen asks for its size (Hugging Face isn't
        // contacted for rows the user never opens). Idempotent, since a
        // grouped Form re-runs this when a row scrolls back into view.
        .task(id: isDownloaded ? nil : modelID) {
            if !isDownloaded { downloadManager.requestSizeEstimate(modelID: modelID) }
        }
    }

    /// 下載 waits for the size: a multi-GB download must not start before
    /// the user has seen how big it is and, in 一般設定, the memory warning.
    @ViewBuilder
    private func downloadButton(resumable: Bool) -> some View {
        switch downloadManager.sizeEstimates[modelID] {
        case .known?:
            Button(downloadTitle(resumable: resumable), action: onDownload)
        case .failed?:
            Button("重新查詢大小") { downloadManager.retrySizeEstimate(modelID: modelID) }
        case .loading?, nil:
            Button(downloadTitle(resumable: resumable), action: onDownload)
                .disabled(true)
                .help("查到模型大小後才能下載")
        }
    }

    /// 繼續下載 when earlier files are kept to pick up from, whether the last
    /// attempt failed in this run or the app quit halfway. 重試下載 after a
    /// failure that left nothing to resume (say it stopped before any data
    /// arrived), so the button never promises to continue from nothing.
    private func downloadTitle(resumable: Bool) -> String {
        if resumable { return "繼續下載" }
        return downloadState?.failed == true ? "重試下載" : "下載"
    }
}
