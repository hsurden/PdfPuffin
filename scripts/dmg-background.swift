// Draws the DMG window background: an arrow from the app to Applications, and the
// one-time "Open Anyway" note. Run: swift scripts/dmg-background.swift Resources/dmg-background.png
// The window is 600 × 400 points; the image is drawn at 2x for Retina screens. Everything sits
// in the top 370 points: on macOS 26 Finder adds a tab bar and path bar that cover the bottom.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 600, height: 400)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size   // 144 dpi, so Finder shows it at 600 × 400 points
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Soft background.
let bg = NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
                    ending: NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1))!
bg.draw(in: NSRect(origin: .zero, size: size), angle: -90)

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerY: CGFloat, width: CGFloat = 520) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: para]
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = str.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin]).height
    str.draw(with: NSRect(x: (600 - width) / 2, y: centerY - h / 2, width: width, height: h), options: [.usesLineFragmentOrigin])
}

text("Install PdfPuffin", size: 22, weight: .bold, color: NSColor(white: 0.15, alpha: 1), centerY: 372)
text("Drag PdfPuffin onto the Applications folder", size: 14, weight: .regular, color: NSColor(white: 0.35, alpha: 1), centerY: 344)

// Arrow between the two icons (icons sit at x 160 and 440, y 160 from the top).
let accent = NSColor(srgbRed: 0.24, green: 0.53, blue: 1.0, alpha: 1)
let y: CGFloat = 400 - 160
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: 238, y: y)); shaft.line(to: NSPoint(x: 352, y: y))
shaft.lineWidth = 6; shaft.lineCapStyle = .round
accent.setStroke(); shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 366, y: y)); head.line(to: NSPoint(x: 346, y: y + 15)); head.line(to: NSPoint(x: 346, y: y - 15)); head.close()
accent.setFill(); head.fill()

// First-launch note (unsigned app).
let note = NSRect(x: 40, y: 38, width: 520, height: 88)
NSColor(white: 1, alpha: 0.75).setFill()
NSBezierPath(roundedRect: note, xRadius: 10, yRadius: 10).fill()
text("The first time you open it, macOS may say it can't verify the developer.\nClick Done, then open System Settings ▸ Privacy & Security, scroll down,\nclick Open Anyway, and click Open when it asks again.\nAfter that it opens normally and updates itself.",
     size: 11.5, weight: .regular, color: NSColor(white: 0.3, alpha: 1), centerY: 82, width: 500)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
