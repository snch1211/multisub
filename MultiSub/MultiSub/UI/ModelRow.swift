//
//  ModelRow.swift
//  MultiSub
//
//  C3 (2026-07-05 follow-up): one row in GeneralSettingsView's model list —
//  shown for every catalog + manually-discovered entry regardless of
//  download state, per PLAN.md's wireframe. A dedicated view struct rather
//  than a body-returning method, per swiftui-pro's guidance that view
//  composition (not @ViewBuilder methods/properties) is what actually avoids
//  re-evaluating the whole row's layout unnecessarily.
//

import SwiftUI

@MainActor
struct ModelRow: View {
    let label: String
    /// Style guide v2 §4's 8pt status dot (`StatusDot`) — purely a
    /// memory-tier signal (ok/warning/blocked), independent of the
    /// "使用中"/"已選用" text baked into `label`: green only once a tier-ok
    /// model is actually downloaded, gray for a not-yet-downloaded tier-ok
    /// model, orange/red for warning/blocked regardless of download state
    /// (so the risk is visible before the user commits the disk space).
    let dotColor: Color
    let downloadState: ModelDownloadManager.DownloadState?
    let isDownloading: Bool
    let isDownloaded: Bool
    let onDelete: () -> Void
    let onDownload: () -> Void

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
            if isDownloading {
                EmptyView()
            } else if isDownloaded {
                Button("刪除模型", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            } else {
                Button(downloadState?.failed == true ? "重試下載" : "下載", action: onDownload)
            }
        }
    }
}
