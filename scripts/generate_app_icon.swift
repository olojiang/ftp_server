#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourceDirectory = root.appendingPathComponent("Sources/LocalFTPApp/Resources", isDirectory: true)
let iconsetDirectory = root.appendingPathComponent(".build/generated/AppIcon.iconset", isDirectory: true)
let iconPath = resourceDirectory.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for file in iconFiles {
    let image = drawIcon(size: file.pixels)
    let data = pngData(from: image, pixels: file.pixels)
    try data.write(to: iconsetDirectory.appendingPathComponent(file.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDirectory.path, "-o", iconPath.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconGeneration", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print("Generated \(iconPath.path)")

private func drawIcon(size: Int) -> NSImage {
    let canvas = CGFloat(size)
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

    let background = NSBezierPath(roundedRect: NSRect(x: canvas * 0.06, y: canvas * 0.06, width: canvas * 0.88, height: canvas * 0.88), xRadius: canvas * 0.2, yRadius: canvas * 0.2)
    NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.22, alpha: 1).setFill()
    background.fill()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.82, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.21, blue: 0.42, alpha: 1)
    ])
    gradient?.draw(in: background, angle: 90)

    let tray = NSBezierPath(roundedRect: NSRect(x: canvas * 0.2, y: canvas * 0.24, width: canvas * 0.6, height: canvas * 0.22), xRadius: canvas * 0.055, yRadius: canvas * 0.055)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    tray.fill()

    let traySlot = NSBezierPath(roundedRect: NSRect(x: canvas * 0.3, y: canvas * 0.33, width: canvas * 0.4, height: canvas * 0.035), xRadius: canvas * 0.018, yRadius: canvas * 0.018)
    NSColor(calibratedRed: 0.08, green: 0.33, blue: 0.63, alpha: 1).setFill()
    traySlot.fill()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: canvas * 0.5, y: canvas * 0.74))
    arrow.line(to: NSPoint(x: canvas * 0.66, y: canvas * 0.56))
    arrow.line(to: NSPoint(x: canvas * 0.56, y: canvas * 0.56))
    arrow.line(to: NSPoint(x: canvas * 0.56, y: canvas * 0.42))
    arrow.line(to: NSPoint(x: canvas * 0.44, y: canvas * 0.42))
    arrow.line(to: NSPoint(x: canvas * 0.44, y: canvas * 0.56))
    arrow.line(to: NSPoint(x: canvas * 0.34, y: canvas * 0.56))
    arrow.close()
    NSColor(calibratedRed: 0.2, green: 0.93, blue: 0.39, alpha: 1).setFill()
    arrow.fill()

    drawNode(at: NSPoint(x: canvas * 0.23, y: canvas * 0.62), size: canvas)
    drawNode(at: NSPoint(x: canvas * 0.77, y: canvas * 0.62), size: canvas)
    drawNode(at: NSPoint(x: canvas * 0.5, y: canvas * 0.83), size: canvas)

    return image
}

private func drawNode(at point: NSPoint, size: CGFloat) {
    let radius = size * 0.035
    NSColor(calibratedRed: 0.75, green: 1, blue: 0.82, alpha: 0.95).setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
}

private func pngData(from image: NSImage, pixels: Int) -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap representation")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode png")
    }
    return data
}
