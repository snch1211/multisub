//
//  SidebarView.swift
//  MultiSub
//
//  Style guide v2 §5.0: brand row + four NavigationLinks.
//

import SwiftUI

@MainActor
struct SidebarView: View {
    @Bindable var router: AppRouter

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
                Label("一般設定", systemImage: "gearshape")
                    .tag(AppRouter.Tab.general)
                Label("字幕樣式", systemImage: "textformat")
                    .tag(AppRouter.Tab.styles)
                Label("快取管理", systemImage: "internaldrive")
                    .tag(AppRouter.Tab.cache)
                Label("生詞本", systemImage: "book")
                    .tag(AppRouter.Tab.vocab)
            }
        }
        // Style guide §5.0: sidebar ~200pt wide — also what keeps "MultiSub"
        // on one line next to the (now smaller) brand mark.
        .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 220)
    }
}
