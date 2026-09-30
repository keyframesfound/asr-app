import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates the app icon (1024×1024 base) as a macOS .iconset → .icns is
/// handled by the build script via iconutil. Drawn with CoreGraphics: rounded
/// indigo square + white waveform bars (a lesson recording) + one sparkle
/// (the AI summary/quiz side).
let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }

// Squircle background — macOS icons get their corner mask from the system at
// Big Sur+; draw the full-bleed rounded rect anyway for the asset catalog look.
let inset: CGFloat = 100
let radius: CGFloat = 185
let bg = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
// Black, matching the app's black/white UI — faint gradient keeps the squircle from reading flat.
let colors = [rgba(0.0, 0.0, 0.0), rgba(0.09, 0.09, 0.10)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.saveGState()
let path = CGPath(roundedRect: bg, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end: CGPoint(x: CGFloat(size), y: 0),
    options: [])
ctx.restoreGState()

// Waveform: seven vertical bars, rounded caps, centred on the middle line.
let bars: [(height: CGFloat, alpha: CGFloat)] = [
    (180, 0.75), (330, 0.95), (240, 0.85), (420, 1.0), (270, 0.9), (360, 0.95), (160, 0.7),
]
let barWidth: CGFloat = 46
let gap: CGFloat = 40
let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
var x = (CGFloat(size) - totalWidth) / 2
let midY = CGFloat(size) / 2 - 30
for bar in bars {
    let rect = CGRect(x: x, y: midY - bar.height / 2, width: barWidth, height: bar.height)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: bar.alpha))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
}

// Sparkle (four-pointed star), top right — the AI summary/quiz side.
func sparkle(center: CGPoint, radius: CGFloat, color: CGColor) {
    let path = CGMutablePath()
    let points = 8
    for i in 0..<points {
        let angle = CGFloat(i) / CGFloat(points) * .pi * 2 - .pi / 2
        let r = i % 2 == 0 ? radius : radius * 0.28
        let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
}
sparkle(center: CGPoint(x: 740, y: 700), radius: 90, color: CGColor(srgbRed: 0.88, green: 0.88, blue: 0.90, alpha: 0.9))

guard let image = ctx.makeImage() else { fatalError("no image") }

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let scales: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, pixels) in scales {
    guard let scaledCtx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("scale context failed") }
    scaledCtx.interpolationQuality = .high
    scaledCtx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let scaled = scaledCtx.makeImage() else { fatalError("scale failed") }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(name).png") as CFURL
    guard let destImg = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("dest failed")
    }
    CGImageDestinationAddImage(destImg, scaled, nil)
    CGImageDestinationFinalize(destImg)
}
print("iconset written to \(outDir)")
