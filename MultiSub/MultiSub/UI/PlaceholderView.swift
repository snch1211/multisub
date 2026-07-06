//
//  PlaceholderView.swift
//  MultiSub
//
//  Stand-in for a not-yet-migrated detail pane during G1–G5 (see PLAN.md
//  Phase G "執行注意"). Replaced tab-by-tab as G2–G5 land.
//

import SwiftUI

@MainActor
struct PlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            "本分頁移植中（Phase G）",
            systemImage: systemImage,
            description: Text("「\(title)」尚未改寫為 SwiftUI，稍後的任務會補上。")
        )
    }
}
