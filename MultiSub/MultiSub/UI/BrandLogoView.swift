//
//  BrandLogoView.swift
//  MultiSub
//
//  Restores extension/popup.html's .logo SVG (two rounded bars) as native
//  SwiftUI shapes — style guide v2 §5.0.1. Deliberately not an NSImage/App
//  icon or NSBezierPath draw: v1's U1 had repeated background-redraw bugs
//  with a custom NSView.draw(_:) that don't apply to SwiftUI's Color.primary.
//

import SwiftUI

@MainActor
struct BrandLogoView: View {
    var body: some View {
        // Scaled down from the original 52×14 / 36×12 popup proportions so
        // the mark sits at roughly the cap-height of the adjacent .headline
        // "MultiSub" text instead of dwarfing it in the sidebar row.
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.85))
                .frame(width: 26, height: 7)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(MSBrand.accent)
                .frame(width: 18, height: 6)
        }
        // Purely decorative — the adjacent "MultiSub" Text already announces
        // the brand name, so VoiceOver shouldn't read the shapes separately.
        .accessibilityHidden(true)
    }
}
