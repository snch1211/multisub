//
//  BrandLogoView.swift
//  MultiSub
//
//  Restores extension/popup.html's .logo SVG (two rounded bars) as native
//  SwiftUI shapes. Deliberately not an NSImage/App icon or NSBezierPath
//  draw: the AppKit version had repeated background-redraw bugs with a
//  custom NSView.draw(_:) that don't apply to SwiftUI's Color.primary.
//

import SwiftUI

@MainActor
struct BrandLogoView: View {
    /// 1 is the sidebar size; the onboarding page shows it larger. Applied to
    /// the frames rather than via `scaleEffect`, so the layout grows with it.
    var scale: CGFloat = 1

    var body: some View {
        // Scaled down from the original 52×14 / 36×12 popup proportions so
        // the mark sits at roughly the cap-height of the adjacent .headline
        // "MultiSub" text instead of dwarfing it in the sidebar row.
        VStack(spacing: 2 * scale) {
            RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                .fill(Color.primary.opacity(0.85))
                .frame(width: 26 * scale, height: 7 * scale)
            RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                .fill(MSBrand.accent)
                .frame(width: 18 * scale, height: 6 * scale)
        }
        // Purely decorative — the adjacent "MultiSub" Text already announces
        // the brand name, so VoiceOver shouldn't read the shapes separately.
        .accessibilityHidden(true)
    }
}
