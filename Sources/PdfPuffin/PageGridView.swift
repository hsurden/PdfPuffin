import AppKit
import PDFKit

/// PDF Expert's page grid (View ▸ Thumbnails, ⌘4, or the four-squares toolbar
/// button): every page as a thumbnail with its number, the current page's number in
/// a blue badge. Click / ⌘-click / ⇧-click select, drag to reorder, double-click or
/// Return opens the page, ← → ↑ ↓ move through the grid, Delete removes pages.
final class PageGridView: NSView {
    weak var doc: DocumentViewController?
    private let scroll = NSScrollView()
    private let canvas = GridCanvas()

    var selection = IndexSet() { didSet { canvas.needsDisplay = true; doc?.main?.updateToolbar() } }
    private var anchor: Int?
    var current = 0 { didSet { canvas.needsDisplay = true } }

    init(doc: DocumentViewController) {
        self.doc = doc
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.pageBG.cgColor
        canvas.grid = self
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.pinEdges(to: self)
        current = doc.currentPageIndex
        selection = [current]
        anchor = current
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    var pageCount: Int { doc?.pageCount ?? 0 }

    override func layout() {
        super.layout()
        canvas.relayout(width: scroll.contentSize.width)
    }

    func reload() {
        canvas.invalidateCache()
        let n = pageCount
        selection = selection.filteredIndexSet { $0 < n }
        if selection.isEmpty, n > 0 { selection = [min(current, n - 1)] }
        current = min(current, max(0, n - 1))
        // A shift-click anchor on a deleted page would select a page that no longer exists.
        if let a = anchor, a >= n { anchor = n > 0 ? current : nil }
        canvas.relayout(width: scroll.contentSize.width)
        canvas.needsDisplay = true
    }

    func scrollToCurrent() {
        canvas.layoutSubtreeIfNeeded()
        canvas.scrollToVisible(canvas.cellRect(current).insetBy(dx: -10, dy: -30))
    }

    /// The selected pages, or the current page if none.
    var targetPages: IndexSet { selection.isEmpty ? [current] : selection }

    // MARK: clicks

    func clicked(_ i: Int, modifiers: NSEvent.ModifierFlags, count: Int) {
        if count >= 2 { doc?.openPageFromGrid(i); return }
        if modifiers.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            anchor = i
        } else if modifiers.contains(.shift), let a = anchor {
            selection = IndexSet(integersIn: min(a, i)...max(a, i))
        } else {
            selection = [i]
            anchor = i
        }
        current = i
    }

    func clickedEmpty() { selection = []; anchor = nil }

    /// Arrow keys move through the grid (⇧ extends the selection), Return opens,
    /// Delete removes the selected pages, ⌘A selects all.
    func handleKey(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let cols = canvas.columns
        var next: Int?
        switch e.keyCode {
        case 123: next = current - 1                       // ←
        case 124: next = current + 1                       // →
        case 126: next = current - cols                    // ↑
        case 125: next = current + cols                    // ↓
        case 115: next = 0                                 // Home
        case 119: next = pageCount - 1                     // End
        case 36, 76: doc?.openPageFromGrid(current); return true   // Return / Enter
        case 51, 117:                                      // Delete
            guard m.isEmpty else { return false }
            doc?.main?.gridDelete(nil); return true
        case 0 where m == .command: selection = IndexSet(integersIn: 0..<pageCount); return true
        default: return false
        }
        guard var n = next, m.subtracting(.shift).isEmpty else { return false }
        n = min(max(n, 0), pageCount - 1)
        if m.contains(.shift), let a = anchor { selection = IndexSet(integersIn: min(a, n)...max(a, n)) }
        else { selection = [n]; anchor = n }
        current = n
        scrollToCurrent()
        return true
    }

    /// Drop of dragged pages before index `dest`.
    func moveSelection(before dest: Int) {
        guard let d = doc, !selection.isEmpty else { return }
        let moving = selection
        if d.changePages(moving, before: dest) {
            let start = dest - moving.count(in: 0..<dest)
            selection = IndexSet(integersIn: start..<(start + moving.count))
            current = start
        }
    }
}

/// Draws the cells and handles the mouse (selection, double-click, drag to reorder).
final class GridCanvas: NSView {
    weak var grid: PageGridView?
    private let cache: NSCache<PDFPage, NSImage> = {
        let c = NSCache<PDFPage, NSImage>()
        c.countLimit = 120
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()
    private var pending: Set<ObjectIdentifier> = []
    private let thumbQueue = DispatchQueue(label: "com.hs.PdfPuffin.gridThumbs", qos: .userInitiated)
    private let generationLock = NSLock()
    private var renderGeneration = 0
    private(set) var columns = 1
    private let thumbW: CGFloat = 200, gapX: CGFloat = 48, gapY: CGFloat = 56, top: CGFloat = 36
    private var cellH: CGFloat = 300
    private var dragStart: NSPoint?
    private var dropIndex: Int? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private var document: PDFDocument? { grid?.doc?.document }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return renderGeneration
    }

    func invalidateCache() {
        generationLock.lock()
        renderGeneration += 1
        generationLock.unlock()
        cache.removeAllObjects()
        pending.removeAll()
    }

    private func requestThumbnail(for page: PDFPage, size: NSSize, rect: NSRect) {
        let id = ObjectIdentifier(page)
        guard !pending.contains(id) else { return }
        pending.insert(id)
        let gen = currentGeneration()
        guard let snapshot = thumbnailSnapshot(of: page) else { pending.remove(id); return }
        thumbQueue.async { [weak self] in
            guard let self, self.currentGeneration() == gen else { return }
            let img = snapshot.thumbnail(of: size, for: .cropBox)
            let cost = max(1, Int(size.width * size.height * 4))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentGeneration() == gen else { return }
                self.cache.setObject(img, forKey: page, cost: cost)
                self.pending.remove(id)
                self.setNeedsDisplay(rect)
            }
        }
    }

    func relayout(width: CGFloat) {
        let n = grid?.pageCount ?? 0
        columns = max(1, Int((width - gapX) / (thumbW + gapX)))
        // Height from the tallest page (portrait pages fill the cell).
        var maxAspect: CGFloat = 1.3
        if let d = document { for i in 0..<min(n, 40) { if let p = d.page(at: i) { maxAspect = max(maxAspect, aspect(p)) } } }
        cellH = thumbW * maxAspect
        let rows = (n + columns - 1) / columns
        let h = top + CGFloat(rows) * (cellH + gapY + 24)
        frame.size = NSSize(width: width, height: max(h, (superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    private func aspect(_ p: PDFPage) -> CGFloat {
        let b = p.bounds(for: .cropBox)
        let (w, h) = p.rotation % 180 == 0 ? (b.width, b.height) : (b.height, b.width)
        return w > 0 ? h / w : 1.3
    }

    private var leftMargin: CGFloat {
        let used = CGFloat(columns) * thumbW + CGFloat(columns - 1) * gapX
        return max(gapX / 2, (bounds.width - used) / 2)
    }

    /// The whole cell (page area plus number) for page i.
    func cellRect(_ i: Int) -> NSRect {
        let r = i / columns, c = i % columns
        return NSRect(x: leftMargin + CGFloat(c) * (thumbW + gapX), y: top + CGFloat(r) * (cellH + gapY + 24),
                      width: thumbW, height: cellH + 34)
    }

    /// The page image rect inside a cell, bottom-aligned like PDF Expert.
    private func pageRect(_ i: Int) -> NSRect {
        guard let p = document?.page(at: i) else { return .zero }
        let cell = cellRect(i)
        let a = aspect(p)
        var w = thumbW, h = thumbW * a
        if h > cellH { h = cellH; w = h / a }
        return NSRect(x: cell.midX - w / 2, y: cell.minY + cellH - h, width: w, height: h)
    }

    private func index(at p: NSPoint) -> Int? {
        guard let n = grid?.pageCount else { return nil }
        for i in 0..<n where cellRect(i).insetBy(dx: -gapX / 4, dy: -6).contains(p) { return i }
        return nil
    }

    /// Insertion point for a drop: before the cell under the pointer (or after it
    /// when the pointer is on its right half).
    private func insertion(at p: NSPoint) -> Int {
        guard let n = grid?.pageCount, n > 0 else { return 0 }
        var best = n, bestD = CGFloat.greatestFiniteMagnitude
        for i in 0...n {
            let ref = i < n ? cellRect(i) : cellRect(n - 1).offsetBy(dx: thumbW + gapX, dy: 0)
            let x = ref.minX - gapX / 2, y = ref.midY
            let d = hypot(p.x - x, (p.y - y) * 0.6)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = grid, let d = document else { return }
        for i in 0..<g.pageCount {
            let cell = cellRect(i)
            guard cell.insetBy(dx: -10, dy: -10).intersects(dirtyRect), let page = d.page(at: i) else { continue }
            let r = pageRect(i)
            NSColor.white.setFill(); r.fill()
            if let img = cache.object(forKey: page) {
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                requestThumbnail(for: page, size: NSSize(width: r.width * 2, height: r.height * 2), rect: r)
            }
            if g.selection.contains(i) {
                let p = NSBezierPath(roundedRect: r.insetBy(dx: -5, dy: -5), xRadius: 6, yRadius: 6)
                p.lineWidth = 3; Theme.badgeBlue.setStroke(); p.stroke()
            } else {
                NSColor(white: 0.8, alpha: 1).setStroke(); NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)).stroke()
            }
            let isCur = i == g.current
            let label = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: isCur ? .semibold : .regular),
                                                         .foregroundColor: isCur ? NSColor.white : NSColor(white: 0.25, alpha: 1)]
            let sz = label.size(withAttributes: attrs)
            let cy = cell.minY + cellH + 22
            if isCur {
                let bw = max(28, sz.width + 14)
                Theme.badgeBlue.setFill()
                NSBezierPath(roundedRect: NSRect(x: cell.midX - bw / 2, y: cy - 14, width: bw, height: 28), xRadius: 4, yRadius: 4).fill()
            }
            label.draw(at: NSPoint(x: cell.midX - sz.width / 2, y: cy - sz.height / 2), withAttributes: attrs)
        }
        if let di = dropIndex, g.pageCount > 0 {                 // drop marker
            let ref = di < g.pageCount ? pageRect(di) : pageRect(g.pageCount - 1).offsetBy(dx: thumbW + gapX, dy: 0)
            Theme.accent.setFill()
            NSRect(x: ref.minX - gapX / 2 - 2, y: ref.minY - 6, width: 4, height: ref.height + 12).fill()
        }
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        dragStart = nil
        guard let i = index(at: p) else { grid?.clickedEmpty(); return }
        let mods = e.modifierFlags
        // Pressing on an already-selected page keeps the selection, so it can be dragged.
        if grid?.selection.contains(i) == true, e.clickCount == 1, !mods.contains(.command), !mods.contains(.shift) {
            grid?.current = i
        } else {
            grid?.clicked(i, modifiers: mods, count: e.clickCount)
        }
        if e.clickCount >= 2 { return }                   // clicked() opened the page
        dragStart = p
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(e.locationInWindow, from: nil)
        if dropIndex == nil, hypot(p.x - s.x, p.y - s.y) < 6 { return }
        dropIndex = insertion(at: p)
        autoscroll(with: e)
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragStart = nil; dropIndex = nil }
        if let di = dropIndex { grid?.moveSelection(before: di); return }
        // A plain click on a page inside a multi-selection selects just that page.
        if let s = dragStart, let i = index(at: s), e.clickCount == 1,
           !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.shift), (grid?.selection.count ?? 0) > 1 {
            grid?.clicked(i, modifiers: [], count: 1)
        }
    }
}

/// PDF Expert's page-tools bar shown in place of the annotate bar while the grid is
/// open: Insert page, Append file, Rotate, Copy, Paste, Extract, Delete.
final class PageToolsRow: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.toolRow.cgColor
        typealias M = MainWindowController
        func button(_ title: String, _ symbol: String, _ tip: String, _ sel: Selector, tint: NSColor = NSColor(white: 0.2, alpha: 1)) -> NSButton {
            let b = NSButton(title: title, image: Theme.symbol(symbol, 16), target: nil, action: sel)
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.font = .systemFont(ofSize: 14)
            b.contentTintColor = tint
            b.toolTip = tip
            b.refusesFirstResponder = true
            return b
        }
        let red = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.15, alpha: 1)
        let items = [
            button("Insert page", "doc.badge.plus", "Insert a blank page after the selection", #selector(M.gridInsertBlank(_:))),
            button("Append file", "doc.richtext", "Add the pages of a PDF after the selection", #selector(M.gridAppendFile(_:))),
            button("Crop", "crop", "Preview and crop selected pages", #selector(M.cropPagesAction(_:))),
            button("Rotate", "rotate.right", "Rotate the selected pages 90° clockwise (⌥-click: counter-clockwise)", #selector(M.gridRotate(_:))),
            button("Copy", "doc.on.doc", "Copy the selected pages (⌘C)", #selector(M.gridCopy(_:))),
            button("Paste", "doc.on.clipboard", "Paste PDF pages or images after the selection (⌘V)", #selector(M.gridPaste(_:))),
            button("Extract", "arrow.up.doc", "Open the selected pages as a new document", #selector(M.gridExtract(_:))),
            button("Delete", "trash", "Delete the selected pages (⌫)", #selector(M.gridDelete(_:)), tint: red),
        ]
        let row = NSStackView(views: items)
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let line = ColorView(Theme.separator)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
