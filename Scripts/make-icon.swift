#!/usr/bin/env swift
//
// Renders the app icon and packs it into Assets.xcassets.
//
// Drawn in code rather than committed as binaries: the icon is the sunburst the
// app draws, using the same validated palette, so it should be derived from the
// same numbers rather than redrawn by hand and left to drift.
//
//   swift Scripts/make-icon.swift
//

import AppKit
import Foundation

// The first four slots of the categorical palette, dark variants.
let hues: [NSColor] = [
    NSColor(srgbRed: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255, alpha: 1),
    NSColor(srgbRed: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255, alpha: 1),
    NSColor(srgbRed: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255, alpha: 1),
    NSColor(srgbRed: 0xC9 / 255, green: 0x85 / 255, blue: 0x00 / 255, alpha: 1),
]

/// One ring's worth of slices: (slot, sweep fraction).
let rings: [[(Int, Double)]] = [
    [(0, 0.46), (1, 0.26), (2, 0.17), (3, 0.11)],
    [(0, 0.28), (0, 0.18), (1, 0.16), (1, 0.10), (2, 0.17), (3, 0.11)],
    [(0, 0.16), (0, 0.13), (0, 0.09), (1, 0.15), (1, 0.11), (2, 0.10),
     (2, 0.08), (3, 0.11), (3, 0.07)],
]

func lighten(_ color: NSColor, by amount: Double) -> NSColor {
    guard let c = color.usingColorSpace(.sRGB) else { return color }
    return NSColor(
        srgbRed: min(1, c.redComponent + amount),
        green: min(1, c.greenComponent + amount),
        blue: min(1, c.blueComponent + amount),
        alpha: 1
    )
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: CGSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)

    // Rounded-square plate, following the macOS icon grid: the artwork sits in
    // roughly 82% of the canvas.
    let margin = size * 0.09
    let plate = CGRect(x: margin, y: margin,
                       width: size - margin * 2, height: size - margin * 2)
    let corner = plate.width * 0.2237

    let platePath = CGPath(
        roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
        transform: nil
    )
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let backdrop = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).cgColor,
            NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backdrop,
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )

    let center = CGPoint(x: plate.midX, y: plate.midY)
    let outer = plate.width * 0.40
    let inner = plate.width * 0.135
    let gap = plate.width * 0.018
    let ringWidth = (outer - inner) / CGFloat(rings.count)

    for (index, ring) in rings.enumerated() {
        let r0 = inner + CGFloat(index) * ringWidth
        let r1 = r0 + ringWidth - gap
        var angle = -Double.pi / 2

        for (slot, fraction) in ring {
            let sweep = fraction * 2 * .pi
            let padding = min(0.05, sweep * 0.06)
            let start = angle + padding / 2
            let end = angle + sweep - padding / 2

            let path = CGMutablePath()
            path.addArc(center: center, radius: r1,
                        startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: center, radius: r0,
                        startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()

            let color = lighten(hues[slot], by: Double(index) * 0.07)
            context.addPath(path)
            context.setFillColor(color.cgColor)
            context.fillPath()

            angle += sweep
        }
    }

    // Hollow centre, matching the app's own sunburst.
    context.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(
        x: center.x - inner + gap, y: center.y - inner + gap,
        width: (inner - gap) * 2, height: (inner - gap) * 2
    ))
    context.restoreGState()

    image.unlockFocus()
    return image
}

func write(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

// MARK: - Emit the asset catalogue

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
    let pixels = CGFloat(variant.size * variant.scale)
    let name = "icon_\(variant.size)x\(variant.size)"
        + (variant.scale == 2 ? "@2x" : "") + ".png"

    let image = drawIcon(size: pixels)
    // lockFocus renders at the backing scale; force the pixel dimensions.
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

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
