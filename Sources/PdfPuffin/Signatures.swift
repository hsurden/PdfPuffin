import AppKit
import PDFKit

/// A saved signature: pen strokes, a typed name in a script font, or an image.
/// Stored as JSON (+ PNG for images) in ~/Library/Application Support/PdfPuffin/Signatures.
struct Signature: Codable, Identifiable {
    struct Pt: Codable { var x: Double; var y: Double; var w: Double }
    var id: String
    var kind: String                 // "ink", "text", "image"
    var aspect: Double               // width / height
    var height: Double               // default height on the page, in points
    var strokes: [[Pt]]? = nil       // ink: points with y from 0 (top) to 1 (bottom)
    var lineWidth: Double? = nil
    var name: String? = nil          // text
    var font: String? = nil          // PostScript font name
    var rgba: [Double]? = nil        // ink/text colour

    var color: NSColor {
        let c = rgba ?? [0, 0, 0, 1]
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }
    var imageURL: URL { SignatureStore.folder.appendingPathComponent(id + ".png") }

    /// Draws the signature to fill `r` (in a y-up context such as a PDF page).
    func draw(in r: NSRect, context cg: CGContext) {
        switch kind {
        case "ink":
            cg.saveGState()
            cg.setStrokeColor(color.cgColor)
            cg.setLineCap(.round); cg.setLineJoin(.round)
            let s = r.height
            for stroke in strokes ?? [] where stroke.count > 1 {
                for i in 1..<stroke.count {
                    let a = stroke[i - 1], b = stroke[i]
                    // PDF Expert stores the pen width (pt at a 30-pt-high signature) and a
                    // per-point pressure factor (about 1); scale both with the size drawn.
                    let pressure = min(max((a.w + b.w) / 2, 0.3), 1.2)
                    cg.setLineWidth(max(0.5 * s / 36, (lineWidth ?? 1) * pressure * s / 30))
                    cg.move(to: CGPoint(x: r.minX + a.x * s, y: r.maxY - a.y * s))
                    cg.addLine(to: CGPoint(x: r.minX + b.x * s, y: r.maxY - b.y * s))
                    cg.strokePath()
                }
            }
            cg.restoreGState()
        case "text":
            let font = NSFont(name: font ?? "", size: 10) ?? NSFont(name: "SnellRoundhand", size: 10) ?? .systemFont(ofSize: 10)
            let str = name ?? ""
            let unit = (str as NSString).size(withAttributes: [.font: font])
            let fs = 10 * min(r.width / max(unit.width, 1), r.height / max(unit.height, 1))
            let f = NSFont(descriptor: font.fontDescriptor, size: fs) ?? font
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            let sz = (str as NSString).size(withAttributes: attrs)
            (str as NSString).draw(at: NSPoint(x: r.minX + (r.width - sz.width) / 2, y: r.minY + (r.height - sz.height) / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        default:
            if let img = NSImage(contentsOf: imageURL), let ci = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cg.interpolationQuality = .high
                cg.draw(ci, in: r)
            }
        }
    }

    /// Picture for the Signatures panel.
    func thumbnail(width: CGFloat) -> NSImage {
        let h = width / CGFloat(max(aspect, 0.1))
        let size = NSSize(width: width, height: min(h, width * 0.6))
        return NSImage(size: size, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            var r = rect.insetBy(dx: 6, dy: 6)
            let a = CGFloat(self.aspect)
            if r.width / r.height > a { let w = r.height * a; r.origin.x += (r.width - w) / 2; r.size.width = w }
            else { let hh = r.width / a; r.origin.y += (r.height - hh) / 2; r.size.height = hh }
            self.draw(in: r, context: cg)
            return true
        }
    }
}

/// A placed signature. PDFKit saves what `draw` produces as the annotation's
/// appearance, so the signature stays in the file (checked: survives save and reopen).
final class SignatureAnnotation: PDFAnnotation {
    var signature: Signature?
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let signature else { super.draw(with: box, in: context); return }
        signature.draw(in: bounds, context: context)
    }
}

enum SignatureStore {
    /// The signature the Signature tool places next.
    static var selected: Signature?

    static let folder: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PdfPuffin/Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func all() -> [Signature] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            .compactMap { try? JSONDecoder().decode(Signature.self, from: Data(contentsOf: $0)) }
    }

    static func save(_ s: Signature) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: folder.appendingPathComponent(s.id + ".json")) }
    }

    static func delete(_ s: Signature) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(s.id + ".json"))
        try? FileManager.default.removeItem(at: s.imageURL)
    }

    /// Adds an image file (PNG, JPEG, PDF…) as a signature.
    static func addImage(from url: URL) -> Signature? {
        guard let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let s = Signature(id: UUID().uuidString, kind: "image", aspect: Double(img.size.width / max(img.size.height, 1)), height: 36)
        try? png.write(to: s.imageURL)
        save(s)
        return s
    }

    // MARK: PDF Expert import

    static var pdfExpertPrefs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.readdle.PDFExpert-Mac.plist")
    }

    /// Copies the signatures saved in PDF Expert (its `myInkSignatures` preference).
    /// Skips ones already imported. Returns how many were added.
    @discardableResult
    static func importFromPDFExpert() -> Int {
        guard let plist = NSDictionary(contentsOf: pdfExpertPrefs),
              let data = plist["myInkSignatures"] as? Data else { return 0 }
        let u: NSKeyedUnarchiver
        do { u = try NSKeyedUnarchiver(forReadingFrom: data) } catch { return 0 }
        u.requiresSecureCoding = false
        u.setClass(RDInk.self, forClassName: "RDPDFInkSignature")
        u.setClass(RDText.self, forClassName: "RDPDFTextSignature")
        u.setClass(RDImage.self, forClassName: "RDPDFImageSignature")
        u.setClass(NSColor.self, forClassName: "RDCPColor")
        let items = (u.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [Any]) ?? []
        u.finishDecoding()
        let have = Set(all().map(\.id))
        var added = 0
        for item in items {
            var s: Signature?
            if let i = item as? RDInk {
                s = Signature(id: i.uid, kind: "ink", aspect: i.size.width / max(i.size.height, 0.01), height: i.pdfScale,
                              strokes: i.strokes, lineWidth: i.width, rgba: rgba(i.color))
            } else if let t = item as? RDText {
                s = Signature(id: t.uid, kind: "text", aspect: t.size.width / max(t.size.height, 0.01), height: t.pdfScale,
                              name: t.name, font: t.font, rgba: rgba(t.color))
            } else if let m = item as? RDImage, let img = NSImage(data: m.imageData) {
                var sig = Signature(id: m.uid, kind: "image", aspect: Double(img.size.width / max(img.size.height, 1)), height: m.pdfScale)
                try? m.imageData.write(to: sig.imageURL)
                sig.height = m.pdfScale
                s = sig
            }
            if let s, !have.contains(s.id) { save(s); added += 1 }
        }
        return added
    }

    private static func rgba(_ c: NSColor?) -> [Double] {
        guard let c = c?.usingColorSpace(.sRGB) else { return [0, 0, 0, 1] }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
    }
}

private extension URL {
    var creationDate: Date? { try? resourceValues(forKeys: [.creationDateKey]).creationDate }
}

// Stand-ins for PDF Expert's archived classes (keys read from its preferences).
@objc(PPRDInk) final class RDInk: NSObject, NSCoding {
    var uid = UUID().uuidString, strokes: [[Signature.Pt]] = [], width = 1.0, pdfScale = 36.0
    var size = CGSize(width: 3, height: 1), color: NSColor?
    init?(coder c: NSCoder) {
        uid = (c.decodeObject(forKey: "uid") as? String) ?? uid
        let paths = (c.decodeObject(forKey: "paths") as? [[NSDictionary]]) ?? []
        strokes = paths.map { $0.map { d in
            Signature.Pt(x: (d["x"] as? Double) ?? 0, y: (d["y"] as? Double) ?? 0, w: (d["width"] as? Double) ?? 0.5)
        } }
        width = c.decodeDouble(forKey: "width")
        pdfScale = c.decodeDouble(forKey: "pdfScale")
        size = NSSizeFromString((c.decodeObject(forKey: "size") as? String) ?? "{3, 1}")
        color = c.decodeObject(forKey: "color") as? NSColor
    }
    func encode(with coder: NSCoder) {}
}
@objc(PPRDText) final class RDText: NSObject, NSCoding {
    var uid = UUID().uuidString, name = "", font = "", pdfScale = 36.0, size = CGSize(width: 3, height: 1), color: NSColor?
    init?(coder c: NSCoder) {
        uid = (c.decodeObject(forKey: "uid") as? String) ?? uid
        name = (c.decodeObject(forKey: "name") as? String) ?? ""
        font = (c.decodeObject(forKey: "namePostScriptFontName") as? String) ?? ""
        pdfScale = c.decodeDouble(forKey: "pdfScale")
        size = NSSizeFromString((c.decodeObject(forKey: "size") as? String) ?? "{3, 1}")
        color = c.decodeObject(forKey: "color") as? NSColor
    }
    func encode(with coder: NSCoder) {}
}
@objc(PPRDImage) final class RDImage: NSObject, NSCoding {
    var uid = UUID().uuidString, imageData = Data(), pdfScale = 36.0
    init?(coder c: NSCoder) {
        uid = (c.decodeObject(forKey: "uid") as? String) ?? uid
        imageData = (c.decodeObject(forKey: "imageData") as? Data) ?? Data()
        pdfScale = c.decodeDouble(forKey: "pdfScale")
    }
    func encode(with coder: NSCoder) {}
}
