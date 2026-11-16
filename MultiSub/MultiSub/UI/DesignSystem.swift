//
//  DesignSystem.swift
//  MultiSub
//
//  The *only* place `if #available(macOS 26.0, *)` may
//  appear. Feature views call these wrappers instead of branching themselves.
//

import SwiftUI

enum MSBrand {
    /// Hardcoded-color exception #1 — brand accent, only ever
    /// used for the sidebar logo's lower bar, never on buttons/controls.
    static let accent = Color(red: 0.898, green: 0.137, blue: 0.184)

    /// Clearance for the sidebar's brand row under `.windowStyle(.hiddenTitleBar)`
    /// (see `MultiSubApp`), which stops reserving that space for us the way a
    /// normal toolbar/titlebar would. Matches the traffic-light control strip's
    /// height on current macOS; named here (instead of a bare literal in
    /// `SidebarView`) since it'd need revisiting if that strip's height changes.
    static let sidebarTopInset: CGFloat = 28
}

enum DesignSystem {
    /// `MULTISUB_FORCE_LEGACY_UI=1` forces the macOS 15.0 fallback path even
    /// on a macOS 26 dev machine (no 15.x hardware to
    /// test on otherwise). DEBUG-only so a Release build can't be forced.
    static var forceLegacyUI: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MULTISUB_FORCE_LEGACY_UI"] == "1"
        #else
        return false
        #endif
    }

    /// Hardcoded-color exception #2 — the subtitle-styles tab's
    /// fake player background. Must render as a dark player frame
    /// regardless of system light/dark mode, so it's exempt from the
    /// semantic-color rule (same exception `ViewController.buildStylesTab`
    /// used via `NSColor(calibratedWhite:alpha:)`). Raised from 0.1 to 0.32 — the user found near-black too dark to
    /// distinguish a black/semi-transparent overlay background against it.
    static let previewPlayerBackground = Color(white: 0.32)
}

/// Status indicator: a semantic-colored 8pt dot + label.
@MainActor
struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
        // Without this, VoiceOver reads the dot and the label as two
        // separate elements (the dot itself as an unlabeled shape).
        .accessibilityElement(children: .combine)
    }
}

/// A search field that lives in view content rather than the window
/// toolbar — for panel-local search (e.g. filtering one list among several
/// in a split view), where the usual `.searchable()` toolbar field
/// doesn't apply because only one `.searchable()` can occupy the window's
/// toolbar at a time. Mirrors System Settings' sidebar-list search field
/// (magnifying glass + clear button in a rounded, materialed capsule)
/// instead of a plain bordered `TextField`, which doesn't read as native.
@MainActor
struct MSInlineSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜尋")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// CEFR level pill, colored from easy (green) to hard (red).
@MainActor
struct CEFRBadge: View {
    let level: String

    private var colors: (background: Color, foreground: Color) {
        switch level.uppercased() {
        case "A1": return (.green, .white)
        case "A2": return (.teal, .white)
        case "B1": return (.blue, .white)
        case "B2": return (.yellow, .black)
        case "C1": return (.orange, .black)
        case "C2": return (.red, .white)
        default: return (.gray, .white)
        }
    }

    var body: some View {
        Text(level.uppercased())
            .font(.caption.bold())
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(colors.background, in: Capsule())
    }
}
