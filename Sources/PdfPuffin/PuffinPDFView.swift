import AppKit
import PDFKit

/// PDFView with PDF Expert's paging keys. `handleKey` is also called by the
/// window's key monitor, so the keys work no matter which view last got a click.
final class PuffinPDFView: PDFView {
    weak var owner: DocumentViewController? {
        didSet { registerForDraggedTypes([SignatureButton.dragType]) }
    }

    private func signatureTarget(_ sender: NSDraggingInfo) -> (Signature, PDFPage, NSPoint)? {
        guard let signature = (sender.draggingSource as? SignatureButton)?.signature else { return nil }
        let local = convert(sender.draggingLocation, from: nil)
        guard visibleRect.contains(local), let page = page(for: local, nearest: false) else { return nil }
        return (signature, page, convert(local, to: page))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is SignatureButton { return signatureTarget(sender) == nil ? [] : .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource is SignatureButton { return signatureTarget(sender) == nil ? [] : .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingSource is SignatureButton { return signatureTarget(sender) != nil }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSource is SignatureButton else { return super.performDragOperation(sender) }
        guard let (signature, page, point) = signatureTarget(sender) else { return false }
        SignatureStore.selected = signature
        placeSignature(signature, on: page, from: point, to: point)
        return true
    }

    // Page theme (View ▸ Theme): applied when the view shows a document or the theme changes.
    private var themeObserver: NSObjectProtocol?
    override var document: PDFDocument? {
        didSet { DispatchQueue.main.async { [weak self] in self?.applyPageTheme() } }
    }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if themeObserver == nil {
            themeObserver = NotificationCenter.default.addObserver(forName: PageTheme.changed, object: nil, queue: .main) { [weak self] _ in
                self?.applyPageTheme()
            }
        }
        applyPageTheme()
    }

    /// The shape being drawn: annotation, its page, and the drag's start point.
    var drawing: (PDFAnnotation, PDFPage, NSPoint)?
    var inkPoints: [NSPoint] = []
    var eraserPage: PDFPage?
    var signatureStart: (PDFPage, NSPoint)?

    override func cursorUpdate(with event: NSEvent) {
        if owner?.shapeTool != nil { NSCursor.crosshair.set() } else { super.cursorUpdate(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: false) else { toolTip = nil; return }
        let pt = convert(p, to: page)
        if let a = AnnotationSelection.hit(page, pt) {
            if a.type == "Text" {
                let c = (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                toolTip = c.isEmpty ? nil : c
                return
            }
            if ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(a.type ?? "") {
                let c = NoteCardEditor.distinctComment(for: a, on: page).trimmingCharacters(in: .whitespacesAndNewlines)
                toolTip = c.isEmpty ? nil : c
                return
            }
        }
        toolTip = nil
    }

    override var acceptsFirstResponder: Bool { true }

    /// Edit ▸ Undo / Redo reach the tab's own history, not PDFKit's private one.
    override var undoManager: UndoManager? { owner?.editHistory ?? super.undoManager }

    /// ⌘C: after clicking in the thumbnail list, copy the selected pages as a PDF
    /// (in document order); otherwise copy the selected text as usual.
    override func copy(_ sender: Any?) {
        if let d = owner, d.thumbnailsActive, !d.sidebar.thumbnails.selectedPages.isEmpty {
            d.copySelectedPagesToPasteboard()
        } else {
            super.copy(sender)
        }
    }

    /// PDFView validates menu items privately (not in its header), so this
    /// shadows that method and forwards everything except page Copy to it.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)), let d = owner, d.thumbnailsActive,
           !d.sidebar.thumbnails.selectedPages.isEmpty {
            let n = d.sidebar.thumbnails.selectedPages.count
            item.title = n == 1 ? "Copy Page" : "Copy \(n) Pages"
            return true
        }
        if item.action == #selector(copy(_:)) { item.title = "Copy" }
        let sel = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard PDFView.instancesRespond(to: sel), let imp = class_getMethodImplementation(PDFView.self, sel) else {
            return item.action.map { responds(to: $0) } ?? false
        }
        typealias Fn = @convention(c) (AnyObject, Selector, NSMenuItem) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(self, sel, item)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// Returns true when the key was a paging key and was handled.
    func handleKey(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        switch e.keyCode {
        case 123 where m.isEmpty: owner?.previousPage(); return true          // ←
        case 124 where m.isEmpty: owner?.nextPage(); return true              // →
        case 126 where m.isEmpty: lineScroll(up: true); return true           // ↑
        case 125 where m.isEmpty: lineScroll(up: false); return true          // ↓
        case 49 where m.isEmpty: pageScroll(down: true); return true          // Space
        case 49 where m == .shift: pageScroll(down: false); return true       // ⇧Space
        case 121 where m.isEmpty: pageScroll(down: true); return true         // Page Down
        case 116 where m.isEmpty: pageScroll(down: false); return true        // Page Up
        case 115 where m.isEmpty: owner?.firstPage(); return true             // Home
        case 119 where m.isEmpty: owner?.lastPage(); return true              // End
        default: return false
        }
    }

    private var clip: NSClipView? { documentView?.enclosingScrollView?.contentView }

    /// Scrolls by `delta` (positive = towards the end). Returns false if nothing moved.
    @discardableResult
    func scrollBy(_ delta: CGFloat) -> Bool {
        guard let clip, let doc = documentView else { return false }
        var origin = clip.bounds.origin
        let old = origin.y
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let dy = clip.isFlipped ? delta : -delta
        origin.y = min(max(0, origin.y + dy), maxY)
        if abs(origin.y - old) < 0.5 { return false }
        clip.scroll(to: origin)
        documentView?.enclosingScrollView?.reflectScrolledClipView(clip)
        return true
    }

    func lineScroll(up: Bool) {
        if !scrollBy(up ? -48 : 48), !displayMode.isContinuous {
            if up, canGoToPreviousPage { goToPreviousPage(nil); scrollToEndOfPage() }
            else if !up, canGoToNextPage { goToNextPage(nil) }
        }
    }

    func pageScroll(down: Bool) {
        guard let clip else { return }
        let h = clip.bounds.height * 0.9
        if !scrollBy(down ? h : -h), !displayMode.isContinuous {
            if down, canGoToNextPage { goToNextPage(nil) }
            else if !down, canGoToPreviousPage { goToPreviousPage(nil); scrollToEndOfPage() }
        }
    }

    private func scrollToEndOfPage() {
        DispatchQueue.main.async { [weak self] in _ = self?.scrollBy(100_000) }
    }
}

extension PDFDisplayMode {
    var isContinuous: Bool { self == .singlePageContinuous || self == .twoUpContinuous }
}

// MARK: - zoom as PDF Expert shows it (100% = actual paper size)

extension PuffinPDFView {
    /// PDFKit's scale 1.0 draws one PDF point (1/72 inch) per screen point, which on a
    /// Retina MacBook (about 127 points per inch) shows a page at only ~57% of its paper
    /// size. PDF Expert and PdfPuffin call 100% the real paper size instead, so every
    /// percentage shown or chosen is divided or multiplied by this factor.
    static func actualSizeScale(for screen: NSScreen?) -> CGFloat {
        guard let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 1 }
        let mm = CGDisplayScreenSize(id).width
        guard mm > 50 else { return 1 }                       // size unknown (some projectors, virtual displays)
        let factor = screen.frame.width / (mm / 25.4) / 72
        return factor.isFinite && (0.75...3).contains(factor) ? factor : 1
    }

    var actualSizeScale: CGFloat { Self.actualSizeScale(for: window?.screen ?? NSScreen.main) }

    /// The zoom shown to the user: 1.0 means actual paper size.
    var displayZoom: CGFloat { scaleFactor / actualSizeScale }
}
