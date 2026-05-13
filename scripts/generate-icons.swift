#!/usr/bin/env swift
// Generates Halen's icon assets from Halen.svg.
//
//   - Menubar template PNGs (black-on-transparent at 22 / 44 / 66 pt). Halen
//     sets `isTemplate = true` so macOS tints them automatically.
//   - App icon iconset (white shapes on cobalt blue background at all the
//     standard sizes), then bundled into AppIcon.icns via `iconutil`.
//
// Run once from the project root. Re-run any time Halen.svg changes.

import Cocoa
import Foundation

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceSVG = URL(fileURLWithPath: "/Users/lukadadiani/Downloads/Halen.svg")
let resourcesDir = projectRoot.appending(path: "Resources")
let iconsetDir = resourcesDir.appending(path: "AppIcon.iconset")
let menubarOutDir = resourcesDir.appending(path: "Menubar")

try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: menubarOutDir, withIntermediateDirectories: true)

let svgString = try String(contentsOf: sourceSVG, encoding: .utf8)

// Two recoloured variants — black for template, white for app icon.
let blackSVG = svgString
    .replacingOccurrences(of: "rgb(0,77,252)", with: "rgb(0,0,0)")
    .replacingOccurrences(of: "rgb(1,78,252)", with: "rgb(0,0,0)")
let whiteSVG = svgString
    .replacingOccurrences(of: "rgb(0,77,252)", with: "rgb(255,255,255)")
    .replacingOccurrences(of: "rgb(1,78,252)", with: "rgb(255,255,255)")

let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "halen-icons-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

let blackURL = tempDir.appending(path: "black.svg")
let whiteURL = tempDir.appending(path: "white.svg")
try blackSVG.write(to: blackURL, atomically: true, encoding: .utf8)
try whiteSVG.write(to: whiteURL, atomically: true, encoding: .utf8)

func render(_ url: URL, size: NSSize, background: NSColor? = nil, inset: CGFloat = 0) -> NSImage {
    guard let svg = NSImage(contentsOf: url) else {
        fatalError("Failed to load SVG at \(url.path)")
    }
    let out = NSImage(size: size)
    out.lockFocus()
    defer { out.unlockFocus() }

    if let bg = background {
        bg.setFill()
        NSRect(origin: .zero, size: size).fill()
    }

    let svgSize = svg.size
    let target = size.width * (1 - inset * 2)
    let scale = target / max(svgSize.width, svgSize.height)
    let drawSize = NSSize(width: svgSize.width * scale, height: svgSize.height * scale)
    let origin = NSPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
    svg.draw(in: NSRect(origin: origin, size: drawSize))
    return out
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icons", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

// MARK: - App icon (cobalt blue background, white logo, ~18% padding)
let cobalt = NSColor(red: 0/255, green: 77/255, blue: 252/255, alpha: 1)
let appIconSizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for entry in appIconSizes {
    let img = render(whiteURL, size: NSSize(width: entry.px, height: entry.px), background: cobalt, inset: 0.18)
    try writePNG(img, to: iconsetDir.appending(path: entry.name))
    print("✓ \(entry.name)")
}

// MARK: - Menubar template (black on transparent)
for (px, suffix) in [(22, ""), (44, "@2x"), (66, "@3x")] {
    let img = render(blackURL, size: NSSize(width: px, height: px), background: nil, inset: 0.04)
    try writePNG(img, to: menubarOutDir.appending(path: "HalenMenubar\(suffix).png"))
    print("✓ HalenMenubar\(suffix).png")
}

// MARK: - Build .icns via iconutil
let icnsURL = resourcesDir.appending(path: "AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetDir.path]
let pipe = Pipe()
process.standardError = pipe
try process.run()
process.waitUntilExit()
if process.terminationStatus == 0 {
    print("✓ AppIcon.icns")
} else {
    let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    fatalError("iconutil failed: \(err)")
}

print("\nDone — generated icons in \(resourcesDir.path)")
