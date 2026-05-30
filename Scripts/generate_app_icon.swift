#!/usr/bin/env swift
// Renders the CPA Panel app icon (full-bleed 1024x1024, no alpha) and writes every
// size required by App/Assets.xcassets/AppIcon.appiconset.
//
// Design language matches the macOS CPA icon: an open "gauge" arc plus three
// descending quota bars on a deep teal gradient. iOS masks the corners, so the
// art is full-bleed with no rounded border or drop shadow baked in.
//
// Usage: swift Scripts/generate_app_icon.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSetDir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")

func srgb() -> CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: srgb(), components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

func renderBaseIcon(side: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: srgb(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!

    // Work in SVG-style coordinates (origin top-left, y down) on a 1024 canvas.
    let s = side / 1024.0
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: s, y: s)

    // Diagonal background gradient: deep slate -> dark teal -> teal.
    let bg = CGGradient(
        colorsSpace: srgb(),
        colors: [
            color(0.043, 0.071, 0.125),   // #0B1220
            color(0.055, 0.302, 0.325),   // #0E4D53
            color(0.071, 0.659, 0.553)    // #12A88D
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        bg,
        start: CGPoint(x: 96, y: 96),
        end: CGPoint(x: 928, y: 928),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Soft cyan glow in the upper-left for a little life.
    let glow = CGGradient(
        colorsSpace: srgb(),
        colors: [color(0.40, 0.92, 0.96, 0.30), color(0.40, 0.92, 0.96, 0.0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 332, y: 300), startRadius: 0,
        endCenter: CGPoint(x: 332, y: 300), endRadius: 560,
        options: []
    )

    // Open gauge arc (a "C" opening to the right), near-white, thick rounded stroke.
    let arc = CGMutablePath()
    arc.move(to: CGPoint(x: 700, y: 300))
    arc.addCurve(to: CGPoint(x: 500, y: 212), control1: CGPoint(x: 649, y: 250), control2: CGPoint(x: 578, y: 212))
    arc.addCurve(to: CGPoint(x: 188, y: 524), control1: CGPoint(x: 328, y: 212), control2: CGPoint(x: 188, y: 352))
    arc.addCurve(to: CGPoint(x: 500, y: 836), control1: CGPoint(x: 188, y: 696), control2: CGPoint(x: 328, y: 836))
    arc.addCurve(to: CGPoint(x: 700, y: 748), control1: CGPoint(x: 578, y: 836), control2: CGPoint(x: 649, y: 798))
    ctx.setStrokeColor(color(0.973, 0.980, 0.988))
    ctx.setLineWidth(108)
    ctx.setLineCap(.round)
    ctx.addPath(arc)
    ctx.strokePath()

    // Three descending quota bars to the right of the arc.
    func bar(x: CGFloat, y: CGFloat, w: CGFloat, fill: CGColor) {
        let h: CGFloat = 88
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        ctx.setFillColor(fill)
        ctx.addPath(path)
        ctx.fillPath()
    }
    bar(x: 452, y: 360, w: 330, fill: color(0.133, 0.827, 0.933))          // #22D3EE cyan
    bar(x: 452, y: 482, w: 246, fill: color(0.973, 0.980, 0.988, 0.94))    // near-white
    bar(x: 452, y: 604, w: 160, fill: color(0.973, 0.980, 0.988, 0.74))    // dimmer

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot create destination for \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("cannot write \(url.lastPathComponent)")
    }
}

// filename -> pixel side
let outputs: [String: CGFloat] = [
    "AppIcon-1024.png": 1024,
    "AppIcon-iPhone-20@2x.png": 40, "AppIcon-iPhone-20@3x.png": 60,
    "AppIcon-iPhone-29@2x.png": 58, "AppIcon-iPhone-29@3x.png": 87,
    "AppIcon-iPhone-40@2x.png": 80, "AppIcon-iPhone-40@3x.png": 120,
    "AppIcon-iPhone-60@2x.png": 120, "AppIcon-iPhone-60@3x.png": 180,
    "AppIcon-iPad-20.png": 20, "AppIcon-iPad-20@2x.png": 40,
    "AppIcon-iPad-29.png": 29, "AppIcon-iPad-29@2x.png": 58,
    "AppIcon-iPad-40.png": 40, "AppIcon-iPad-40@2x.png": 80,
    "AppIcon-iPad-76.png": 76, "AppIcon-iPad-76@2x.png": 152,
    "AppIcon-iPad-83_5@2x.png": 167
]

// Render each size from scratch so the art stays crisp at small sizes.
for (name, side) in outputs.sorted(by: { $0.value > $1.value }) {
    let image = renderBaseIcon(side: side)
    write(image, to: iconSetDir.appendingPathComponent(name))
    print("wrote \(name) (\(Int(side))px)")
}
print("done: \(outputs.count) icons")
