#!/usr/bin/env swift
import AppKit
import Foundation

// Installs artwork as THE app icon.
//
// iOS icons must be opaque squares with square corners — the system draws the
// rounded mask itself, and an alpha channel is an App Store rejection. Source
// artwork usually arrives as a rounded card floating on a page, so this trims
// the flat border away, squares what's left, flattens it onto the card's own
// colour, and writes a 1024pt PNG into the asset catalog.
//
//   scripts/set-app-icon.swift <artwork.png> [--no-trim]

let iconSize = 1024
let borderTolerance = 14  // per-channel distance still counted as "border"

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconSetDir = repoRoot.appendingPathComponent(
    "Diane/Resources/Assets.xcassets/AppIcon.appiconset")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 2 else {
    fail("usage: scripts/set-app-icon.swift <artwork.png> [--no-trim]")
}
let trimBorder = !CommandLine.arguments.contains("--no-trim")
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])

guard let data = try? Data(contentsOf: inputURL),
      let source = NSBitmapImageRep(data: data)?.cgImage
        ?? NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("couldn't read an image from \(inputURL.path)") }

// MARK: pixels

let width = source.width
let height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("couldn't rasterize the source image") }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
}

/// (r, g, b, a) at a pixel; row 0 is the TOP row (context origin is flipped).
func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
    let i = ((height - 1 - y) * width + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
}

let reference = pixel(0, 0)
let referenceIsOpaque = reference.3 > 250

/// Anything that isn't solid artwork: transparent margin, the soft drop
/// shadow around a floating card (semi-transparent, and NOT part of the
/// icon — leaving it in keeps the card from bleeding to the edges), or a
/// flat opaque page matching the corner colour.
func isBorder(_ p: (Int, Int, Int, Int)) -> Bool {
    if p.3 < 250 { return true }
    guard referenceIsOpaque else { return false }
    return abs(p.0 - reference.0) <= borderTolerance
        && abs(p.1 - reference.1) <= borderTolerance
        && abs(p.2 - reference.2) <= borderTolerance
}

// MARK: trim to the artwork

var minX = 0, minY = 0, maxX = width - 1, maxY = height - 1
if trimBorder {
    minX = width; minY = height; maxX = -1; maxY = -1
    for y in 0..<height {
        for x in 0..<width where !isBorder(pixel(x, y)) {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { fail("the image is a single flat colour") }
}

// Square around the artwork's centre, clamped to the canvas.
let side = min(max(maxX - minX + 1, maxY - minY + 1), min(width, height))
let centerX = (minX + maxX) / 2
let centerY = (minY + maxY) / 2
let cropX = min(max(centerX - side / 2, 0), width - side)
let cropY = min(max(centerY - side / 2, 0), height - side)

// MARK: background colour — the most common opaque colour just inside the
// artwork edge, so masked-away corners blend instead of flashing white.
var tally: [Int: Int] = [:]
let inset = max(side / 25, 2)
for t in 1..<20 {
    let along = cropX + side * t / 20
    let down = cropY + side * t / 20
    for sample in [(along, cropY + inset), (along, cropY + side - inset),
                   (cropX + inset, down), (cropX + side - inset, down)] {
        let p = pixel(min(sample.0, width - 1), min(sample.1, height - 1))
        guard p.3 > 200 else { continue }
        tally[(p.0 << 16) | (p.1 << 8) | p.2, default: 0] += 1
    }
}
let packed = tally.max { $0.value < $1.value }?.key ?? 0xFF_FF_FF
let background = CGColor(
    red: CGFloat((packed >> 16) & 0xFF) / 255,
    green: CGFloat((packed >> 8) & 0xFF) / 255,
    blue: CGFloat(packed & 0xFF) / 255,
    alpha: 1
)

// MARK: render an opaque 1024pt icon

guard let cropped = source.cropping(
    to: CGRect(x: cropX, y: height - cropY - side, width: side, height: side)
) else { fail("crop failed") }

guard let canvas = CGContext(
    data: nil, width: iconSize, height: iconSize,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fail("couldn't create the icon canvas") }

canvas.interpolationQuality = .high
canvas.setFillColor(background)
canvas.fill(CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
canvas.draw(cropped, in: CGRect(x: 0, y: 0, width: iconSize, height: iconSize))

guard let output = canvas.makeImage() else { fail("couldn't render the icon") }
let png = NSBitmapImageRep(cgImage: output)
png.size = NSSize(width: iconSize, height: iconSize)
guard let pngData = png.representation(using: .png, properties: [:]) else {
    fail("couldn't encode PNG")
}

try? FileManager.default.createDirectory(at: iconSetDir, withIntermediateDirectories: true)
let iconURL = iconSetDir.appendingPathComponent("AppIcon.png")
do {
    try pngData.write(to: iconURL)
    try Data("""
    {
      "images" : [
        {
          "filename" : "AppIcon.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """.utf8).write(to: iconSetDir.appendingPathComponent("Contents.json"))
} catch { fail("couldn't write the icon: \(error.localizedDescription)") }

let hex = String(format: "#%06X", packed)
print("source   \(width)x\(height)")
print("artwork  \(side)x\(side) at (\(cropX), \(cropY))\(trimBorder ? "" : " (trim skipped)")")
print("backdrop \(hex)")
print("wrote    \(iconURL.path)")
