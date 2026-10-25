// Renders Resources/AppIcon.icns: ink squircle, off-white prompt, blue caret.
// Run: swift scripts/make-icon.swift
import AppKit

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824pt body centered in 1024 with ~185pt corner radius.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSColor(srgbRed: 0x0E / 255, green: 0x0E / 255, blue: 0x0D / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).fill()
    NSColor(srgbRed: 0xF2 / 255, green: 0xF0 / 255, blue: 0xEA / 255, alpha: 0.12).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 183 * s, yRadius: 183 * s)
    rim.lineWidth = 4 * s
    rim.stroke()

    let ink = NSColor(srgbRed: 0xF2 / 255, green: 0xF0 / 255, blue: 0xEA / 255, alpha: 1)
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 350 * s, y: 640 * s))
    chevron.line(to: NSPoint(x: 510 * s, y: 512 * s))
    chevron.line(to: NSPoint(x: 350 * s, y: 384 * s))
    chevron.lineWidth = 56 * s
    chevron.lineCapStyle = .square
    chevron.lineJoinStyle = .miter
    ink.setStroke()
    chevron.stroke()

    NSColor(srgbRed: 0x4C / 255, green: 0x8D / 255, blue: 0xFF / 255, alpha: 1).setFill()
    NSRect(x: 590 * s, y: 368 * s, width: 64 * s, height: 288 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
