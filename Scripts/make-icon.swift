#!/usr/bin/env swift
//
// Renders the app icon and packs it into Assets.xcassets.
//
// The icon artwork lives in Design/app-icon.svg (the "worm in the silt"
// mascot). This script rasterises it at every catalogue size so the asset
// set is always derived from that single source rather than edited by hand.
//
//   swift Scripts/make-icon.swift
//

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Design/app-icon.svg")

guard let artwork = NSImage(contentsOf: svgURL) else {
    fputs("Cannot load \(svgURL.path)\n", stderr)
    exit(1)
}

// CoreSVG honours the SVG's own clip-path, so the sediment strata are already
// cut to the squircle plate: nothing to re-clip here. It does *not* accept
// `rgba()` colours though — a fill written that way rasterises with an alpha of
// zero, i.e. invisibly — so the artwork carries opacity in `fill-opacity` and
// `stroke-opacity` instead. Keep it that way when editing Design/app-icon.svg.

func render(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    artwork.draw(
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

// MARK: - Emit the asset catalogue

let iconSet = root
    .appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(
    at: iconSet, withIntermediateDirectories: true
)

struct Variant { let size: Int; let scale: Int }
let variants = [16, 32, 128, 256, 512].flatMap {
    [Variant(size: $0, scale: 1), Variant(size: $0, scale: 2)]
}

var entries: [String] = []
for variant in variants {
    let name = "icon_\(variant.size)x\(variant.size)"
        + (variant.scale == 2 ? "@2x" : "") + ".png"

    let bitmap = render(pixels: variant.size * variant.scale)
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: iconSet.appendingPathComponent(name))

    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(variant.scale)x",
          "size" : "\(variant.size)x\(variant.size)"
        }
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(
    to: iconSet.appendingPathComponent("Contents.json"),
    atomically: true, encoding: .utf8
)

// The catalogue itself needs a root marker.
try """
{ "info" : { "author" : "xcode", "version" : 1 } }
""".write(
    to: root.appendingPathComponent("App/Resources/Assets.xcassets/Contents.json"),
    atomically: true, encoding: .utf8
)

print("Icône générée : \(variants.count) tailles dans \(iconSet.path)")
