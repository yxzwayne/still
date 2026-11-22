import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(calibratedRed: 0.23, green: 0.37, blue: 0.31, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.07, y: p * 0.07, width: p * 0.86, height: p * 0.86), xRadius: p * 0.20, yRadius: p * 0.20).fill()
        NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.88, alpha: 1).setStroke()
        let bubble = NSBezierPath()
        bubble.move(to: NSPoint(x: p * 0.32, y: p * 0.32))
        bubble.line(to: NSPoint(x: p * 0.27, y: p * 0.23))
        bubble.curve(to: NSPoint(x: p * 0.72, y: p * 0.50), controlPoint1: NSPoint(x: p * 0.70, y: p * 0.23), controlPoint2: NSPoint(x: p * 0.76, y: p * 0.38))
        bubble.curve(to: NSPoint(x: p * 0.28, y: p * 0.56), controlPoint1: NSPoint(x: p * 0.69, y: p * 0.81), controlPoint2: NSPoint(x: p * 0.26, y: p * 0.80))
        bubble.curve(to: NSPoint(x: p * 0.32, y: p * 0.32), controlPoint1: NSPoint(x: p * 0.23, y: p * 0.46), controlPoint2: NSPoint(x: p * 0.27, y: p * 0.36))
        bubble.lineWidth = p * 0.04; bubble.lineCapStyle = .round; bubble.lineJoinStyle = .round; bubble.stroke()
        let line = NSBezierPath(); line.move(to: NSPoint(x: p * 0.39, y: p * 0.51)); line.line(to: NSPoint(x: p * 0.61, y: p * 0.51)); line.lineWidth = p * 0.04; line.lineCapStyle = .round; line.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
