import AppKit
import PDFKit

/// Click a placed annotation (with no tool armed) to select it, as in PDF Expert:
/// a dashed box with handles. Drag inside to move, drag a corner or line endpoint
/// to resize (signatures keep their proportions), Delete removes it, Esc / click elsewhere deselects.
final class AnnotationSelection {
    static let selectable: Set<String> = [
        "Stamp", "Square", "Circle", "Line", "Ink", "FreeText", "Text",
        "Highlight", "Underline", "StrikeOut"
    ]

    weak var doc: DocumentViewController?
    let page: PDFPage
    private(set) var annotation: PDFAnnotation
    private let overlay = SelectionOverlay()
    private var observers: [NSObjectProtocol] = []

    private enum Drag { case move, corner(Int), lineStart, lineEnd }   // corners: 0 BL, 1 BR, 2 TL, 3 TR (page space)
    private var drag: Drag?
    private var dragStart = NSPoint.zero
    private var startBounds = NSRect.zero
    private var startSnapshot: AnnotSnapshot?
    private var moved = false

    init(doc: DocumentViewController, page: PDFPage, annotation: PDFAnnotation) {
        self.doc = doc; self.page = page; self.annotation = annotation
        overlay.resizable = Self.canResize(annotation)
        doc.pdfView.addSubview(overlay)
        layout()
        let nc = NotificationCenter.default
        if let clip = doc.pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.layout() })
        }
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: doc.pdfView, queue: .main) { [weak self] _ in self?.layout() })
    }

    static func canMove(_ a: PDFAnnotation) -> Bool {
        ["Stamp", "Square", "Circle", "Line", "Ink", "FreeText", "Text"].contains(a.type ?? "")
    }

    static func canResize(_ a: PDFAnnotation) -> Bool {
        ["Stamp", "Square", "Circle", "FreeText", "Ink"].contains(a.type ?? "")
    }

    static func isLine(_ a: PDFAnnotation) -> Bool { a.type == "Line" }

    /// The topmost selectable annotation at a page point.
    static func hit(_ page: PDFPage, _ p: NSPoint) -> PDFAnnotation? {
        page.annotations.reversed().first { a in
            selectable.contains(a.type ?? "") && !a.isWatermark && a.bounds.insetBy(dx: -4, dy: -4).contains(p)
        }
    }

    func layout() {
        guard let pdf = doc?.pdfView else { return }
        overlay.frame = pdf.convert(annotation.bounds, from: page).insetBy(dx: -SelectionOverlay.pad, dy: -SelectionOverlay.pad)
        if Self.isLine(annotation) {
            let p1 = NSPoint(x: annotation.bounds.minX + annotation.startPoint.x,
                             y: annotation.bounds.minY + annotation.startPoint.y)
            let p2 = NSPoint(x: annotation.bounds.minX + annotation.endPoint.x,
                             y: annotation.bounds.minY + annotation.endPoint.y)
            let v1 = overlay.convert(pdf.convert(p1, from: page), from: pdf)
            let v2 = overlay.convert(pdf.convert(p2, from: page), from: pdf)
            overlay.lineEndpoints = (v1, v2)
        } else {
            overlay.lineEndpoints = nil
        }
    }

    func end() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        overlay.removeFromSuperview()
    }

    /// Mouse down at a window point. Returns true if it starts a move or resize.
    func begin(at windowPoint: NSPoint) -> Bool {
        guard let pdf = doc?.pdfView, Self.canMove(annotation) else { return false }
        let local = overlay.convert(windowPoint, from: nil)
        let p = pdf.convert(pdf.convert(windowPoint, from: nil), to: page)
        if Self.isLine(annotation), let ep = overlay.lineEndpoint(at: local) {
            drag = ep == 0 ? .lineStart : .lineEnd
        } else if overlay.resizable, let c = overlay.corner(at: local) {
            drag = .corner(c)
        } else if annotation.bounds.insetBy(dx: -4, dy: -4).contains(p) {
            drag = .move
        } else {
            return false
        }
        dragStart = p
        startBounds = annotation.bounds
        startSnapshot = AnnotSnapshot(annotation)
        moved = false
        return true
    }

    func dragged(to windowPoint: NSPoint, shift: Bool) {
        guard let drag, let pdf = doc?.pdfView else { return }
        let p = pdf.convert(pdf.convert(windowPoint, from: nil), to: page)
        let pb = page.bounds(for: pdf.displayBox)
        switch drag {
        case .lineStart, .lineEnd:
            let isStart: Bool
            if case .lineStart = drag { isStart = true } else { isStart = false }
            let origStart = NSPoint(x: startBounds.minX + (startSnapshot?.startPoint?.x ?? annotation.startPoint.x),
                                    y: startBounds.minY + (startSnapshot?.startPoint?.y ?? annotation.startPoint.y))
            let origEnd = NSPoint(x: startBounds.minX + (startSnapshot?.endPoint?.x ?? annotation.endPoint.x),
                                  y: startBounds.minY + (startSnapshot?.endPoint?.y ?? annotation.endPoint.y))
            let fixed = isStart ? origEnd : origStart
            var moving = NSPoint(x: min(max(p.x, pb.minX), pb.maxX), y: min(max(p.y, pb.minY), pb.maxY))
            if shift {
                var w = moving.x - fixed.x, h = moving.y - fixed.y
                if abs(w) > abs(h) * 2 { h = 0 }
                else if abs(h) > abs(w) * 2 { w = 0 }
                else { let s = max(abs(w), abs(h)); w = w < 0 ? -s : s; h = h < 0 ? -s : s }
                moving = NSPoint(x: min(max(fixed.x + w, pb.minX), pb.maxX),
                                 y: min(max(fixed.y + h, pb.minY), pb.maxY))
            }
            let s = isStart ? moving : fixed
            let e = isStart ? fixed : moving
            let pad = (annotation.border?.lineWidth ?? 2.5) * 4 + 6
            let r = NSRect(x: min(s.x, e.x) - pad, y: min(s.y, e.y) - pad,
                           width: max(abs(e.x - s.x) + pad * 2, 12), height: max(abs(e.y - s.y) + pad * 2, 12))
            annotation.bounds = r
            annotation.startPoint = NSPoint(x: s.x - r.minX, y: s.y - r.minY)
            annotation.endPoint = NSPoint(x: e.x - r.minX, y: e.y - r.minY)
        case .move, .corner:
            let dx = p.x - dragStart.x, dy = p.y - dragStart.y
            var r = startBounds
            switch drag {
            case .move:
                r.origin.x += dx; r.origin.y += dy
            case .corner(let c):
                var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
                if c == 0 || c == 2 { minX += dx } else { maxX += dx }
                if c == 0 || c == 1 { minY += dy } else { maxY += dy }
                let minW: CGFloat = annotation.type == "FreeText" ? 30 : 8
                r = NSRect(x: min(minX, maxX), y: min(minY, maxY),
                           width: max(abs(maxX - minX), minW), height: max(abs(maxY - minY), 8))
                // Signatures (and ⇧) keep their proportions, anchored at the opposite corner.
                if annotation is SignatureAnnotation || shift {
                    let aspect = startBounds.width / max(startBounds.height, 1)
                    let h = max(r.height, r.width / aspect)
                    let w = h * aspect
                    let anchorX = (c == 0 || c == 2) ? startBounds.maxX : startBounds.minX
                    let anchorY = (c == 0 || c == 1) ? startBounds.maxY : startBounds.minY
                    r = NSRect(x: (c == 0 || c == 2) ? anchorX - w : anchorX,
                               y: (c == 0 || c == 1) ? anchorY - h : anchorY, width: w, height: h)
                }
                if annotation.type == "FreeText" {
                    let font = annotation.font ?? NSFont.systemFont(ofSize: 14)
                    let text = annotation.contents ?? ""
                    let needed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
                        .boundingRect(with: NSSize(width: max(r.width - 8, 20), height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
                    let minH = max(ceil(needed.height) + 6, font.pointSize + 6)
                    if r.height < minH {
                        let oldMaxY = r.maxY
                        r.size.height = minH
                        if c == 0 || c == 1 { r.origin.y = oldMaxY - minH }
                    }
                }
            default: break
            }
            // Keep it on the page.
            r.origin.x = min(max(r.origin.x, pb.minX), max(pb.minX, pb.maxX - r.width))
            r.origin.y = min(max(r.origin.y, pb.minY), max(pb.minY, pb.maxY - r.height))
            if case .corner = drag, annotation.type == "Ink", let origPaths = startSnapshot?.paths {
                let sx = r.width / max(startBounds.width, 1)
                let sy = r.height / max(startBounds.height, 1)
                let tf = AffineTransform(scaleByX: sx, byY: sy)
                for path in annotation.paths ?? [] { annotation.remove(path) }
                for orig in origPaths {
                    let scaled = orig.copy() as! NSBezierPath
                    scaled.transform(using: tf)
                    scaled.lineWidth = orig.lineWidth
                    scaled.lineCapStyle = orig.lineCapStyle
                    scaled.lineJoinStyle = orig.lineJoinStyle
                    annotation.add(scaled)
                }
            } else if r == annotation.bounds {
                return
            }
            annotation.bounds = r
        }
        pdf.refresh(annotation, on: page)        // PDFKit needs a re-add to repaint
        moved = true
        layout()
    }

    func finish() {
        let wasResize: Bool
        switch drag {
        case .corner, .lineStart, .lineEnd: wasResize = true
        default: wasResize = false
        }
        drag = nil
        if moved {
            let old = startSnapshot ?? AnnotSnapshot(annotation)
            doc?.recordChanged(annotation, on: page, name: wasResize ? "Resize" : "Move",
                               from: old, to: AnnotSnapshot(annotation))
        }
        startSnapshot = nil
        moved = false
    }

    func delete() {
        doc?.removeAnnotation(annotation)                 // undoable
        doc?.pdfView.repaint(page)
    }
}

/// The dashed blue box with corner or endpoint handles.
final class SelectionOverlay: NSView {
    static let pad: CGFloat = 5
    var resizable = true { didSet { needsDisplay = true } }
    var lineEndpoints: (NSPoint, NSPoint)? { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // mouse goes through; the window monitor handles it

    private var corners: [NSRect] {
        let r = bounds.insetBy(dx: Self.pad, dy: Self.pad), s: CGFloat = 8
        let pts = [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
        return pts.map { NSRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    /// Corner index in page terms (0 BL, 1 BR, 2 TL, 3 TR) under a local point.
    func corner(at p: NSPoint) -> Int? {
        guard let i = corners.firstIndex(where: { $0.insetBy(dx: -5, dy: -5).contains(p) }) else { return nil }
        // Local space may be flipped relative to the page; map to page corners.
        if isFlipped { return [2, 3, 0, 1][i] }
        return i
    }

    func lineEndpoint(at p: NSPoint) -> Int? {
        guard let (a, b) = lineEndpoints else { return nil }
        if NSRect(x: a.x - 6, y: a.y - 6, width: 12, height: 12).contains(p) { return 0 }
        if NSRect(x: b.x - 6, y: b.y - 6, width: 12, height: 12).contains(p) { return 1 }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: Self.pad, dy: Self.pad)
        let path = NSBezierPath(rect: r)
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.lineWidth = 1
        Theme.accent.setStroke()
        path.stroke()
        if let (a, b) = lineEndpoints {
            let s: CGFloat = 9
            for pt in [a, b] {
                let c = NSRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)
                NSColor.white.setFill(); NSBezierPath(ovalIn: c).fill()
                Theme.accent.setStroke(); let o = NSBezierPath(ovalIn: c); o.lineWidth = 1.4; o.stroke()
            }
            return
        }
        guard resizable else { return }
        for c in corners {
            NSColor.white.setFill(); NSBezierPath(ovalIn: c).fill()
            Theme.accent.setStroke(); let o = NSBezierPath(ovalIn: c); o.lineWidth = 1.2; o.stroke()
        }
    }
}
