//
//  CacheManagementView.swift
//  MultiSub
//
//  Style guide v2 §5.3. Behavior ported from ViewController.buildCacheTab()
//  and its neighboring methods (reloadCacheEntries/rebuildCacheRows/
//  cacheItemDisplayTitle/deleteCacheSelected/clearAllCacheTapped) — see
//  PLAN.md G4. Grouping rule (2+ entries per series+season get a header,
//  singletons render flat) is unchanged; presentation swaps the AppKit
//  hand-rolled `GroupedRow` for `Table`'s native row-grouping (`Section`
//  inside the `rows:` builder), per style guide §4's table row.
//

import SwiftUI

@MainActor
struct CacheManagementView: View {
    private struct Row: Identifiable {
        let entry: CacheEntry
        let displayTitle: String
        var id: CacheGroupKey { CacheGroupKey(movieId: entry.movieId, targetLang: entry.targetLang, sourceLang: entry.sourceLang) }
    }

    @State private var entries: [CacheEntry] = []
    @State private var syncedAt: Date?
    @State private var stalenessOverride: String?
    @State private var selection = Set<CacheGroupKey>()
    @State private var showDeleteSelectedConfirm = false
    @State private var showClearAllConfirm = false

    private var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }
    private var groups: [RowGroup<Row>] {
        buildRowGroups(
            entries,
            groupKey: Self.groupKey,
            groupLabel: { seriesGroupLabel($0.seriesTitle ?? $0.movieId, seasonNumber: $0.seasonNumber) },
            makeRow: { entry, grouped in Row(entry: entry, displayTitle: Self.displayTitle(entry, grouped: grouped)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summarySection
            if entries.isEmpty {
                ContentUnavailableView("尚無快取", systemImage: "internaldrive")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                buttonRow
            }
        }
        .padding()
        .onAppear { reload() }
    }

    // MARK: - Sections

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("共 \(entries.count) 集・共 \(Self.formatBytes(totalBytes))")
            Text(stalenessOverride ?? Self.stalenessText(syncedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新整理") { reload() }
                .padding(.top, 4)
        }
    }

    private var table: some View {
        Table(of: Row.self, selection: $selection) {
            TableColumn("劇集") { row in Text(row.displayTitle) }
                .width(min: 140, ideal: 180)
            TableColumn("語言") { row in Text("\(row.entry.sourceLang) → \(row.entry.targetLang)") }
                .width(min: 70, ideal: 90)
            TableColumn("句數") { row in Text("\(row.entry.lineCount)") }
                .width(min: 40, ideal: 50)
            TableColumn("大小") { row in Text(Self.formatBytes(row.entry.bytes)) }
                .width(min: 60, ideal: 70)
            TableColumn("時間") { row in Text(Self.formatTime(row.entry.savedAt)) }
                .width(min: 110, ideal: 130)
        } rows: {
            ForEach(groups) { group in
                switch group {
                case .grouped(let label, let rows):
                    Section(label) {
                        ForEach(rows) { row in TableRow(row) }
                    }
                case .flat(let row):
                    TableRow(row)
                }
            }
        }
    }

    private var buttonRow: some View {
        HStack {
            Button("刪除所選") { showDeleteSelectedConfirm = true }
                .disabled(selection.isEmpty)
                .confirmationDialog(
                    "確定要刪除所選的 \(selection.count) 集快取嗎？",
                    isPresented: $showDeleteSelectedConfirm, titleVisibility: .visible
                ) {
                    Button("刪除", role: .destructive) { deleteSelected() }
                } message: {
                    Text("刪除會排入佇列，下次 Safari 擴充功能同步時才會實際生效（通常在你回到 Netflix 播放頁或打開 popup 後數秒到一分鐘內）。")
                }
            Button("清除全部快取") { showClearAllConfirm = true }
                .confirmationDialog(
                    "確定要清除全部 \(entries.count) 集快取嗎？",
                    isPresented: $showClearAllConfirm, titleVisibility: .visible
                ) {
                    Button("清除全部", role: .destructive) { clearAll() }
                } message: {
                    Text("此動作無法復原。刪除會排入佇列，下次 Safari 擴充功能同步時才會實際生效。")
                }
        }
    }

    // MARK: - Data flow

    private func reload() {
        let (loaded, synced) = CacheSync.loadIndex()
        entries = loaded.sorted { $0.savedAt > $1.savedAt }
        syncedAt = synced
        stalenessOverride = nil
        let stillPresent = Set(entries.map { CacheGroupKey(movieId: $0.movieId, targetLang: $0.targetLang, sourceLang: $0.sourceLang) })
        selection.formIntersection(stillPresent)
    }

    private func deleteSelected() {
        let keys = selection
        guard !keys.isEmpty else { return }
        CacheSync.queueDelete(CacheDeleteRequest(clearAll: false, groups: Array(keys)))
        // Optimistic UI: drop the rows now; the extension confirms this for
        // real the next time it pings and pushes a fresh index.
        entries.removeAll { keys.contains(CacheGroupKey(movieId: $0.movieId, targetLang: $0.targetLang, sourceLang: $0.sourceLang)) }
        selection.removeAll()
        stalenessOverride = "已排入清除佇列，實際生效需等 Safari 擴充功能下次同步"
    }

    private func clearAll() {
        guard !entries.isEmpty else { return }
        CacheSync.queueDelete(CacheDeleteRequest(clearAll: true, groups: []))
        entries = []
        selection.removeAll()
        stalenessOverride = "已排入清除佇列，實際生效需等 Safari 擴充功能下次同步"
    }

    // MARK: - Grouping (rule ported from ViewController.rebuildCacheRows; see EpisodeGrouping.swift)

    /// A entry with no `seriesTitle` yet (the fire-and-forget `episode-title`
    /// lookup hasn't landed, or never will) falls back to its own `movieId`
    /// as the grouping key, which always renders as an ungrouped singleton
    /// row showing the bare movieId.
    private static func groupKey(_ entry: CacheEntry) -> String {
        guard let series = entry.seriesTitle, !series.isEmpty else { return "movie:\(entry.movieId)" }
        return "\(series)|\(entry.seasonNumber.map(String.init) ?? "")"
    }

    /// `grouped` entries (sitting under a `Section`) show just the
    /// episode-specific part, to avoid repeating the series name the header
    /// already states.
    private static func displayTitle(_ entry: CacheEntry, grouped: Bool) -> String {
        guard let series = entry.seriesTitle, !series.isEmpty else { return entry.movieId }
        if let episode = entry.episodeTitle, !episode.isEmpty {
            return grouped ? episode : "\(series) - \(episode)"
        }
        return series
    }

    // MARK: - Formatting

    private static func stalenessText(_ syncedAt: Date?) -> String {
        guard let syncedAt else {
            return "尚未收到 Safari 擴充功能的同步資料——開啟 Netflix 播放頁或點開 popup 後再回來按「重新整理」"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_TW")
        return "資料來自 Safari 擴充功能同步，非即時。最後同步：\(formatter.string(from: syncedAt))"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private static func formatTime(_ savedAtMs: Double) -> String {
        guard savedAtMs > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: savedAtMs / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        formatter.locale = Locale(identifier: "zh_TW")
        return formatter.string(from: date)
    }
}
