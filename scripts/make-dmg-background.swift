#!/usr/bin/swift
// The disk image's Finder background: a neutral ground and one arrow from the
// app to the Applications folder. Drawn here, at build time, for the same
// reason the app icons come from a generator — no hand-made binary assets in
// the repository, and the arrow's endpoints stay in one file with the icon
// positions make-dmg.sh gives the Finder (icons centred at x=150 and x=450,
// y=190 from the top, in a 600×380 window).
//
// Deliberately restrained: no wordmark, no instructions, no tint. The arrow
// IS the instruction, which is how Apple's own images do it.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let points = NSSize(width: 600, height: 380)
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

NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
NSRect(origin: .zero, size: points).fill()

// Between the two icon homes, at their vertical centre. AppleScript positions
// count from the top; AppKit draws from the bottom — 380 − 190 = 190.
let y: CGFloat = 190
let tip = CGPoint(x: 365, y: y)
NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()

let shaft = NSBezierPath()
shaft.move(to: CGPoint(x: 235, y: y))
shaft.line(to: CGPoint(x: tip.x - 14, y: y))
shaft.lineWidth = 5
shaft.lineCapStyle = .round
shaft.stroke()

let head = NSBezierPath()
head.move(to: CGPoint(x: tip.x - 18, y: y + 11))
head.line(to: tip)
head.line(to: CGPoint(x: tip.x - 18, y: y - 11))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()
rep.size = points   // pixels ÷ points = 2× → tagged 144 dpi for the Finder

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
