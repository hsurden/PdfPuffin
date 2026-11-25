import AppKit
import PDFKit

/// Shape tools: drag anywhere on a page to draw one. Hold ⇧ for a square / circle.
enum ShapeTool: String, CaseIterable {
    case rectangle, oval, area, text, pen, eraser, line, arrow, note, signature, date, check, cross, stamp

    var title: String {
        ["Rectangle", "Oval", "Highlight Area", "Text", "Pen", "Eraser", "Line", "Arrow", "Note", "Signature",
         "Date", "Checkmark", "Cross", "Stamp"][index]
    }
    var symbol: String {
        ["rectangle", "circle", "rectangle.inset.filled", "character.textbox", "pencil.tip", "eraser",
         "line.diagonal", "arrow.up.right", "text.bubble", "signature", "calendar", "checkmark", "xmark", "seal"][index]
    }
    /// Fill & Sign tools placed with a single click.
    var isClickPlaced: Bool { [.date, .check, .cross, .stamp].contains(self) }
    /// Tools listed under the Shapes button.
    static let shapes: [ShapeTool] = [.rectangle, .oval, .line, .arrow, .area]
    var isShape: Bool { Self.shapes.contains(self) }
    /// Tools with a line thickness setting.
    var hasWidth: Bool { [.rectangle, .oval, .line, .arrow, .pen].contains(self) }
    private var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// The colours offered in the tool row and Annotate ▸ Color. Each tool remembers
/// its own colour (as PDF Expert does), stored in UserDefaults.
enum AnnotColors {
    static let palette: [(String, NSColor)] = [
        ("Red", NSColor(srgbRed: 0.90, green: 0.16, blue: 0.16, alpha: 1)),
        ("Orange", NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1)),
        ("Yellow", NSColor(srgbRed: 1.00, green: 0.84, blue: 0.10, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.20, green: 0.70, blue: 0.30, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.60, green: 0.30, blue: 0.85, alpha: 1)),
        ("Black", NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)),
    ]

    /// Tool keys: "highlight", "underline", "strikeOut", or a ShapeTool raw value.
    static let defaults: [String: Int] = [
        "highlight": 2, "underline": 4, "strikeOut": 0, "rectangle": 0, "oval": 0, "area": 2, "text": 0,
        "pen": 0, "line": 0, "arrow": 0, "note": 2, "date": 6, "check": 6, "cross": 6, "stamp": 0,
    ]

    static func key(for subtype: PDFAnnotationSubtype) -> String {
        switch subtype {
        case .highlight: return "highlight"
        case .underline: return "underline"
        default: return "strikeOut"
        }
    }

    static func index(for key: String) -> Int {
        (UserDefaults.standard.object(forKey: "color:" + key) as? Int) ?? defaults[key] ?? 0
    }
    static func color(for key: String) -> NSColor { palette[min(index(for: key), palette.count - 1)].1 }
    static func set(_ i: Int, for key: String) { UserDefaults.standard.set(i, forKey: "color:" + key) }

    static let widths: [CGFloat] = [1, 2, 3, 5, 8]
    static func width(for key: String) -> CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "width:" + key) as? Double) ?? (key == "pen" ? 2 : 2.5))
    }
    static func setWidth(_ w: CGFloat, for key: String) { UserDefaults.standard.set(Double(w), forKey: "width:" + key) }

    /// A round colour swatch for menus and the tool row.
    static func swatch(_ c: NSColor, size: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }
}

extension PuffinPDFView {
    /// PDFKit's tiled drawing ignores bounds changes; re-adding forces a repaint.
    func refresh(_ a: PDFAnnotation, on page: PDFPage) {
        page.removeAnnotation(a)
        page.addAnnotation(a)
        repaint(page)
    }

    /// Repaints `page` after an annotation change. In split view PDFKit's light
    /// repaint is unreliable in both panes, so each pane is re-laid out instead.
    func repaint(_ page: PDFPage) {
        let panes = owner?.readingPanes ?? [self]
        annotationsChanged(on: page)
        if panes.count < 2 { return }
        // Both panes draw the same page; PDFKit only refreshes whichever asks last,
        // so ask again for each pane on its own run-loop turn.
        for (i, pane) in panes.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i + 1)) { [weak pane] in
                pane?.relayoutKeepingPosition()
            }
        }
    }

    /// Re-lays out the pages (which redraws cached tiles) without moving the view.
    func relayoutKeepingPosition() {
        let clip = documentView?.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        layoutDocumentView()
        if let clip, let origin {
            clip.scroll(to: origin)
            documentView?.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Mouse handling while a page tool is armed (shapes, pen, eraser, text).
    /// Returns false when no tool is armed (normal PDF mouse handling).
    func shapeMouse(_ e: NSEvent, phase: Int) -> Bool {
        guard let d = owner, let tool = d.shapeTool else { return false }
        let p = convert(e.locationInWindow, from: nil)
        if phase == 0 {
            guard let page = page(for: p, nearest: true) else { return true }
            let start = convert(p, to: page)
            switch tool {
            case .text:
                DispatchQueue.main.async { d.editText(nil, on: page, at: start) }
                return true
            case .eraser:
                eraserPage = page
                erase(at: start, on: page)
                return true
            case .date, .check, .cross, .stamp:
                placeFillMark(tool, on: page, at: start)
                return true
            case .signature:                                  // placed on mouse-up only
                signatureStart = (page, start)
                return true
            case .note:
                let pb = page.bounds(for: displayBox)
                let x = min(max(start.x - 12, pb.minX), max(pb.minX, pb.maxX - 24))
                let y = min(max(start.y - 12, pb.minY), max(pb.minY, pb.maxY - 24))
                let a = PDFAnnotation(bounds: NSRect(x: x, y: y, width: 24, height: 24), forType: .text, withProperties: nil)
                a.color = AnnotColors.color(for: "note")
                a.iconType = .comment
                a.userName = NSFullUserName()
                a.modificationDate = Date()
                page.addAnnotation(a)
                repaint(page)
                d.shapeTool = nil
                DispatchQueue.main.async { d.openNoteCard(for: a, on: page, isNew: true) }
                return true
            default:
                let a = Self.makeAnnotation(tool, from: start, to: start, points: [start], page: page)
                page.addAnnotation(a)
                drawing = (a, page, start)
                inkPoints = [start]
                NSCursor.crosshair.set()
                return true
            }
        }
        if tool == .signature {
            guard phase == 2, let (page, start) = signatureStart else { return true }
            signatureStart = nil
            var q = convert(p, to: page)
            let pb = page.bounds(for: displayBox)
            q.x = min(max(q.x, pb.minX), pb.maxX); q.y = min(max(q.y, pb.minY), pb.maxY)
            if let signature = SignatureStore.selected {
                placeSignature(signature, on: page, from: start, to: q)
            }
            return true
        }
        if tool == .eraser {
            if let page = eraserPage { erase(at: convert(p, to: page), on: page) }
            if phase == 2 { eraserPage = nil }
            return true
        }
        guard let (old, page, start) = drawing else { return true }
        var q = convert(p, to: page)
        let pb = page.bounds(for: displayBox)
        q.x = min(max(q.x, pb.minX), pb.maxX)
        q.y = min(max(q.y, pb.minY), pb.maxY)
        if tool == .pen { inkPoints.append(q) }
        if e.modifierFlags.contains(.shift), tool != .pen {       // square / circle / 45° line
            var w = q.x - start.x, h = q.y - start.y
            if tool == .line || tool == .arrow {
                if abs(w) > abs(h) * 2 { h = 0 } else if abs(h) > abs(w) * 2 { w = 0 }
                else { let s = max(abs(w), abs(h)); w = w < 0 ? -s : s; h = h < 0 ? -s : s }
            } else {
                let s = max(abs(w), abs(h)); w = w < 0 ? -s : s; h = h < 0 ? -s : s
            }
            q = NSPoint(x: start.x + w, y: start.y + h)
        }
        // Rebuild the annotation (PDFKit does not repaint geometry changes reliably).
        let a = Self.makeAnnotation(tool, from: start, to: q, points: inkPoints, page: page)
        page.removeAnnotation(old)
        page.addAnnotation(a)
        repaint(page)
        drawing = (a, page, start)
        if phase == 2 {
            drawing = nil
            let tiny = tool == .pen ? inkPoints.count < 2 : hypot(q.x - start.x, q.y - start.y) < 4
            if tiny { page.removeAnnotation(a); repaint(page) }
            else { d.recordAdded(a, on: page, name: "Add \(tool.title)") }
        }
        return true
    }

    func placeSignature(_ signature: Signature, on page: PDFPage, from start: NSPoint, to end: NSPoint) {
        guard let doc = owner, signature.height > 0, signature.aspect > 0 else { return }
        let box = page.bounds(for: displayBox)
        let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
        let sized = dx >= 4 && dy >= 4
        let height = min(sized ? min(dy, dx / signature.aspect) : signature.height,
                         box.height, box.width / signature.aspect)
        let width = height * signature.aspect
        let x = sized ? min(start.x, end.x) : start.x - width / 2
        let y = sized ? min(start.y, end.y) : start.y - height / 2
        let rect = NSRect(x: min(max(x, box.minX), box.maxX - width),
                          y: min(max(y, box.minY), box.maxY - height), width: width, height: height)
        doc.activatePane(self)
        let stamp = SignatureAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
        stamp.signature = signature
        stamp.userName = NSFullUserName()
        stamp.modificationDate = Date()
        page.addAnnotation(stamp)
        repaint(page)
        doc.recordAdded(stamp, on: page, name: "Add Signature")
        doc.shapeTool = nil
        doc.thumbnailsActive = false
        doc.selection = AnnotationSelection(doc: doc, page: page, annotation: stamp)
        window?.makeFirstResponder(self)
    }

    /// Removes the annotations under the eraser (whole annotations).
    private func erase(at pt: NSPoint, on page: PDFPage) {
        let hits = page.annotations.filter { a in
            AnnotationsPane.kinds.contains(a.type ?? "") && a.bounds.insetBy(dx: -3, dy: -3).contains(pt)
                && (a.type != "Ink" || Self.inkHit(a, pt))
        }
        guard !hits.isEmpty else { return }
        for a in hits { owner?.removeAnnotation(a) }        // undoable
        repaint(page)
    }

    private static func inkHit(_ a: PDFAnnotation, _ pt: NSPoint) -> Bool {
        let local = NSPoint(x: pt.x - a.bounds.minX, y: pt.y - a.bounds.minY)
        for path in a.paths ?? [] {
            var pts = [NSPoint](repeating: .zero, count: 3)
            for i in 0..<path.elementCount {
                path.element(at: i, associatedPoints: &pts)
                if hypot(pts[0].x - local.x, pts[0].y - local.y) < 8 { return true }
            }
        }
        return false
    }

    static func makeAnnotation(_ tool: ShapeTool, from s: NSPoint, to q: NSPoint, points: [NSPoint], page: PDFPage) -> PDFAnnotation {
        let color = AnnotColors.color(for: tool.rawValue).withAlphaComponent(AnnotColors.opacity(for: tool.rawValue))
        let lw = AnnotColors.width(for: tool.rawValue)
        let border = PDFBorder()
        border.lineWidth = lw
        let a: PDFAnnotation
        switch tool {
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            let r = NSRect(x: (xs.min() ?? s.x) - lw, y: (ys.min() ?? s.y) - lw,
                           width: (xs.max() ?? s.x) - (xs.min() ?? s.x) + lw * 2,
                           height: (ys.max() ?? s.y) - (ys.min() ?? s.y) + lw * 2)
            a = PDFAnnotation(bounds: r, forType: .ink, withProperties: nil)
            let path = NSBezierPath()
            path.lineWidth = lw
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (i, pt) in points.enumerated() {
                let l = NSPoint(x: pt.x - r.minX, y: pt.y - r.minY)
                if i == 0 { path.move(to: l) } else { path.line(to: l) }
            }
            a.add(path)
            a.color = color
        case .line, .arrow:
            let pad = lw * 4 + 6
            let r = NSRect(x: min(s.x, q.x) - pad, y: min(s.y, q.y) - pad,
                           width: abs(q.x - s.x) + pad * 2, height: abs(q.y - s.y) + pad * 2)
            a = PDFAnnotation(bounds: r, forType: .line, withProperties: nil)
            a.startPoint = NSPoint(x: s.x - r.minX, y: s.y - r.minY)
            a.endPoint = NSPoint(x: q.x - r.minX, y: q.y - r.minY)
            a.endLineStyle = tool == .arrow ? .openArrow : .none
            a.color = color
        default:
            let r = NSRect(x: min(s.x, q.x), y: min(s.y, q.y), width: abs(q.x - s.x), height: abs(q.y - s.y))
            a = PDFAnnotation(bounds: r, forType: tool == .oval ? .circle : .square, withProperties: nil)
            if tool == .area {
                a.color = .clear
                a.interiorColor = AnnotColors.color(for: "area").withAlphaComponent(0.35)
                border.lineWidth = 0
            } else {
                a.color = color
                let fi = AnnotColors.fillIndex(for: tool.rawValue)
                if fi >= 0, fi < AnnotColors.palette.count {
                    a.interiorColor = AnnotColors.palette[fi].1.withAlphaComponent(0.3 * AnnotColors.opacity(for: tool.rawValue))
                }
            }
        }
        a.border = border
        a.userName = NSFullUserName()
        a.modificationDate = Date()
        return a
    }
}

// MARK: - Text boxes

/// Remembered text style (font family, size, bold, italic; colour lives in AnnotColors["text"]).
enum TextStyle {
    static var family: String {
        get { UserDefaults.standard.string(forKey: "text.family") ?? "Helvetica" }
        set { UserDefaults.standard.set(newValue, forKey: "text.family") }
    }
    static var size: CGFloat {
        get { CGFloat((UserDefaults.standard.object(forKey: "text.size") as? Double) ?? 14) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "text.size") }
    }
    static var bold: Bool {
        get { UserDefaults.standard.bool(forKey: "text.bold") }
        set { UserDefaults.standard.set(newValue, forKey: "text.bold") }
    }
    static var whiteBackground: Bool {
        get { UserDefaults.standard.bool(forKey: "text.whiteBackground") }
        set { UserDefaults.standard.set(newValue, forKey: "text.whiteBackground") }
    }
    static var italic: Bool {
        get { UserDefaults.standard.bool(forKey: "text.italic") }
        set { UserDefaults.standard.set(newValue, forKey: "text.italic") }
    }

    static func font(family: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

extension DocumentViewController {
    /// Starts typing directly on the page: a new box at `point` (its top-left), or
    /// the existing text box `existing`.
    func editText(_ existing: PDFAnnotation?, on page: PDFPage, at point: NSPoint) {
        textEditor?.commit()
        let anchor = existing.map { NSPoint(x: $0.bounds.minX, y: $0.bounds.maxY) } ?? point
        let ed = InlineTextEditor(doc: self, page: page, anchor: anchor, existing: existing)
        textEditor = ed
        ed.start()
    }
}

extension NSColor {
    func isClose(to o: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = o.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.05 && abs(a.greenComponent - b.greenComponent) < 0.05
            && abs(a.blueComponent - b.blueComponent) < 0.05
    }
}


/// The editable parts of an annotation, for Undo / Redo of moves, resizes and style/text edits.
struct AnnotSnapshot {
    var bounds: NSRect
    var contents: String?
    var font: NSFont?
    var fontColor: NSColor?
    var color: NSColor
    var interiorColor: NSColor?
    var lineWidth: CGFloat?
    var startPoint: NSPoint?
    var endPoint: NSPoint?
    var paths: [NSBezierPath]?

    init(_ a: PDFAnnotation) {
        bounds = a.bounds
        contents = a.contents
        font = a.font
        fontColor = a.fontColor
        color = a.color
        interiorColor = a.interiorColor
        lineWidth = a.border?.lineWidth
        startPoint = a.type == "Line" ? a.startPoint : nil
        endPoint = a.type == "Line" ? a.endPoint : nil
        paths = a.type == "Ink" ? a.paths?.map { $0.copy() as! NSBezierPath } : nil
    }

    func apply(to a: PDFAnnotation) {
        a.bounds = bounds
        a.contents = contents
        if a.type == "FreeText" {
            if let font { a.font = font }
            if let fontColor { a.fontColor = fontColor }
        }
        a.color = color
        if ["Square", "Circle"].contains(a.type ?? "") {
            a.interiorColor = interiorColor
        }
        if let lw = lineWidth {
            let b = a.border ?? PDFBorder()
            b.lineWidth = lw
            a.border = b
        }
        if a.type == "Line", let sp = startPoint, let ep = endPoint {
            a.startPoint = sp
            a.endPoint = ep
        }
        if a.type == "Ink", let saved = paths {
            for p in a.paths ?? [] { a.remove(p) }
            for p in saved { a.add(p.copy() as! NSBezierPath) }
        }
    }
}
