import AppKit
import PDFKit

/// View ▸ Zoom ▸ Pan & Zoom: a small floating panel with the current page and a box
/// marking the part of it on screen. Drag the box (or click anywhere) to move the
/// view; the slider sets the zoom. It follows the frontmost document.
final class PanZoomPanel: NSPanel {
    private static var shared: PanZoomPanel?
    static var isShown: Bool { shared?.isVisible == true }

    static func toggle() {
        if let p = shared, p.isVisible { p.orderOut(nil); return }
        let p = shared ?? PanZoomPanel()
        shared = p
        p.orderFront(nil)
        p.map.refresh(force: true)
    }

    private let map = PanZoomMap()
    /// In displayed zoom (1 = actual paper size), like the toolbar's percentage.
    private let slider = NSSlider(value: 1, minValue: 0.25, maxValue: 4, target: nil, action: nil)
    private let percent = label("100%", size: 11, color: .secondaryLabelColor)
    private var timer: Timer?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 230, height: 320),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Pan & Zoom"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 170, height: 220)
        setFrameAutosaveName("PdfPuffinPanZoom")
        if frame.origin == .zero, let screen = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: screen.maxX - 260, y: screen.maxY - 80))
        }

        slider.target = self
        slider.action = #selector(zoomChanged)
        slider.isContinuous = true
        slider.refusesFirstResponder = true
        slider.controlSize = .small
        let minus = iconButton("minus.magnifyingglass", tip: "Zoom Out", target: self, action: #selector(zoomOut), tint: .secondaryLabelColor, size: 13, width: 22)
        let plus = iconButton("plus.magnifyingglass", tip: "Zoom In", target: self, action: #selector(zoomIn), tint: .secondaryLabelColor, size: 13, width: 22)
        let row = NSStackView(views: [minus, slider, plus, percent])
        row.spacing = 4
        let root = contentView!
        for v in [map, row] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            map.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            map.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            map.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: map.bottomAnchor, constant: 8),
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            percent.widthAnchor.constraint(equalToConstant: 38),
        ])
        // Follow scrolling, zooming, page and tab changes without wiring into each view.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.map.refresh(force: false)
            if let pdf = self.map.pdf {
                if !self.slider.isHighlighted { self.slider.doubleValue = Double(pdf.displayZoom) }
                self.percent.stringValue = "\(Int((pdf.displayZoom * 100).rounded()))%"
            }
        }
    }

    @objc private func zoomChanged() {
        guard let pdf = map.pdf else { return }
        pdf.autoScales = false
        pdf.scaleFactor = CGFloat(slider.doubleValue) * pdf.actualSizeScale
    }
    @objc private func zoomIn() { map.pdf?.zoomIn(nil) }
    @objc private func zoomOut() { map.pdf?.zoomOut(nil) }
}

/// The page picture and the visible-area box.
final class PanZoomMap: NSView {
    /// The frontmost document's active pane.
    var pdf: PuffinPDFView? {
        let main = (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? MainWindowController }.first
        guard let d = main?.current, !d.gridMode else { return nil }
        return d.pdfView
    }
    private var page: PDFPage?
    private var image: NSImage?
    private var visible = NSRect.zero        // in page space
    private var lastKey = ""

    /// Redraws when the page, the visible area or the size changed.
    func refresh(force: Bool) {
        guard let pdf, let page = pdf.currentPage else {
            if page != nil || force { page = nil; image = nil; needsDisplay = true }
            return
        }
        let box = page.bounds(for: pdf.displayBox)
        // No overlap gives a null (infinite) rect: treat it as nothing visible.
        let overlap = pdf.convert(pdf.bounds, to: page).intersection(box)
        let vis = overlap.isNull || !overlap.width.isFinite || !overlap.height.isFinite ? .zero : overlap
        let key = "\(ObjectIdentifier(page).hashValue)|\(vis.minX.rounded()),\(vis.minY.rounded()),\(vis.width.rounded()),\(vis.height.rounded())|\(bounds.width.rounded())x\(bounds.height.rounded())"
        guard force || key != lastKey else { return }
        if page !== self.page || image == nil || force {
            self.page = page
            image = page.thumbnail(of: NSSize(width: bounds.width * 2, height: bounds.height * 2), for: pdf.displayBox)
        }
        visible = vis
        lastKey = key
        needsDisplay = true
    }

    /// Where the page picture sits in this view.
    private var pageRect: NSRect {
        guard let page, let pdf else { return .zero }
        var size = page.bounds(for: pdf.displayBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func toView(_ r: NSRect) -> NSRect {
        guard let page, let pdf else { return .zero }
        let box = page.bounds(for: pdf.displayBox), pr = pageRect
        guard box.width > 0, box.height > 0 else { return .zero }
        let sx = pr.width / box.width, sy = pr.height / box.height
        return NSRect(x: pr.minX + (r.minX - box.minX) * sx, y: pr.minY + (r.minY - box.minY) * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.93, alpha: 1).setFill()
        bounds.fill()
        guard page != nil else {
            let s = NSAttributedString(string: "No page", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            s.draw(at: NSPoint(x: bounds.midX - s.size().width / 2, y: bounds.midY - 7))
            return
        }
        let pr = pageRect
        NSColor.white.setFill(); pr.fill()
        image?.draw(in: pr)
        NSColor(white: 0, alpha: 0.2).setStroke(); NSBezierPath(rect: pr).stroke()
        // Only unrotated pages map cleanly from page space to the picture.
        guard page?.rotation ?? 0 == 0 else { return }
        let box = toView(visible).intersection(pr)
        guard box.width > 0, box.height > 0 else { return }
        NSColor(srgbRed: 0.95, green: 0.25, blue: 0.2, alpha: 0.12).setFill()
        NSBezierPath(rect: box).fill()
        let outline = NSBezierPath(rect: box.insetBy(dx: 0.75, dy: 0.75))
        outline.lineWidth = 1.5
        NSColor(srgbRed: 0.92, green: 0.22, blue: 0.18, alpha: 1).setStroke()
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) { centre(at: event) }
    override func mouseDragged(with event: NSEvent) { centre(at: event) }

    /// Scrolls so the clicked point of the page is in the middle of the window.
    private func centre(at event: NSEvent) {
        guard let pdf, let page, page.rotation == 0,
              let docView = pdf.documentView, let clip = docView.enclosingScrollView?.contentView else { return }
        let p = convert(event.locationInWindow, from: nil)
        let pr = pageRect, box = page.bounds(for: pdf.displayBox)
        guard pr.width > 0, pr.height > 0 else { return }
        let pagePoint = NSPoint(x: box.minX + (p.x - pr.minX) / pr.width * box.width,
                                y: box.minY + (p.y - pr.minY) / pr.height * box.height)
        let inDoc = docView.convert(pdf.convert(pagePoint, from: page), from: pdf)
        let size = clip.bounds.size
        var origin = NSPoint(x: inDoc.x - size.width / 2,
                             y: inDoc.y - size.height / 2)
        let maxX = max(0, docView.bounds.width - size.width), maxY = max(0, docView.bounds.height - size.height)
        origin.x = min(max(origin.x, docView.bounds.minX), docView.bounds.minX + maxX)
        origin.y = min(max(origin.y, docView.bounds.minY), docView.bounds.minY + maxY)
        clip.scroll(to: origin)
        docView.enclosingScrollView?.reflectScrolledClipView(clip)
        refresh(force: false)
    }
}

extension MainWindowController {
    @objc func togglePanZoom(_ sender: Any?) { PanZoomPanel.toggle() }
}
