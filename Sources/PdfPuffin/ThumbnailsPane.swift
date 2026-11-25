import AppKit
import PDFKit

/// Page thumbnails. Click = go to page; ⌘-click / ⇧-click = select several pages,
/// then make a new document from them or add them to another open tab.
final class ThumbnailsPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var doc: DocumentViewController?
    let table = FocuslessTableView()
    private static let dragType = NSPasteboard.PasteboardType("com.hs.PdfPuffin.thumbnail-row")
    private let cache: NSCache<NSNumber, NSImage> = {
        let c = NSCache<NSNumber, NSImage>()
        c.countLimit = 80
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    private var pending: Set<Int> = []
    private let thumbQueue = DispatchQueue(label: "com.hs.PdfPuffin.sidebarThumbs", qos: .userInitiated)
    private let generationLock = NSLock()
    private var renderGeneration = 0
    private(set) var currentPage = 0
    static let thumbWidth: CGFloat = 150

    private let actionBar = NSView()
    private let countLabel = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let newDocButton = NSButton(title: "New Document", target: nil, action: nil)
    private let addToButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var actionBarHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.headerView = nil
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("t")))
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = makeScroll(table)
        addSubview(scroll)
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        actionBar.wantsLayer = true
        actionBar.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
        addSubview(actionBar)

        newDocButton.target = self
        newDocButton.action = #selector(newDocFromSelection)
        newDocButton.controlSize = .small
        newDocButton.toolTip = "Make a new document (new tab) from the selected pages"
        addToButton.controlSize = .small
        addToButton.toolTip = "Append the selected pages to another open tab"
        (addToButton.menu ?? NSMenu()).delegate = self
        for b in [newDocButton, addToButton] as [NSControl] {
            b.refusesFirstResponder = true
            b.translatesAutoresizingMaskIntoConstraints = false
            actionBar.addSubview(b)
        }
        actionBar.addSubview(countLabel)

        actionBarHeight = actionBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionBarHeight,
            countLabel.topAnchor.constraint(equalTo: actionBar.topAnchor, constant: 8),
            countLabel.centerXAnchor.constraint(equalTo: actionBar.centerXAnchor),
            newDocButton.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            newDocButton.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 8),
            addToButton.centerYAnchor.constraint(equalTo: newDocButton.centerYAnchor),
            addToButton.leadingAnchor.constraint(equalTo: newDocButton.trailingAnchor, constant: 6),
            addToButton.trailingAnchor.constraint(lessThanOrEqualTo: actionBar.trailingAnchor, constant: -8),
        ])
        actionBar.isHidden = true
        rebuildAddToMenu(addToButton.menu!, isPopup: true)
    }
    required init?(coder: NSCoder) { fatalError() }

    var document: PDFDocument? { doc?.document }
    var selectedPages: IndexSet { table.selectedRowIndexes }

    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        renderGeneration += 1
        return renderGeneration
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return renderGeneration
    }

    func reload() {
        _ = bumpGeneration()
        cache.removeAllObjects()
        pending.removeAll()
        table.reloadData()
        updateActionBar()
    }

    func reloadImages() {
        _ = bumpGeneration()
        cache.removeAllObjects()
        pending.removeAll()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        table.reloadData()
    }

    func setCurrent(_ i: Int) {
        let old = currentPage
        currentPage = i
        for r in [old, i] { (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ThumbCell)?.isCurrent = (r == i) }
        if table.selectedRowIndexes.count <= 1, i < table.numberOfRows {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        if i < table.numberOfRows, !isHidden { table.scrollRowToVisible(i) }
    }

    // MARK: data source

    func numberOfRows(in tableView: NSTableView) -> Int { document?.pageCount ?? 0 }

    private func imageHeight(_ row: Int) -> CGFloat {
        guard let p = document?.page(at: row) else { return 194 }
        let b = p.bounds(for: .cropBox)
        let (w, h) = p.rotation % 180 == 0 ? (b.width, b.height) : (b.height, b.width)
        return w > 0 ? Self.thumbWidth * h / w : 194
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { imageHeight(row) + 44 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("thumb")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ThumbCell) ?? ThumbCell()
        cell.identifier = id
        let key = NSNumber(value: row)
        let cached = cache.object(forKey: key)
        cell.pageNumber = row + 1
        cell.imageHeight = imageHeight(row)
        cell.image = cached
        cell.isCurrent = row == currentPage
        cell.isChosen = tableView.isRowSelected(row)
        if cached == nil { render(row) }
        return cell
    }

    private func render(_ row: Int) {
        guard !pending.contains(row), let live = document?.page(at: row), let page = thumbnailSnapshot(of: live) else { return }
        let size = NSSize(width: Self.thumbWidth * 2, height: imageHeight(row) * 2)
        let gen = currentGeneration()
        pending.insert(row)
        thumbQueue.async { [weak self] in
            guard let self, self.currentGeneration() == gen else { return }
            let img = page.thumbnail(of: size, for: .cropBox)
            let cost = max(1, Int(size.width * size.height * 4))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentGeneration() == gen else { return }
                self.cache.setObject(img, forKey: NSNumber(value: row), cost: cost)
                self.pending.remove(row)
                (self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbCell)?.image = img
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? ThumbCell)?.isChosen = table.isRowSelected(row)
        }
        updateActionBar()
    }

    private func updateActionBar() {
        let n = table.selectedRowIndexes.count
        let show = n >= 2
        actionBar.isHidden = !show
        actionBarHeight.constant = show ? 64 : 0
        countLabel.stringValue = "\(n) pages selected"
        rebuildAddToMenu(addToButton.menu!, isPopup: true)
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0 else { return }
        doc?.thumbnailsActive = true
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if mods.contains(.command) || mods.contains(.shift) { return }   // multi-select only
        doc?.jump(toPage: r)
    }

    // MARK: merge actions

    @objc func newDocFromSelection() {
        guard let d = doc, !selectedPages.isEmpty else { NSSound.beep(); return }
        d.main?.newDocument(fromPages: d.copies(of: selectedPages),
                            name: d.excerptName(for: selectedPages))
    }

    @objc func addSelection(to item: NSMenuItem) {
        guard let d = doc, let target = item.representedObject as? DocumentViewController, !selectedPages.isEmpty else { return }
        target.append(pages: d.copies(of: selectedPages))
        d.main?.flash("Added \(selectedPages.count) page\(selectedPages.count == 1 ? "" : "s") to “\(target.displayName)”")
    }

    @objc func selectAllPages() { table.selectAll(nil) }
    @objc func clearPageSelection() { table.selectRowIndexes([currentPage], byExtendingSelection: false) }

    /// "2–5, 9"
    static func describe(_ set: IndexSet) -> String {
        set.rangeView.map { r in
            r.count == 1 ? "\(r.lowerBound + 1)" : "\(r.lowerBound + 1)–\(r.upperBound)"
        }.joined(separator: ", ")
    }

    func rebuildAddToMenu(_ menu: NSMenu, isPopup: Bool) {
        menu.removeAllItems()
        if isPopup { menu.addItem(withTitle: "Add to…", action: nil, keyEquivalent: "") }
        let others = doc?.main?.documentControllers.filter { $0 !== doc } ?? []
        if others.isEmpty {
            let i = menu.addItem(withTitle: "No other open tabs", action: nil, keyEquivalent: "")
            i.isEnabled = false
        }
        for o in others {
            let i = menu.addItem(withTitle: o.displayName, action: #selector(addSelection(to:)), keyEquivalent: "")
            i.target = self
            i.representedObject = o
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView,
              (0...tableView.numberOfRows).contains(row) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === tableView else { return false }
        let rows = info.draggingPasteboard.pasteboardItems?.compactMap {
            $0.string(forType: Self.dragType).flatMap(Int.init)
        } ?? []
        return doc?.changePages(IndexSet(rows), before: row) ?? false
    }

    @objc private func removeSelectedPages() {
        _ = doc?.changePages(selectedPages, before: nil)
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === addToButton.menu { rebuildAddToMenu(menu, isPopup: true); return }
        let r = table.clickedRow
        if r >= 0, !table.isRowSelected(r) { table.selectRowIndexes([r], byExtendingSelection: false) }
        menu.removeAllItems()
        let n = selectedPages.count
        let s = n == 1 ? "Page" : "\(n) Pages"
        menu.addItem(withTitle: "New Document from \(s)", action: #selector(newDocFromSelection), keyEquivalent: "").target = self
        let add = menu.addItem(withTitle: "Add \(s) to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        rebuildAddToMenu(sub, isPopup: false)
        add.submenu = sub
        menu.addItem(.separator())
        if n > 0, n < table.numberOfRows {
            menu.addItem(withTitle: "Remove \(s)", action: #selector(removeSelectedPages), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Select All Pages", action: #selector(selectAllPages), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Deselect Pages", action: #selector(clearPageSelection), keyEquivalent: "").target = self
    }
}

/// One thumbnail: white page with border (blue when selected) and the page
/// number underneath (in a blue badge for the current page).
final class ThumbCell: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var pageNumber = 1 { didSet { needsDisplay = true } }
    var imageHeight: CGFloat = 194 { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var isChosen = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = ThumbnailsPane.thumbWidth
        let r = NSRect(x: (bounds.width - w) / 2, y: 8, width: w, height: imageHeight)
        NSColor.white.setFill()
        r.fill()
        if let image {
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if isChosen {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), xRadius: 5, yRadius: 5)
            p.lineWidth = 3
            Theme.badgeBlue.setStroke(); p.stroke()
        } else {
            NSColor(white: 0.82, alpha: 1).setStroke()
            NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)).stroke()
        }
        let num = "\(pageNumber)" as NSString
        let font = NSFont.systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isCurrent ? NSColor.white : NSColor.secondaryLabelColor]
        let size = num.size(withAttributes: attrs)
        let cy = r.maxY + 20
        if isCurrent {
            let bw = max(22, size.width + 12)
            let badge = NSRect(x: bounds.midX - bw / 2, y: cy - 11, width: bw, height: 22)
            Theme.badgeBlue.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        }
        num.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: cy - size.height / 2), withAttributes: attrs)
    }
}

/// A copy of `page` in its own throwaway document, for drawing a thumbnail off
/// the main thread. PDFKit pages aren't thread-safe: drawing the live page while
/// the main thread adds or removes an annotation can throw NSRangeException
/// (reproduced under stress). The copy carries the annotations as they are now.
func thumbnailSnapshot(of page: PDFPage) -> PDFPage? {
    guard let copy = page.copy() as? PDFPage else { return nil }
    // copy() turns self-drawing annotations (signatures, checkmarks, stamps)
    // into plain stamps that have no appearance until saved; swap in real copies.
    let originals = page.annotations, copies = copy.annotations
    if originals.count == copies.count {
        for (o, c) in zip(originals, copies) {
            if let m = o as? MarkAnnotation {
                let n = MarkAnnotation(bounds: m.bounds, forType: .stamp, withProperties: nil)
                n.kind = m.kind; n.color = m.color
                copy.removeAnnotation(c); copy.addAnnotation(n)
            } else if let sig = o as? SignatureAnnotation {
                let n = SignatureAnnotation(bounds: sig.bounds, forType: .stamp, withProperties: nil)
                n.signature = sig.signature
                copy.removeAnnotation(c); copy.addAnnotation(n)
            }
        }
    }
    let holder = PDFDocument()
    holder.insert(copy, at: 0)
    return holder.page(at: 0).map { p in objc_setAssociatedObject(p, &snapshotHolderKey, holder, .OBJC_ASSOCIATION_RETAIN); return p }
}
private var snapshotHolderKey: UInt8 = 0
