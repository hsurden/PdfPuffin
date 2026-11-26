import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

// More document tools: Split into Files, watermarks, Speech, Export Images, Remove
// Blank Pages, Remove Password, and printing/copying/editing permissions.

// MARK: - watermarks

/// A watermark: text or a picture drawn faintly across the page. It is a stamp
/// annotation that saves with its own appearance (so every PDF reader shows it) and
/// carries the author "PdfPuffin Watermark" (PDFKit keeps /T on save but drops /NM) so
/// Remove Watermark can find it after reopening.
final class WatermarkAnnotation: PDFAnnotation {
    static let namePrefix = "PdfPuffin Watermark"
    var text: String?
    var image: NSImage?
    var tint: NSColor = .gray
    var opacity: CGFloat = 0.25
    var angle: CGFloat = 45

    static func make(text: String?, image: NSImage?, tint: NSColor, opacity: CGFloat, diagonal: Bool, on page: PDFPage) -> WatermarkAnnotation {
        let box = page.bounds(for: .cropBox)
        let a = WatermarkAnnotation(bounds: box.insetBy(dx: box.width * 0.04, dy: box.height * 0.04), forType: .stamp, withProperties: nil)
        a.text = text; a.image = image; a.tint = tint; a.opacity = opacity
        a.angle = diagonal ? 45 : 0
        a.contents = text ?? "Watermark"
        a.userName = namePrefix
        a.isReadOnly = true
        return a
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let r = bounds
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.setAlpha(opacity)
        if let image {
            let s = min(r.width * 0.7 / max(image.size.width, 1), r.height * 0.7 / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * s, height: image.size.height * s)
            image.draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height))
            return
        }
        guard let text, !text.isEmpty else { return }
        // Fit the text along the diagonal (or across), filling about 80% of it.
        let span = angle == 0 ? r.width : hypot(r.width, r.height)
        let probe = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 100, weight: .bold)])
        let size = min(100 * span * 0.8 / max(probe.width, 1), r.height * 0.3)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: tint]
        let t = (text as NSString).size(withAttributes: attrs)
        context.translateBy(x: r.midX, y: r.midY)
        context.rotate(by: (angle == 0 ? 0 : atan2(r.height, r.width)))
        (text as NSString).draw(at: NSPoint(x: -t.width / 2, y: -t.height / 2), withAttributes: attrs)
    }
}

extension PDFAnnotation {
    /// Ours (by name, also after reopening) or another app's /Watermark annotation.
    var isWatermark: Bool {
        if self is WatermarkAnnotation || type == "Watermark" { return true }
        return userName == WatermarkAnnotation.namePrefix
    }
}

// MARK: - splitting

enum SplitPlan {
    /// Every `n` pages: 1–n, n+1–2n, …
    static func every(_ n: Int, pageCount: Int) -> [ClosedRange<Int>] {
        guard n > 0, pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: n).map { $0...min($0 + n - 1, pageCount - 1) }
    }

    /// One file per comma-separated part ("1-10, 11-20, 25"); nil if a part is invalid.
    static func ranges(_ input: String, numbers: PageNumbers) -> [ClosedRange<Int>]? {
        var out: [ClosedRange<Int>] = []
        for part in input.split(separator: ",") {
            guard let pages = numbers.pages(String(part), printed: false), let lo = pages.first, let hi = pages.last,
                  pages.count == hi - lo + 1 else { return nil }
            out.append(lo...hi)
        }
        return out.isEmpty ? nil : out
    }

    /// One file per top-level bookmark, each running to the next bookmark's page.
    static func bookmarks(_ doc: PDFDocument) -> [(String, ClosedRange<Int>)] {
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else { return [] }
        var starts: [(String, Int)] = []
        for i in 0..<root.numberOfChildren {
            guard let item = root.child(at: i), let page = item.destination?.page else { continue }
            let index = doc.index(for: page)
            guard index != NSNotFound, !starts.contains(where: { $0.1 == index }) else { continue }
            starts.append((item.label ?? "Part \(i + 1)", index))
        }
        starts.sort { $0.1 < $1.1 }
        guard !starts.isEmpty else { return [] }
        if starts[0].1 > 0 { starts.insert(("Front matter", 0), at: 0) }
        return starts.enumerated().map { k, s in
            (s.0, s.1...((k + 1 < starts.count ? starts[k + 1].1 : doc.pageCount) - 1))
        }
    }
}

// MARK: - blank pages

enum BlankPages {
    /// No text, no annotations, and almost no ink when drawn small.
    static func isBlank(_ page: PDFPage) -> Bool {
        if !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if page.annotations.contains(where: { $0.type != "Link" && $0.type != "Popup" }) { return false }
        // An RGB canvas: drawing colour pages into a greyscale one floods the log with warnings.
        let w = 80, h = 104
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let box = page.bounds(for: .cropBox)
        ctx.scaleBy(x: CGFloat(w) / max(box.width, 1), y: CGFloat(h) / max(box.height, 1))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .cropBox, to: ctx)
        guard let data = ctx.data else { return false }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var inked = 0
        for i in 0..<(w * h) where min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]) < 225 { inked += 1 }
        return Double(inked) / Double(w * h) < 0.002          // under 0.2% of the page
    }
}

// MARK: - images inside a PDF

enum PDFImages {
    struct Result { var saved: [URL] = []; var skipped = 0 }

    /// Saves every distinct image the pages use (JPEGs as-is, others as PNG).
    static func export(_ data: Data, baseName: String, to folder: URL) -> Result {
        var result = Result()
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { return result }
        var seen = Set<Int>()   // stream addresses: an image used on many pages is saved once
        for p in 1...max(1, pdf.numberOfPages) where p <= pdf.numberOfPages {
            guard let dict = pdf.page(at: p)?.dictionary else { continue }
            var n = 0
            walk(resources: dict, depth: 0) { stream in
                guard seen.insert(unsafeBitCast(stream, to: Int.self)).inserted else { return }
                n += 1
                let stem = "\(baseName) - p\(p) - image \(n)"
                if let url = save(stream, stem: stem, folder: folder) { result.saved.append(url) } else { result.skipped += 1 }
            }
        }
        return result
    }

    /// Calls `found` for each image XObject, also inside form XObjects.
    private static func walk(resources owner: CGPDFDictionaryRef, depth: Int, _ found: (CGPDFStreamRef) -> Void) {
        guard depth < 6 else { return }
        var res: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(owner, "Resources", &res), let res,
              CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xobjects else { return }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var s: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &s), let s { streams.append(s) }
            return true
        }, nil)
        for s in streams {
            guard let d = CGPDFStreamGetDictionary(s) else { continue }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(d, "Subtype", &subtype), let subtype else { continue }
            switch String(cString: subtype) {
            case "Image": found(s)
            case "Form": walk(resources: d, depth: depth + 1, found)
            default: break
            }
        }
    }

    private static func save(_ stream: CGPDFStreamRef, stem: String, folder: URL) -> URL? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, let d = CGPDFStreamGetDictionary(stream) else { return nil }
        switch format {
        case .jpegEncoded: return write(data, folder, stem, "jpg")
        case .JPEG2000: return write(data, folder, stem, "jp2")
        default: break
        }
        var w = 0, h = 0, bpc = 0
        guard CGPDFDictionaryGetInteger(d, "Width", &w), CGPDFDictionaryGetInteger(d, "Height", &h), w > 0, h > 0 else { return nil }
        if !CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bpc) { bpc = 8 }
        guard bpc == 8, let (space, comps) = colorSpace(d), data.count >= w * h * comps,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * comps, bytesPerRow: w * comps,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return write(png, folder, stem, "png")
    }

    private static func colorSpace(_ d: CGPDFDictionaryRef) -> (CGColorSpace, Int)? {
        var name: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(d, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceRGB": return (CGColorSpaceCreateDeviceRGB(), 3)
            case "DeviceGray": return (CGColorSpaceCreateDeviceGray(), 1)
            case "DeviceCMYK": return (CGColorSpaceCreateDeviceCMYK(), 4)
            default: return nil
            }
        }
        // [/ICCBased <stream with /N>]
        var array: CGPDFArrayRef?, kind: UnsafePointer<Int8>?, icc: CGPDFStreamRef?
        guard CGPDFDictionaryGetArray(d, "ColorSpace", &array), let array,
              CGPDFArrayGetName(array, 0, &kind), let kind, String(cString: kind) == "ICCBased",
              CGPDFArrayGetStream(array, 1, &icc), let icc, let iccDict = CGPDFStreamGetDictionary(icc) else { return nil }
        var n = 0
        CGPDFDictionaryGetInteger(iccDict, "N", &n)
        switch n {
        case 1: return (CGColorSpaceCreateDeviceGray(), 1)
        case 3: return (CGColorSpaceCreateDeviceRGB(), 3)
        case 4: return (CGColorSpaceCreateDeviceCMYK(), 4)
        default: return nil
        }
    }

    private static func write(_ data: Data, _ folder: URL, _ stem: String, _ ext: String) -> URL? {
        let url = folder.appendingPathComponent(stem.replacingOccurrences(of: "/", with: "-") + "." + ext)
        return (try? data.write(to: url, options: .withoutOverwriting)) != nil ? url : nil
    }
}

// MARK: - commands

extension MainWindowController {

    // File ▸ Split into Files…

    @objc func splitIntoFiles(_ sender: Any?) {
        guard let d = current else { return }
        d.textEditor?.commit()
        let bookmarkParts = SplitPlan.bookmarks(d.document)
        let a = NSAlert()
        a.messageText = "Split into Files"
        a.informativeText = "Each part is saved as its own PDF in a folder you choose. The open document is not changed."
        let mode = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 300, height: 26), pullsDown: false)
        mode.addItems(withTitles: ["Every N pages", "Page ranges (one file each)", "At each top-level bookmark"])
        mode.item(at: 2)?.isEnabled = !bookmarkParts.isEmpty
        mode.autoenablesItems = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = "10"
        field.placeholderString = "Pages per file, e.g. 10"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        box.addSubview(mode); box.addSubview(field)
        a.accessoryView = box
        a.addButton(withTitle: "Choose Folder…")
        a.addButton(withTitle: "Cancel")
        let switcher = SplitModeWatcher(mode: mode, field: field)
        mode.target = switcher; mode.action = #selector(SplitModeWatcher.changed)

        var parts: [(String?, ClosedRange<Int>)] = []
        while true {
            guard a.runModal() == .alertFirstButtonReturn else { return }
            switch mode.indexOfSelectedItem {
            case 0:
                if let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), n > 0 {
                    parts = SplitPlan.every(n, pageCount: d.pageCount).map { (nil, $0) }
                }
            case 1:
                let numbers = PageNumbers(labels: (0..<d.pageCount).map { String($0 + 1) })
                parts = (SplitPlan.ranges(field.stringValue, numbers: numbers) ?? []).map { (nil, $0) }
            default:
                parts = bookmarkParts.map { ($0.0, $0.1) }
            }
            if !parts.isEmpty { break }
            a.informativeText = mode.indexOfSelectedItem == 0
                ? "Type how many pages go in each file."
                : "Type ranges such as 1-10, 11-25, 26 (pages 1 to \(d.pageCount))."
        }
        _ = switcher

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save \(parts.count) Files Here"
        panel.directoryURL = d.fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        // Work from a saved copy so signatures and stamps keep their appearance.
        let source: () -> PDFDocument? = { d.document.dataRepresentation().flatMap(PDFDocument.init(data:)).flatMap { $0.isLocked ? nil : $0 } }
        var written: [URL] = []
        for (title, range) in parts {
            guard let part = source() else { break }
            for i in stride(from: part.pageCount - 1, through: 0, by: -1) where !range.contains(i) { part.removePage(at: i) }
            part.outlineRoot = nil
            let pages = IndexSet(integersIn: range)
            let base = title.map { "\(d.displayName) - \($0.replacingOccurrences(of: "/", with: "-"))" } ?? d.excerptName(for: pages)
            var url = folder.appendingPathComponent(base + ".pdf")
            var k = 2
            while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(k).pdf"); k += 1 }
            if part.write(to: url) { written.append(url) }
        }
        if written.count == parts.count {
            flash("Saved \(written.count) files")
            NSWorkspace.shared.activateFileViewerSelecting(written)
        } else {
            let e = NSAlert()
            e.messageText = "Saved \(written.count) of \(parts.count) files"
            e.informativeText = "PDFKit couldn't write the rest. Try another folder."
            e.runModal()
        }
    }

    // Edit ▸ Add Watermark… / Remove Watermark

    @objc func addWatermark(_ sender: Any?) {
        guard let d = current else { return }
        let a = NSAlert()
        a.messageText = "Add Watermark"
        a.informativeText = "Adds faint text or a picture across the pages. Undo or Edit ▸ Remove Watermark takes it off."
        let text = NSTextField(frame: NSRect(x: 0, y: 96, width: 300, height: 24))
        text.stringValue = "CONFIDENTIAL"
        let picture = NSButton(checkboxWithTitle: "Use a picture instead…", target: nil, action: nil)
        picture.frame = NSRect(x: 0, y: 70, width: 300, height: 20)
        let colour = NSPopUpButton(frame: NSRect(x: 0, y: 36, width: 145, height: 26), pullsDown: false)
        colour.addItems(withTitles: ["Grey", "Red", "Blue", "Black"])
        let strength = NSPopUpButton(frame: NSRect(x: 155, y: 36, width: 145, height: 26), pullsDown: false)
        strength.addItems(withTitles: ["Light", "Medium", "Strong"])
        strength.selectItem(at: 1)
        let layout = NSPopUpButton(frame: NSRect(x: 0, y: 2, width: 145, height: 26), pullsDown: false)
        layout.addItems(withTitles: ["Diagonal", "Horizontal"])
        let pages = NSPopUpButton(frame: NSRect(x: 155, y: 2, width: 145, height: 26), pullsDown: false)
        pages.addItems(withTitles: ["All pages", "This page"])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 122))
        for v in [text, picture, colour, strength, layout, pages] as [NSView] { box.addSubview(v) }
        a.accessoryView = box
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = text
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var image: NSImage?
        if picture.state == .on {
            let p = NSOpenPanel()
            p.allowedContentTypes = [.image]
            p.message = "Choose a picture for the watermark (a logo works best)."
            guard p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) else { return }
            image = img
        }
        let words = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard image != nil || !words.isEmpty else { NSSound.beep(); return }
        let tint: NSColor = [NSColor(white: 0.45, alpha: 1), .systemRed, .systemBlue, .black][colour.indexOfSelectedItem]
        let opacity: CGFloat = [0.14, 0.25, 0.4][strength.indexOfSelectedItem]
        let targets = pages.indexOfSelectedItem == 0 ? Array(0..<d.pageCount) : [d.currentPageIndex]
        let marks: [(PDFPage, PDFAnnotation)] = targets.compactMap { i in
            guard let page = d.document.page(at: i) else { return nil }
            return (page, WatermarkAnnotation.make(text: image == nil ? words : nil, image: image, tint: tint, opacity: opacity,
                                                  diagonal: layout.indexOfSelectedItem == 0, on: page))
        }
        d.addAnnotations(marks, name: "Add Watermark")
        flash("Watermark added to \(marks.count) page\(marks.count == 1 ? "" : "s")")
    }

    @objc func removeWatermark(_ sender: Any?) {
        guard let d = current else { return }
        var found: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<d.pageCount {
            guard let page = d.document.page(at: i) else { continue }
            for a in page.annotations where a.isWatermark { found.append((page, a)) }
        }
        guard !found.isEmpty else {
            let a = NSAlert()
            a.messageText = "No removable watermark found"
            a.informativeText = "PdfPuffin removes watermarks added as annotations, by PdfPuffin or other apps. A watermark drawn into the page itself can't be separated from the page."
            a.runModal()
            return
        }
        d.removeAnnotations(found, name: "Remove Watermark")
        flash("Removed the watermark from \(Set(found.map { ObjectIdentifier($0.0) }).count) page(s) (⌘Z to undo)")
    }

    // Edit ▸ Speech

    @objc func startSpeaking(_ sender: Any?) { if let d = current { ReadAloud.shared.start(d) } }
    @objc func stopSpeaking(_ sender: Any?) { ReadAloud.shared.stop() }

    // File ▸ Export To ▸ Images in PDF…

    @objc func exportEmbeddedImages(_ sender: Any?) {
        guard let d = current, let data = d.document.dataRepresentation() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Images Here"
        panel.message = "Saves the pictures inside the PDF at their original resolution."
        panel.directoryURL = d.fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let r = PDFImages.export(data, baseName: d.displayName, to: folder)
        let a = NSAlert()
        if r.saved.isEmpty && r.skipped == 0 {
            a.messageText = "This PDF has no pictures"
            a.informativeText = "Its pages are text and drawings. To save whole pages as images, use File ▸ Export To ▸ Image."
            a.runModal()
            return
        }
        a.messageText = "Saved \(r.saved.count) image\(r.saved.count == 1 ? "" : "s")"
        if r.skipped > 0 {
            a.informativeText = "\(r.skipped) more use a format PdfPuffin can't save on its own (such as indexed colour or masks). File ▸ Export To ▸ Image saves whole pages instead."
        }
        a.runModal()
        if !r.saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(r.saved) }
    }

    // Edit ▸ Remove Blank Pages…

    @objc func removeBlankPages(_ sender: Any?) {
        guard let d = current else { return }
        let blank = IndexSet((0..<d.pageCount).filter { d.document.page(at: $0).map(BlankPages.isBlank) ?? false })
        let a = NSAlert()
        guard !blank.isEmpty else {
            a.messageText = "No blank pages found"
            a.informativeText = "A page counts as blank when it has no text, no annotations and almost nothing drawn on it."
            a.runModal()
            return
        }
        guard blank.count < d.pageCount else {
            a.messageText = "Every page looks blank"
            a.informativeText = "Nothing was removed. A document needs at least one page."
            a.runModal()
            return
        }
        a.messageText = "Remove \(blank.count) blank page\(blank.count == 1 ? "" : "s")?"
        a.informativeText = "Page\(blank.count == 1 ? "" : "s") \(ThumbnailsPane.describe(blank)). You can undo this."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if d.changePages(blank, before: nil) { flash("Removed \(blank.count) blank page\(blank.count == 1 ? "" : "s") (⌘Z to undo)") }
    }

    // File ▸ Remove Password…

    @objc func removePassword(_ sender: Any?) {
        guard let d = current, d.document.isEncrypted else { return }
        d.textEditor?.commit()
        guard let url = askSaveURL(d, suffix: " (unprotected)", ext: "pdf",
                                   message: "Saves a copy without the password or restrictions. The open document is not changed.") else { return }
        if isOpenElsewhere(url, except: d) { refuseOpenFile(url); return }
        guard let copy = Self.unencryptedCopy(of: d.document), copy.write(to: url) else { failed(url); return }
        noteRecent(url)
        flash("Saved “\(url.lastPathComponent)” without a password")
    }

    /// Saving an unlocked PDF keeps its encryption, so copy the pages, outline and
    /// title into a fresh document instead.
    static func unencryptedCopy(of doc: PDFDocument) -> PDFDocument? {
        guard !doc.isLocked else { return nil }
        let fresh = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { return nil }
            fresh.insert(page, at: fresh.pageCount)
        }
        fresh.outlineRoot = doc.outlineRoot
        fresh.documentAttributes = doc.documentAttributes
        return fresh
    }

    // MARK: menu state

    func validateMoreItem(_ item: NSMenuItem) -> Bool? {
        let d = current
        switch item.action {
        case #selector(removePassword(_:)):
            return d?.document.isEncrypted == true && d?.document.isLocked == false
        case #selector(splitIntoFiles(_:)):
            return (d?.pageCount ?? 0) > 1
        case #selector(removeBlankPages(_:)):
            return (d?.pageCount ?? 0) > 1
        case #selector(startSpeaking(_:)):
            return d != nil && !ReadAloud.shared.isSpeaking
        case #selector(stopSpeaking(_:)):
            return ReadAloud.shared.isSpeaking
        default:
            return nil
        }
    }
}

/// Swaps the Split dialog's field between "pages per file" and "page ranges".
final class SplitModeWatcher: NSObject {
    let mode: NSPopUpButton, field: NSTextField
    init(mode: NSPopUpButton, field: NSTextField) { self.mode = mode; self.field = field }
    @objc func changed() {
        switch mode.indexOfSelectedItem {
        case 0: field.isEnabled = true; field.stringValue = "10"; field.placeholderString = "Pages per file, e.g. 10"
        case 1: field.isEnabled = true; field.stringValue = ""; field.placeholderString = "e.g. 1-10, 11-25, 26"
        default: field.isEnabled = false; field.stringValue = ""; field.placeholderString = "One file per bookmark"
        }
    }
}
