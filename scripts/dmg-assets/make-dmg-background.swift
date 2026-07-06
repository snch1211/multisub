// make-dmg-background.swift — renders the DMG window background (R4 polish).
//
// Draws a dark, on-brand backdrop with the product title and a red arrow
// guiding the user to drag the app onto the Applications folder. Finder draws
// the actual app / Applications icons on top at the positions make-dmg.sh sets.
//
// IMPORTANT layout / resolution facts:
//   • Finder renders a DMG background at 1 image pixel = 1 point. So the artwork
//     is authored in the window's POINT size (640×400).
//   • For crispness on Retina, ship a single multi-representation TIFF holding
//     a 1× (640×400) and a 2× (1280×800) bitmap; Finder picks the 2× rep on
//     Retina automatically. (A "@2x.png" sibling is NOT reliably picked up.)
//   • NSImage.lockFocus adopts the screen's backing scale, which would double
//     exported pixel sizes. We draw once into a point-sized NSImage, then blit
//     it into bitmap reps whose pixel size we set explicitly.
//
// Output: dmg-background.tiff (1×+2×, used by the DMG) + dmg-background.png
//         (1× preview for humans/README).
// Run:    swift scripts/dmg-assets/make-dmg-background.swift
//
// AppKit only, no external dependencies (Xcode toolchain is a prereq anyway).

import AppKit

let ptW: CGFloat = 640, ptH: CGFloat = 400
let brandRed = NSColor(calibratedRed: 0.94, green: 0.28, blue: 0.24, alpha: 1) // #F0473E

// ── Draw the artwork once at point resolution (top-left origin) ───────────────
let art = NSImage(size: NSSize(width: ptW, height: ptH))
art.lockFocusFlipped(true)
let ctx = NSGraphicsContext.current!.cgContext

// Slightly lifted top keeps the panel from reading as flat black.
let top = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)    // #262629
let bottom = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1) // #0f0f12
NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: 0, y: 0, width: ptW, height: ptH), angle: -90)

func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top y: CGFloat) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(in: NSRect(x: (ptW - sz.width) / 2, y: y, width: sz.width, height: sz.height))
}
drawText("MultiSub", size: 34, weight: .bold, color: .white, top: 40)
drawText("把 MultiSub 拖進 Applications 資料夾即可安裝",
         size: 14, weight: .medium, color: NSColor(calibratedWhite: 0.92, alpha: 1), top: 84)

// Drag arrow between the two icon slots (icons sit at x≈170 and x≈470, y≈205).
let ay: CGFloat = 205, x0: CGFloat = 250, x1: CGFloat = 392
ctx.saveGState()
ctx.setShadow(offset: NSSize(width: 0, height: 2), blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
let shaft = NSBezierPath()
shaft.move(to: CGPoint(x: x0, y: ay)); shaft.line(to: CGPoint(x: x1 - 10, y: ay))
shaft.lineWidth = 6; shaft.lineCapStyle = .round
brandRed.setStroke(); shaft.stroke()
let head = NSBezierPath()
head.move(to: CGPoint(x: x1, y: ay))
head.line(to: CGPoint(x: x1 - 20, y: ay - 12))
head.line(to: CGPoint(x: x1 - 20, y: ay + 12))
head.close()
brandRed.setFill(); head.fill()
ctx.restoreGState()
art.unlockFocus()

// ── Blit into explicitly-sized bitmap reps (1× and 2×) ────────────────────────
func makeRep(pxW: Int, pxH: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = NSSize(width: ptW, height: ptH)   // point size fixed → sets the scale
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    art.draw(in: NSRect(x: 0, y: 0, width: ptW, height: ptH))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let rep1x = makeRep(pxW: Int(ptW), pxH: Int(ptH))
let rep2x = makeRep(pxW: Int(ptW * 2), pxH: Int(ptH * 2))

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

// Multi-representation TIFF: Finder picks 1×/2× per display.
guard let tiff = NSBitmapImageRep.representationOfImageReps(in: [rep1x, rep2x], using: .tiff, properties: [:]) else { exit(1) }
try! tiff.write(to: dir.appendingPathComponent("dmg-background.tiff"))
print("wrote dmg-background.tiff  (640×400 + 1280×800)")

// 1× PNG kept only as a human-viewable preview (not used by the DMG).
if let png = rep1x.representation(using: .png, properties: [:]) {
    try! png.write(to: dir.appendingPathComponent("dmg-background.png"))
    print("wrote dmg-background.png  (640×400 preview)")
}
