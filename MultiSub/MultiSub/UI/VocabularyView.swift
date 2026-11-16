//
//  VocabularyView.swift
//  MultiSub
//
//  生詞本. Behavior ported from the old AppKit ViewController's vocabulary
//  tab (reloadVocabEpisodes/applyVocabFilter/deleteSelectedWordsTapped/
//  deleteEpisodeTapped/promptOrganizeVocab/runVocabExtraction).
//  CEFR-column sort is simplified to
//  Table's native ascending/descending toggle (no third "unsorted" state —
//  SwiftUI's Table header tap doesn't expose one without extra machinery);
//  everything else is a straight port.
//
//  The episode list has its own search field + collapsible series/season
//  groups (default collapsed) + a sort control (最近整理新→舊/舊→新/劇名 A-Z).
//  Word search stays on the window's native `.searchable()`, which is what
//  gives it the Tahoe glass search-field look; the
//  episode-sort control lives in `.toolbar` for the same reason — only real
//  toolbar items get the native Liquid Glass button treatment, so it's a
//  `Menu` in a `ToolbarItem`, not a view-content control. Under this window's
//  `.hiddenTitleBar` style (see MultiSubApp), NSToolbar packs every item
//  leading-first with no default trailing anchor — a leading `ToolbarItem {
//  Spacer() }` before the sort menu is what actually pushes [sort][search]
//  to the trailing edge the user asked for; without it both sit right next
//  to the sidebar toggle with dead space to the window's right edge.
//  Episode search (`MSInlineSearchField`, DesignSystem.swift) is a styled
//  view-content control rather than a second `.searchable()` — only one can
//  occupy the toolbar, and this is meant to be a persistent panel-local
//  filter, not the window's primary search (same idiom as System Settings'
//  sidebar-list search). A NavigationSplitView + `.searchable(placement:
//  .sidebar)` was tried for this (would've made it a fully native sidebar
//  search field) but made the word-search `.searchable` vanish from the
//  toolbar entirely — two `.searchable`s on sibling NavigationSplitView
//  columns didn't coexist here — so this reverted back to the HSplitView +
//  MSInlineSearchField shape.
//  The "must select an episode first" restriction on word search is gone —
//  no selection now searches every episode's words, with a 集數 column
//  identifying the source.
//

import SwiftUI

extension VocabWord: Identifiable {
    /// `lemma` is unique within one episode's word list (extraction
    /// de-duplicates by lemma), so it doubles as a
    /// stable row identity without touching the shared model type.
    var id: String { lemma }
}

@MainActor
struct VocabularyView: View {
    private struct EpisodeRow: Identifiable {
        let file: VocabFile
        let displayTitle: String
        var id: String { file.movieId }
    }

    /// One row in the word table. Always carries its source episode so the
    /// optional 集數 column (cross-episode search) doesn't need a second row
    /// type — a single-episode Table just doesn't show that column.
    private struct WordRow: Identifiable {
        let word: VocabWord
        let episodeMovieId: String
        let episodeDisplayTitle: String
        var id: String { "\(episodeMovieId)#\(word.lemma)" }
    }

    private enum EpisodeSortOption {
        case recentDesc, recentAsc, titleAZ
    }

    private static let cefrLevels = ["A1", "A2", "B1", "B2", "C1", "C2"]

    @Environment(AppRouter.self) private var router
    @Environment(VocabExtractionManager.self) private var extractionManager

    @State private var episodes: [VocabFile] = []
    @State private var selectedMovieId: String?
    @State private var cefrFilter: String?
    @State private var searchText = ""
    @State private var sortOrder: [KeyPathComparator<WordRow>] = []
    @State private var selectedWordIDs = Set<String>()
    @State private var showDeleteWordsConfirm = false
    @State private var showDeleteEpisodeConfirm = false

    // Episode list search/sort/collapse.
    @State private var episodeSearchText = ""
    @State private var episodeSortOption: EpisodeSortOption = .recentDesc
    /// Group label -> expanded. Absent means collapsed (default-collapsed,
    /// per user's pick), so this only ever needs to record exceptions.
    @State private var expandedGroups = Set<String>()

    // multisub://vocab trigger flow.
    @State private var pendingTranscript: PendingTranscript?
    @State private var showOrganizeConfirm = false
    @State private var nonEnglishSourceLang: String?
    @State private var showNonEnglishAlert = false
    /// Which engine the confirmation says it will use, e.g. "本機模型（Gemma 4 E4B）".
    @State private var organizeEngineName = ""
    @State private var engineMissingMessage = ""
    @State private var showEngineMissingAlert = false

    private var selectedEpisode: VocabFile? {
        episodes.first { $0.movieId == selectedMovieId }
    }

    /// No episode selected means "search everything" rather than
    /// "show nothing" — the old behavior required picking an episode first.
    private var filteredWordRows: [WordRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sourceEpisodes = selectedEpisode.map { [$0] } ?? episodes
        var rows = sourceEpisodes.flatMap { episode in
            episode.words.compactMap { word -> WordRow? in
                if let cefrFilter, word.cefr.uppercased() != cefrFilter { return nil }
                if !query.isEmpty {
                    let matches = word.word.lowercased().contains(query)
                        || word.lemma.lowercased().contains(query)
                        || word.translation.lowercased().contains(query)
                    guard matches else { return nil }
                }
                return WordRow(word: word, episodeMovieId: episode.movieId, episodeDisplayTitle: episode.displayTitle)
            }
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        return rows
    }

    private var selectedWordRow: WordRow? {
        guard selectedWordIDs.count == 1, let id = selectedWordIDs.first else { return nil }
        return filteredWordRows.first { $0.id == id }
    }

    var body: some View {
        Group {
            if episodes.isEmpty {
                ContentUnavailableView("尚無生詞本，請到 Netflix 播放頁整理", systemImage: "book")
            } else {
                HSplitView {
                    episodeList
                        .padding(.trailing)
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                    wordPane
                        .padding(.leading)
                        .frame(minWidth: 400)
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜尋單字")
        .toolbar {
            // Leading spacer item pushes the sort menu (and the trailing
            // .searchable field after it) to the window's right edge — see
            // the file header comment for why this is needed under
            // .hiddenTitleBar.
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                episodeSortMenu
            }
        }
        .padding()
        .onAppear {
            reloadEpisodes()
            handlePendingVocabMovieId(router.pendingVocabMovieId)
        }
        .onChange(of: router.pendingVocabMovieId) { _, newValue in
            handlePendingVocabMovieId(newValue)
        }
        .onChange(of: selectedMovieId) { _, _ in selectedWordIDs.removeAll() }
        .alert("僅支援英文字幕的生詞本整理", isPresented: $showNonEnglishAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("這集的來源字幕語言是「\(nonEnglishSourceLang ?? "")」，生詞本功能目前只支援英文字幕。")
        }
        .alert(
            pendingTranscript.map { "發現尚未整理的《\($0.displayTitle)》，是否開始整理？" } ?? "",
            isPresented: $showOrganizeConfirm
        ) {
            Button("開始整理") { if let pending = pendingTranscript { startOrganizing(pending) } }
            Button("取消", role: .cancel) { pendingTranscript = nil }
        } message: {
            Text("會分析這一集的字幕，挑出值得學的單字，可能需要幾分鐘。\n使用的 AI 引擎：\(organizeEngineName)")
        }
        .alert("尚未設定 AI 引擎", isPresented: $showEngineMissingAlert) {
            Button("前往一般設定") { router.selection = .general }
            Button("取消", role: .cancel) {}
        } message: {
            Text(engineMissingMessage)
        }
    }

    // MARK: - Toolbar: episode sort menu, sits left of the native
    // word search field .searchable() places in the same toolbar.

    private var episodeSortMenu: some View {
        Menu("劇集排序", systemImage: "line.3.horizontal.decrease.circle") {
            Button("最近整理（新到舊）") { episodeSortOption = .recentDesc }
            Button("最近整理（舊到新）") { episodeSortOption = .recentAsc }
            Button("劇名（A–Z）") { episodeSortOption = .titleAZ }
        }
        .help("劇集排序")
    }

    // MARK: - Episode list (left)

    private var episodeList: some View {
        VStack(spacing: 8) {
            MSInlineSearchField(prompt: "搜尋劇集", text: $episodeSearchText)

            List(selection: $selectedMovieId) {
                if !extractionManager.extractions.isEmpty {
                    Section {
                        ForEach(Array(extractionManager.extractions.keys.sorted()), id: \.self) { movieId in
                            if let state = extractionManager.extractions[movieId] {
                                VStack(alignment: .leading, spacing: 4) {
                                    if !state.failed {
                                        ProgressView(value: state.progress)
                                    }
                                    Text(state.statusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                ForEach(episodeGroups) { group in
                    switch group {
                    case .grouped(let label, let rows):
                        DisclosureGroup(label, isExpanded: expandedBinding(for: label)) {
                            ForEach(rows) { row in
                                Text("\(row.displayTitle)（\(row.file.words.count)）").tag(row.id)
                            }
                        }
                    case .flat(let row):
                        Text("\(row.displayTitle)（\(row.file.words.count)）").tag(row.id)
                    }
                }
            }
        }
    }

    private func expandedBinding(for label: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(label) },
            set: { isExpanded in
                if isExpanded { expandedGroups.insert(label) } else { expandedGroups.remove(label) }
            }
        )
    }

    private var episodeGroups: [RowGroup<EpisodeRow>] {
        buildRowGroups(
            filteredSortedEpisodes,
            groupKey: { "\($0.seriesTitle)|\($0.seasonNumber.map(String.init) ?? "")" },
            groupLabel: { seriesGroupLabel($0.seriesTitle, seasonNumber: $0.seasonNumber) },
            makeRow: { file, grouped in
                let title = grouped ? (file.episodeTitle?.isEmpty == false ? file.episodeTitle! : file.displayTitle) : file.displayTitle
                return EpisodeRow(file: file, displayTitle: title)
            }
        )
    }

    private var filteredSortedEpisodes: [VocabFile] {
        let query = episodeSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        var list = episodes
        if !query.isEmpty {
            list = list.filter {
                $0.seriesTitle.lowercased().contains(query)
                    || ($0.episodeTitle?.lowercased().contains(query) ?? false)
                    || $0.displayTitle.lowercased().contains(query)
            }
        }
        switch episodeSortOption {
        case .recentDesc:
            list.sort { $0.createdAt > $1.createdAt }
        case .recentAsc:
            list.sort { $0.createdAt < $1.createdAt }
        case .titleAZ:
            list.sort { $0.seriesTitle.localizedStandardCompare($1.seriesTitle) == .orderedAscending }
        }
        return list
    }

    // MARK: - Word pane (right)

    private var wordPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("CEFR", selection: $cefrFilter) {
                Text("全部").tag(String?.none)
                ForEach(Self.cefrLevels, id: \.self) { level in
                    Text(level).tag(String?.some(level))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            // The 360pt cap above sizes the control; this centers that
            // fixed-width control within the pane, over the Table below,
            // instead of leaving it pinned to the leading edge like the
            // parent VStack's `alignment: .leading` otherwise would.
            .frame(maxWidth: .infinity, alignment: .center)

            if filteredWordRows.isEmpty {
                // Give the empty state the same footprint the Table
                // would occupy (rather than its own compact intrinsic size)
                // so swapping between the two doesn't reflow the rest of the
                // pane, and make it non-interactive — it's a status message,
                // not a row — so a stray click can't trigger anything.
                ContentUnavailableView("沒有符合條件的單字", systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else {
                Table(filteredWordRows, selection: $selectedWordIDs, sortOrder: $sortOrder) {
                    TableColumn("單字", value: \.word.word)
                    TableColumn("CEFR", value: \.word.cefr) { row in CEFRBadge(level: row.word.cefr) }
                        .width(60)
                    TableColumn("翻譯", value: \.word.translation)
                    // Only meaningful once results can span episodes.
                    if selectedEpisode == nil {
                        TableColumn("集數", value: \.episodeDisplayTitle)
                    }
                }
            }

            if let selectedWordRow {
                wordDetailCard(selectedWordRow.word)
            }

            HStack {
                Button("刪除所選單字") { showDeleteWordsConfirm = true }
                    .disabled(selectedWordIDs.isEmpty)
                    .confirmationDialog(
                        "確定要刪除所選的 \(selectedWordIDs.count) 個單字嗎？",
                        isPresented: $showDeleteWordsConfirm, titleVisibility: .visible
                    ) {
                        Button("刪除", role: .destructive) { deleteSelectedWords() }
                    } message: {
                        Text("此動作無法復原。")
                    }
                Button("刪除整集") { showDeleteEpisodeConfirm = true }
                    .disabled(selectedEpisode == nil)
                    .confirmationDialog(
                        selectedEpisode.map { "確定要刪除《\($0.displayTitle)》的整份生詞本嗎？" } ?? "",
                        isPresented: $showDeleteEpisodeConfirm, titleVisibility: .visible
                    ) {
                        Button("刪除", role: .destructive) { deleteEpisode() }
                    } message: {
                        Text(selectedEpisode.map { "此動作無法復原，共 \($0.words.count) 個單字會一併刪除。" } ?? "")
                    }
            }
        }
    }

    private func wordDetailCard(_ word: VocabWord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CEFRBadge(level: word.cefr)
                Text("\(word.word) · \(word.pos)")
                    .font(.headline)
            }
            Text("definition：\(word.definitionEn)")
            Text("翻譯：\(word.translation)")
            Text("例句：\(word.example)")
            Text("例句翻譯：\(word.exampleTranslation)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Data flow

    private func reloadEpisodes(selecting movieId: String? = nil) {
        episodes = VocabStore.loadAll().sorted { $0.createdAt > $1.createdAt }
        if let movieId, episodes.contains(where: { $0.movieId == movieId }) {
            selectedMovieId = movieId
        } else if selectedMovieId == nil || !episodes.contains(where: { $0.movieId == selectedMovieId }) {
            selectedMovieId = episodes.first?.movieId
        }
    }

    /// Selection can span multiple episodes (cross-episode search
    /// with nothing selected in the left list), so removal has to be grouped
    /// by source episode rather than assuming everything selected belongs to
    /// `selectedEpisode`.
    private func deleteSelectedWords() {
        let rowsToRemove = filteredWordRows.filter { selectedWordIDs.contains($0.id) }
        let lemmasByEpisode = Dictionary(grouping: rowsToRemove, by: \.episodeMovieId)
            .mapValues { Set($0.map { $0.word.lemma }) }
        for (movieId, lemmas) in lemmasByEpisode {
            guard var episode = episodes.first(where: { $0.movieId == movieId }) else { continue }
            episode.words.removeAll { lemmas.contains($0.lemma) }
            VocabStore.save(episode)
        }
        selectedWordIDs.removeAll()
        reloadEpisodes(selecting: selectedMovieId)
    }

    private func deleteEpisode() {
        guard let movieId = selectedMovieId else { return }
        VocabStore.delete(movieId: movieId)
        reloadEpisodes()
    }

    // MARK: - multisub://vocab trigger flow

    private func handlePendingVocabMovieId(_ movieId: String?) {
        guard let movieId, let pending = PendingTranscriptStore.load(movieId: movieId) else { return }
        router.pendingVocabMovieId = nil

        // Second gate: content.js/popup.js already check
        // this before the user ever gets here, but this App-side check is the
        // actual line of defense against a stale popup button state or any
        // future caller that bypasses popup entirely.
        let primarySubtag = pending.sourceLang.split(separator: "-").first.map { $0.lowercased() } ?? ""
        guard primarySubtag == "en" else {
            nonEnglishSourceLang = pending.sourceLang
            showNonEnglishAlert = true
            return
        }
        // Checked before asking, so the user isn't told "this takes a few
        // minutes" for a run that would fail on its first request. The
        // transcript stays staged; the popup's button stages it again anyway.
        do {
            organizeEngineName = try Self.engineDescription()
        } catch {
            engineMissingMessage = VocabExtractionManager.message(for: error)
                + "設定好後，再到 Netflix 播放頁按一次「整理本集單字」。"
            showEngineMissingAlert = true
            return
        }
        pendingTranscript = pending
        showOrganizeConfirm = true
    }

    /// The engine `Translator` would use right now, named for the
    /// confirmation alert. Throws `TranslatorError` when none can run.
    private static func engineDescription() throws -> String {
        switch try Translator.resolveEngine(config: MultiSubConfig.load()) {
        case .local(let modelID):
            return "本機模型（\(ModelCatalog.displayName(for: modelID))）"
        case .cloud(let client):
            return "\(client.provider.displayName)（\(client.model)）"
        }
    }

    private func startOrganizing(_ pending: PendingTranscript) {
        pendingTranscript = nil
        extractionManager.start(pending) { file in
            reloadEpisodes(selecting: file.movieId)
        }
    }
}
