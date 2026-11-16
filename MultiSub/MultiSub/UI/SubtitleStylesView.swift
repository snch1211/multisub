//
//  SubtitleStylesView.swift
//  MultiSub
//
//  字幕樣式. Behavior ported from the old AppKit ViewController's styles tab
//  (loadStyleControls/styleControlChanged/resetStyles/updateStylePreview/
//  hexString/color(fromHex:)).
//
//  Controls bind directly to `configStore.config.styles` via computed
//  `Binding`s (hex↔Color conversion happens in the getter, the setter writes
//  through `configStore.update`) instead of
//  mirroring into local @State reloaded on `onAppear`. An earlier version
//  used local @State + a load/save timing guard, but SwiftUI doesn't
//  guarantee `.onChange` fires before a deferred `Task` resets that guard —
//  found in regression testing, where the race actually fired and
//  silently overwrote a real saved style with `SubtitleStyle()` defaults.
//  Binding straight to the model has no load step and therefore no race.
//

import AppKit
import SwiftUI

@MainActor
struct SubtitleStylesView: View {
    @Environment(ConfigStore.self) private var configStore

    /// Named font presets; the App stores whichever CSS `font-family` string
    /// is selected directly in `config.json` (`SubtitleStyle.fontFamily`), so
    /// content.js never needs to map an id back to a value.
    private let fontOptions: [(title: String, cssValue: String)] = [
        ("預設（Netflix Sans）", SubtitleStyle.defaultFontFamily),
        ("系統預設", "-apple-system, system-ui, \"PingFang TC\", sans-serif"),
        ("襯線體", "Georgia, \"Noto Serif TC\", serif"),
    ]

    private static let outlineOffsets: [CGSize] = [
        CGSize(width: -1, height: -1), CGSize(width: 0, height: -1), CGSize(width: 1, height: -1),
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
        CGSize(width: -1, height: 1), CGSize(width: 0, height: 1), CGSize(width: 1, height: 1),
    ]

    private var styles: SubtitleStyle { configStore.config.styles }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .padding()
            Form {
                Section("文字") {
                    ColorPicker("字色", selection: textColorBinding, supportsOpacity: false)
                    Picker("字體", selection: fontFamilyBinding) {
                        ForEach(fontOptions, id: \.cssValue) { option in
                            Text(option.title).tag(option.cssValue)
                        }
                    }
                    HStack {
                        Text("行高")
                        Slider(value: lineHeightBinding, in: 1.0...2.0)
                        Text(String(format: "%.2f", styles.lineHeight))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Toggle("粗體", isOn: boldEnabledBinding)
                }

                Section("背景") {
                    ColorPicker("背景色", selection: backgroundColorBinding, supportsOpacity: false)
                    HStack {
                        Text("不透明度")
                        Slider(value: backgroundOpacityBinding, in: 0...1)
                        Text(String(format: "%.0f%%", styles.backgroundOpacity * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Section("描邊") {
                    Toggle("啟用描邊", isOn: outlineEnabledBinding)
                    ColorPicker("描邊顏色", selection: outlineColorBinding, supportsOpacity: false)
                        .disabled(!styles.outlineEnabled)
                }

                Section {
                    Button("還原預設") { resetStyles() }
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Live preview

    /// Fake player frame (hardcoded-color exception #2) with a
    /// fake original-language line (mimics Netflix's own non-configurable
    /// native subtitle for contrast reference) and a fake translated line
    /// that applies every current adjustment. Both are two-line text so the
    /// 行高 slider has something to visibly
    /// demonstrate — a single-line preview made that control a no-op visually.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.previewPlayerBackground)
            VStack(spacing: 6) {
                Text("I never thought I'd see you\nagain after everything that happened.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                previewSubtitleLine
            }
            .padding(.bottom, 16)
        }
        .frame(height: 140)
    }

    private var previewSubtitleLine: some View {
        outlinedPreviewText("沒想到經歷了那些事之後\n我還能再次見到你。")
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color(fromHex: styles.backgroundColor).opacity(styles.backgroundOpacity), in: RoundedRectangle(cornerRadius: 4))
    }

    /// Multi-directional offset-stack outline — same technique
    /// `overlay.css`'s text-shadow outline uses, so the preview matches what
    /// actually renders on Netflix rather than a different-looking stroke API.
    private func outlinedPreviewText(_ text: String) -> some View {
        ZStack {
            if styles.outlineEnabled {
                ForEach(Array(Self.outlineOffsets.enumerated()), id: \.offset) { _, offset in
                    previewTextBase(text)
                        .foregroundStyle(color(fromHex: styles.outlineColor))
                        .offset(offset)
                }
            }
            previewTextBase(text)
                .foregroundStyle(color(fromHex: styles.textColor))
        }
        .multilineTextAlignment(.center)
    }

    /// `lineSpacing` (SwiftUI adds space only *between* lines,
    /// unlike CSS line-height which also pads above/below each line) mirrors
    /// how the extension's overlay now turns 行高 into a gap between lines
    /// rather than inflating the background box (see overlay.css).
    private var previewLineSpacing: CGFloat {
        CGFloat((styles.lineHeight - 1) * 15)
    }

    private func previewTextBase(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: styles.boldEnabled ? .bold : .regular))
            .lineSpacing(previewLineSpacing)
    }

    // MARK: - Bindings (hex↔Color conversion at the model boundary)

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { color(fromHex: configStore.config.styles.textColor) },
            set: { newValue in configStore.update { $0.styles.textColor = hexString(from: newValue) } }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { color(fromHex: configStore.config.styles.backgroundColor) },
            set: { newValue in configStore.update { $0.styles.backgroundColor = hexString(from: newValue) } }
        )
    }

    private var outlineColorBinding: Binding<Color> {
        Binding(
            get: { color(fromHex: configStore.config.styles.outlineColor) },
            set: { newValue in configStore.update { $0.styles.outlineColor = hexString(from: newValue) } }
        )
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: {
                let current = configStore.config.styles.fontFamily
                return fontOptions.contains { $0.cssValue == current } ? current : fontOptions[0].cssValue
            },
            set: { newValue in configStore.update { $0.styles.fontFamily = newValue } }
        )
    }

    private var lineHeightBinding: Binding<Double> {
        Binding(
            get: { configStore.config.styles.lineHeight },
            set: { newValue in configStore.update { $0.styles.lineHeight = newValue } }
        )
    }

    private var boldEnabledBinding: Binding<Bool> {
        Binding(
            get: { configStore.config.styles.boldEnabled },
            set: { newValue in configStore.update { $0.styles.boldEnabled = newValue } }
        )
    }

    private var backgroundOpacityBinding: Binding<Double> {
        Binding(
            get: { configStore.config.styles.backgroundOpacity },
            set: { newValue in configStore.update { $0.styles.backgroundOpacity = newValue } }
        )
    }

    private var outlineEnabledBinding: Binding<Bool> {
        Binding(
            get: { configStore.config.styles.outlineEnabled },
            set: { newValue in configStore.update { $0.styles.outlineEnabled = newValue } }
        )
    }

    // MARK: - Actions

    private func resetStyles() {
        configStore.update { $0.styles = SubtitleStyle() }
    }

    private func hexString(from color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return "#ffffff" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private func color(fromHex hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return .white }
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        return Color(red: r, green: g, blue: b)
    }
}
