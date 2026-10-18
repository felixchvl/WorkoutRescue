// Generates the 1024×1024 opaque App Store / watchOS icon (no alpha channel, no SF Symbols).
// Usage: swift scripts/make-icon.swift "WorkoutRescue Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
import AppKit
import CoreGraphics

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)

// Background: deep blue vertical gradient.
let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.04, green: 0.10, blue: 0.22, alpha: 1),
                                                       CGColor(red: 0.02, green: 0.30, blue: 0.45, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// A winding GPS track (orange) with start and end dots.
let track = CGMutablePath()
track.move(to: CGPoint(x: 0.20 * s, y: 0.30 * s))
track.addCurve(to: CGPoint(x: 0.45 * s, y: 0.42 * s), control1: CGPoint(x: 0.30 * s, y: 0.18 * s), control2: CGPoint(x: 0.42 * s, y: 0.22 * s))
track.addCurve(to: CGPoint(x: 0.62 * s, y: 0.36 * s), control1: CGPoint(x: 0.48 * s, y: 0.60 * s), control2: CGPoint(x: 0.58 * s, y: 0.50 * s))
track.addCurve(to: CGPoint(x: 0.80 * s, y: 0.42 * s), control1: CGPoint(x: 0.66 * s, y: 0.24 * s), control2: CGPoint(x: 0.76 * s, y: 0.26 * s))
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 1))
ctx.setLineWidth(0.055 * s)
ctx.addPath(track)
ctx.strokePath()
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
for p in [CGPoint(x: 0.20 * s, y: 0.30 * s), CGPoint(x: 0.80 * s, y: 0.42 * s)] {
    ctx.fillEllipse(in: CGRect(x: p.x - 0.045 * s, y: p.y - 0.045 * s, width: 0.09 * s, height: 0.09 * s))
}

// Upward "export" arrow (white) above the track.
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 0.50 * s, y: 0.86 * s))
arrow.addLine(to: CGPoint(x: 0.66 * s, y: 0.68 * s))
arrow.addLine(to: CGPoint(x: 0.56 * s, y: 0.68 * s))
arrow.addLine(to: CGPoint(x: 0.56 * s, y: 0.52 * s))
arrow.addLine(to: CGPoint(x: 0.44 * s, y: 0.52 * s))
arrow.addLine(to: CGPoint(x: 0.44 * s, y: 0.68 * s))
arrow.addLine(to: CGPoint(x: 0.34 * s, y: 0.68 * s))
arrow.closeSubpath()
ctx.addPath(arrow)
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
