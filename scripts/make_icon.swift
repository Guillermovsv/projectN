// Renders a simple app icon to an .iconset folder. Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1),
                        NSColor(calibratedRed: 0.17, green: 0.13, blue: 0.27, alpha: 1)])!.draw(in: path, angle: -90)
    // prompt chevron
    let chevron = NSBezierPath()
    chevron.lineWidth = s * 0.06
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: s * 0.27, y: s * 0.64))
    chevron.line(to: NSPoint(x: s * 0.42, y: s * 0.50))
    chevron.line(to: NSPoint(x: s * 0.27, y: s * 0.36))
    NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.30, alpha: 1).setStroke()
    chevron.stroke()
    // "N" glyph
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.36, weight: .heavy),
        .foregroundColor: NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.85, alpha: 1)
    ]
    let n = NSAttributedString(string: "N", attributes: attrs)
    let sz = n.size()
    n.draw(at: NSPoint(x: s * 0.70 - sz.width / 2, y: s * 0.5 - sz.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
