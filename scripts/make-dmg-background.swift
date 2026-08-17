#!/usr/bin/swift
// The disk image's Finder background. It is generated at build time so the
// repository contains no hand-made binary artwork. Keep the logical centers
// here in sync with the Finder positions in make-dmg.sh.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let points = NSSize(width: 700, height: 440)
let scale: CGFloat = 2   // retina; rep.size below is what marks the file 144 dpi

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(points.width * scale),
                                 pixelsHigh: Int(points.height * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: scale, y: scale)   // draw in points

NSColor(srgbRed: 0.975, green: 0.982, blue: 0.980, alpha: 1).setFill()
NSRect(origin: .zero, size: points).fill()

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: 0.1
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(at: CGPoint(x: (points.width - size.width) / 2, y: y),
                             withAttributes: attributes)
}

// Keep the copy quiet and centered, like a native macOS installer rather than
// turning the disk image into a marketing panel.
drawCentered("sAiity", y: 365,
             font: .systemFont(ofSize: 28, weight: .semibold),
             color: NSColor(srgbRed: 0.04, green: 0.42, blue: 0.42, alpha: 1))
drawCentered("Drag to install", y: 326,
             font: .systemFont(ofSize: 15, weight: .medium),
             color: NSColor(srgbRed: 0.24, green: 0.30, blue: 0.30, alpha: 1))

// Finder positions count from the top; AppKit draws from the bottom. The
// shared y value is the vertical midpoint of this symmetric 440-point canvas.
let y: CGFloat = 220
let appCenterX: CGFloat = 170
let applicationsCenterX: CGFloat = 530
let arrowStartX = appCenterX + 84
let arrowTipX = applicationsCenterX - 84
let tip = CGPoint(x: arrowTipX, y: y)
NSColor(srgbRed: 0.04, green: 0.55, blue: 0.54, alpha: 0.95).setStroke()

let shaft = NSBezierPath()
shaft.move(to: CGPoint(x: arrowStartX, y: y))
shaft.line(to: CGPoint(x: tip.x - 16, y: y))
shaft.lineWidth = 2.5
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: CGPoint(x: tip.x - 16, y: y + 9))
head.line(to: tip)
head.line(to: CGPoint(x: tip.x - 16, y: y - 9))
head.lineWidth = 2.5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()
rep.size = points   // pixels ÷ points = 2× → tagged 144 dpi for the Finder

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
