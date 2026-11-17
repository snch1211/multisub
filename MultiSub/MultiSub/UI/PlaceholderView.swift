//
//  PlaceholderView.swift
//  MultiSub
//
//  Stand-in detail pane used while the tabs were being moved from AppKit to
//  SwiftUI. No tab uses it any more.
//

import SwiftUI

@MainActor
struct PlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            "這個分頁還沒完成",
            systemImage: systemImage,
            description: Text("「\(title)」之後會補上。")
        )
    }
}
