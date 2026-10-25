import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let rect = NSRect(x: size*0.075, y: size*0.075, width: size*0.85, height: size*0.85)
    let path = NSBezierPath(roundedRect: rect, xRadius: size*0.2, yRadius: size*0.2)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.46, blue: 0.98, alpha: 1), NSColor(red: 0.68, green: 0.76, blue: 1, alpha: 1)])!.draw(in: path, angle: 65)
    NSColor.white.withAlphaComponent(0.55).setStroke(); path.lineWidth = max(0.6, size*0.006); path.stroke()
    // Original vector hand outline; no photo or generated-image input.
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x*size, y: y*size) }
    let hand = NSBezierPath()
    hand.move(to: point(0.35, 0.35))
    hand.line(to: point(0.27, 0.51))
    hand.curve(to: point(0.33, 0.55), controlPoint1: point(0.23, 0.59), controlPoint2: point(0.29, 0.62))
    hand.line(to: point(0.38, 0.47))
    hand.line(to: point(0.38, 0.70))
    hand.curve(to: point(0.45, 0.70), controlPoint1: point(0.38, 0.77), controlPoint2: point(0.45, 0.77))
    hand.line(to: point(0.45, 0.78))
    hand.curve(to: point(0.52, 0.78), controlPoint1: point(0.45, 0.85), controlPoint2: point(0.52, 0.85))
    hand.line(to: point(0.52, 0.72))
    hand.curve(to: point(0.59, 0.72), controlPoint1: point(0.52, 0.79), controlPoint2: point(0.59, 0.79))
    hand.line(to: point(0.59, 0.64))
    hand.curve(to: point(0.66, 0.64), controlPoint1: point(0.59, 0.71), controlPoint2: point(0.66, 0.71))
    hand.line(to: point(0.66, 0.42))
    hand.curve(to: point(0.52, 0.22), controlPoint1: point(0.66, 0.31), controlPoint2: point(0.61, 0.22))
    hand.curve(to: point(0.35, 0.35), controlPoint1: point(0.44, 0.21), controlPoint2: point(0.40, 0.25))
    hand.lineJoinStyle = .round; hand.lineCapStyle = .round; hand.lineWidth = max(1, size*0.025)
    NSColor.white.withAlphaComponent(0.95).setStroke(); hand.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
}
