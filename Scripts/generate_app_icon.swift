#!/usr/bin/env swift
// Generate every iOS icon slot from AppIcon-iOS.svg, the editable vector master.
// Usage: swift Scripts/generate_app_icon.swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Render the SVG directly at the destination size, without cropping or resampling a bitmap.
func render(_ image: NSImage, pixels: Int, alpha: Bool, to output: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: alphaInfo.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

struct Manifest: Decodable {
    let images: [Slot]
    struct Slot: Decodable {
        let filename: String
        let size: String
        let scale: String
        var pixels: Int {
            let points = Double(size.split(separator: "x")[0])!
            let multiplier = Double(scale.dropLast())!
            return Int((points * multiplier).rounded())
        }
    }
}

let directory = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
let source = directory.appendingPathComponent("AppIcon-iOS.svg")
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot load SVG master") }
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("Contents.json")))
for slot in manifest.images {
    try render(image, pixels: slot.pixels, alpha: false, to: directory.appendingPathComponent(slot.filename))
    print("Generated \(slot.filename): \(slot.pixels) × \(slot.pixels), RGB")
}
