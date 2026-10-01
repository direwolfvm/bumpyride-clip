// Run from the repository root: swift scripts/generate-macos-icon.swift
// Drawn from vector primitives; the sample videos are not involved in app assets.
import AppKit
import Foundation

let output = URL(fileURLWithPath: "BumpyRide Clip/BumpyRide Clip/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Keep point size equal to pixels: the drawing transform supplies the only scale.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 198, yRadius: 198)
        NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.25, blue: 0.4, alpha: 1), ending: NSColor(srgbRed: 0.055, green: 0.12, blue: 0.21, alpha: 1))!.draw(in: background, angle: -90)
        let film = NSBezierPath(roundedRect: NSRect(x: 240, y: 310, width: 544, height: 428), xRadius: 52, yRadius: 52)
        film.lineWidth = 32; NSColor.white.setStroke(); film.stroke()
        NSColor.white.setFill()
        for x in stride(from: 294, through: 686, by: 98) {
            for y in [344, 668] { NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 44, height: 30), xRadius: 7, yRadius: 7).fill() }
        }
        let play = NSBezierPath(); play.move(to: NSPoint(x: 450, y: 424)); play.line(to: NSPoint(x: 450, y: 626)); play.line(to: NSPoint(x: 618, y: 525)); play.close(); play.fill()
        let waveform = NSBezierPath(); waveform.move(to: NSPoint(x: 198, y: 236))
        for point in [(335,236),(375,270),(424,158),(488,298),(532,218),(570,236),(826,236)] {
            waveform.line(to: NSPoint(x: point.0, y: point.1))
        }
        waveform.lineWidth = 30; waveform.lineCapStyle = .round; waveform.lineJoinStyle = .round
        NSColor(srgbRed: 0.3, green: 0.89, blue: 0.64, alpha: 1).setStroke(); waveform.stroke()
        NSGraphicsContext.restoreGraphicsState()
        // Catch accidental double-scaling at the small Dock/Finder icon resolutions.
        var minX = pixels, minY = pixels, maxX = 0, maxY = 0
        for y in stride(from: 0, to: pixels, by: max(1, pixels / 128)) {
            for x in stride(from: 0, to: pixels, by: max(1, pixels / 128)) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        precondition(Double(maxX - minX + 1) / Double(pixels) > 0.8 && Double(maxY - minY + 1) / Double(pixels) > 0.8,
                     "Icon artwork must fill the canvas at every resolution.")
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        images.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":name])
    }
}
let manifest: [String: Any] = ["images":images,"info":["author":"xcode","version":1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
