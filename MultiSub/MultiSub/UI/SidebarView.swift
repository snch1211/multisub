//
//  SidebarView.swift
//  MultiSub
//
//  Brand row + one row per tab.
//

import SwiftUI

@MainActor
struct SidebarView: View {
    @Bindable var router: AppRouter
    @Environment(VocabExtractionManager.self) private var vocab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BrandLogoView()
                Text("MultiSub")
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.top, MSBrand.sidebarTopInset)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            List(selection: $router.selection) {
                Label("開始使用", systemImage: "sparkles")
                    .tag(AppRouter.Tab.welcome)
                Label("一般設定", systemImage: "gearshape")
                    .tag(AppRouter.Tab.general)
                // A picture, not a letter symbol: the app's language is
                // zh-Hant, so "textformat" draws 「格式」 and "textformat.abc"
                // draws 「甲乙丙」 instead of Latin letters.
                Label("字幕樣式", systemImage: "paintpalette")
                    .tag(AppRouter.Tab.styles)
                Label("快取管理", systemImage: "internaldrive")
                    .tag(AppRouter.Tab.cache)
                HStack {
                    Label("生詞本", systemImage: "book")
                    Spacer(minLength: 4)
                    // An episode is being organized, wherever the window is.
                    if vocab.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("正在整理單字")
                    }
                }
                .tag(AppRouter.Tab.vocab)
            }
        }
        // Sidebar ~200pt wide — also what keeps "MultiSub"
        // on one line next to the (now smaller) brand mark.
        .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 220)
    }
}
