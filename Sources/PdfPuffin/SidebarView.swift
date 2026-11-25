import AppKit
import PDFKit

enum SidebarTab: Int, CaseIterable {
    case bookmarks = 0, outline, annotations, thumbnails
    var title: String { ["Bookmarks", "Outline", "Annotations", "Thumbnails"][rawValue] }
    var symbol: String { ["bookmark", "list.bullet", "character.textbox", "doc.fill"][rawValue] }
}

/// A table that never takes keyboard focus, so arrow keys always reach the PDF.
final class FocuslessTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}
final class FocuslessOutlineView: NSOutlineView {
    override var acceptsFirstResponder: Bool { false }
}

/// Left panel with PDF Expert's four tabs.
final class SidebarView: NSView {
    weak var doc: DocumentViewController? {
        didSet { thumbnails.doc = doc; bookmarks.doc = doc; outline.doc = doc; annotations.doc = doc }
    }
    let thumbnails = ThumbnailsPane()
    let bookmarks = BookmarksPane()
    let outline = OutlinePane()
    let annotations = AnnotationsPane()
    private let segmented = NSSegmentedControl()
    private let header = label("Thumbnails", size: 13, weight: .semibold)
    private let container = NSView()
    private(set) var current: SidebarTab = .thumbnails

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor

        segmented.segmentCount = SidebarTab.allCases.count
        segmented.segmentStyle = .automatic
        segmented.trackingMode = .selectOne
        for t in SidebarTab.allCases {
            segmented.setImage(Theme.symbol(t.symbol, 13), forSegment: t.rawValue)
            segmented.setToolTip(t.title, forSegment: t.rawValue)
            segmented.setWidth(46, forSegment: t.rawValue)
        }
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.refusesFirstResponder = true
        segmented.translatesAutoresizingMaskIntoConstraints = false

        let line = ColorView(Theme.separator)
        line.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        for v in [segmented, header, line, container] { addSubview(v) }
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            segmented.centerXAnchor.constraint(equalTo: centerXAnchor),
            header.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            container.topAnchor.constraint(equalTo: line.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for pane in [thumbnails, bookmarks, outline, annotations] as [NSView] {
            container.addSubview(pane)
            pane.pinEdges(to: container)
        }
        select(.thumbnails)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: SidebarTab) {
        current = tab
        segmented.selectedSegment = tab.rawValue
        header.stringValue = tab.title
        thumbnails.isHidden = tab != .thumbnails
        bookmarks.isHidden = tab != .bookmarks
        outline.isHidden = tab != .outline
        annotations.isHidden = tab != .annotations
        if tab == .thumbnails, let d = doc { thumbnails.setCurrent(d.currentPageIndex) }
    }

    @objc private func segmentChanged() {
        select(SidebarTab(rawValue: segmented.selectedSegment) ?? .thumbnails)
    }

    func reloadAll() {
        thumbnails.reload(); bookmarks.reload(); outline.reload(); annotations.reload()
    }
}

// MARK: - Small shared pieces

func makeScroll(_ doc: NSView) -> NSScrollView {
    let s = NSScrollView()
    s.documentView = doc
    s.hasVerticalScroller = true
    s.autohidesScrollers = true
    s.drawsBackground = false
    s.borderType = .noBorder
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

func emptyLabel(_ text: String) -> NSTextField {
    let l = label(text, size: 12, color: .secondaryLabelColor)
    l.alignment = .center
    l.maximumNumberOfLines = 0
    l.preferredMaxLayoutWidth = 180
    return l
}

func plainTable(_ t: NSTableView) {
    t.headerView = nil
    t.backgroundColor = .clear
    t.style = .sourceList
    t.addTableColumn(NSTableColumn(identifier: .init("c")))
    t.refusesFirstResponder = true
}

func textCell(_ table: NSTableView, _ text: String, secondary: String? = nil) -> NSView {
    let id = NSUserInterfaceItemIdentifier("text")
    let cell = (table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
        let c = NSTableCellView()
        c.identifier = id
        let t = NSTextField(labelWithString: "")
        t.translatesAutoresizingMaskIntoConstraints = false
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 0          // show all of it; rows grow to fit
        t.cell?.truncatesLastVisibleLine = false
        c.addSubview(t)
        c.textField = t
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
            t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
            t.topAnchor.constraint(equalTo: c.topAnchor, constant: 5),
            t.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -5),
        ])
        return c
    }()
    let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
    if let secondary, !secondary.isEmpty {
        s.append(NSAttributedString(string: "\n" + secondary, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    cell.textField?.attributedStringValue = s
    return cell
}

/// First line of a page's text, used as a hint next to bookmarks.
func firstLine(of page: PDFPage?) -> String {
    let s = page?.string ?? ""
    return s.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.count > 3 } ?? ""
}

// MARK: - Bookmarks

final class BookmarksPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var doc: DocumentViewController?
    private let table = FocuslessTableView()
    private let empty = emptyLabel("No bookmarks yet.\nPress ⌘D to bookmark the current page.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        plainTable(table)
        table.usesAutomaticRowHeights = true
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        let menu = NSMenu()
        menu.addItem(withTitle: "Remove Bookmark", action: #selector(removeClicked), keyEquivalent: "").target = self
        table.menu = menu
        let scroll = makeScroll(table)
        let add = NSButton(title: "Add Bookmark", target: self, action: #selector(addClicked))
        add.refusesFirstResponder = true
        add.controlSize = .small
        add.translatesAutoresizingMaskIntoConstraints = false
        for v in [scroll, empty, add] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -8),
            add.centerXAnchor.constraint(equalTo: centerXAnchor),
            add.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: 40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        table.reloadData()
        empty.isHidden = !(doc?.bookmarks.isEmpty ?? true)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { doc?.bookmarks.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let d = doc else { return nil }
        let i = d.bookmarks[row]
        return textCell(tableView, "Page \(i + 1)", secondary: firstLine(of: d.document.page(at: i)))
    }
    @objc private func clicked() {
        guard let d = doc, table.clickedRow >= 0 else { return }
        d.jump(toPage: d.bookmarks[table.clickedRow])
    }
    @objc private func addClicked() { doc?.toggleBookmark() }
    @objc private func removeClicked() {
        guard let d = doc, table.clickedRow >= 0 else { return }
        d.bookmarks.remove(at: table.clickedRow)
    }
}

// MARK: - Outline

final class OutlinePane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var doc: DocumentViewController?
    private let outline = FocuslessOutlineView()
    private let empty = emptyLabel("This document has no outline.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .sourceList
        let col = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.refusesFirstResponder = true
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(clicked)
        outline.usesAutomaticRowHeights = true
        let scroll = makeScroll(outline)
        addSubview(scroll); addSubview(empty)
        scroll.pinEdges(to: self)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: 40),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var root: PDFOutline? { doc?.document.outlineRoot }

    func reload() {
        outline.reloadData()
        empty.isHidden = (root?.numberOfChildren ?? 0) > 0
        if let r = root { for i in 0..<r.numberOfChildren where r.child(at: i)?.isOpen == true { outline.expandItem(r.child(at: i)) } }
    }
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)!.child(at: index)!
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let ol = item as? PDFOutline else { return nil }
        var pageText = ""
        if let p = ol.destination?.page, let d = doc { pageText = "p. \(d.document.index(for: p) + 1)" }
        return textCell(o, ol.label ?? "", secondary: pageText)
    }
    @objc private func clicked() {
        guard let ol = outline.item(atRow: outline.clickedRow) as? PDFOutline, let d = doc else { return }
        if let dest = ol.destination { d.jump(to: dest) }
        else if let a = ol.action as? PDFActionGoTo { d.jump(to: a.destination) }
    }
}

// MARK: - Annotations

final class AnnotationsPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var doc: DocumentViewController?
    private let filterControl = NSSegmentedControl(labels: ["All", "Notes", "Highlights"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = FocuslessTableView()
    private let empty = emptyLabel("No annotations.\nSelect text and press ⌃⌘H to highlight.")
    private var allItems: [(page: Int, annotation: PDFAnnotation)] = []
    private(set) var items: [(page: Int, annotation: PDFAnnotation)] = []
    static let kinds: Set<String> = ["Highlight", "Underline", "StrikeOut", "Text", "FreeText", "Ink",
                                     "Square", "Circle", "Line", "Squiggly", "Stamp"]

    var filterIndex: Int {
        get { filterControl.selectedSegment }
        set { filterControl.selectedSegment = newValue; applyFilter() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.refusesFirstResponder = true
        filterControl.controlSize = .small
        filterControl.segmentDistribution = .fillEqually
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        plainTable(table)
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.usesAutomaticRowHeights = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Edit Comment", action: #selector(editCommentClicked), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy as Markdown", action: #selector(MainWindowController.copyReadingNotes(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Save as Markdown…", action: #selector(MainWindowController.saveReadingNotes(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete Annotation", action: #selector(deleteClicked), keyEquivalent: "").target = self
        table.menu = menu
        let scroll = makeScroll(table)
        addSubview(filterControl); addSubview(scroll); addSubview(empty)
        NSLayoutConstraint.activate([
            filterControl.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            filterControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            filterControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        allItems = []
        if let d = doc?.document {
            for i in 0..<d.pageCount {
                for a in d.page(at: i)?.annotations ?? [] where Self.kinds.contains(a.type ?? "") {
                    allItems.append((i, a))
                }
            }
        }
        applyFilter()
    }

    private func applyFilter() {
        switch filterControl.selectedSegment {
        case 1:
            items = allItems.filter { (i, a) in
                if a.type == "Text" || a.type == "FreeText" { return true }
                guard let page = doc?.document.page(at: i) else { return false }
                return !NoteCardEditor.distinctComment(for: a, on: page).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case 2:
            items = allItems.filter { ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains($0.annotation.type ?? "") }
        default:
            items = allItems
        }
        empty.stringValue = allItems.isEmpty
            ? "No annotations.\nSelect text and press ⌃⌘H to highlight."
            : "No matching annotations."
        table.reloadData()
        empty.isHidden = !items.isEmpty
    }

    @objc private func filterChanged() { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (page, a) = items[row]
        let kind: String
        switch a.type ?? "" {
        case "Text": kind = "Note"
        case "StrikeOut": kind = "Strikethrough"
        case "Square": kind = a.interiorColor != nil && a.interiorColor != .clear ? "Highlight Area" : "Rectangle"
        case "Circle": kind = "Oval"
        case "FreeText": kind = "Text"
        case "Ink": kind = "Pen"
        case "Stamp": kind = a is SignatureAnnotation ? "Signature" : "Stamp"
        default: kind = a.type ?? ""
        }
        let pageLabel = doc?.printedLabel(at: page) ?? String(page + 1)
        let pObj = doc?.document.page(at: page)
        let isMarkup = ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(a.type ?? "")
        let quote = (isMarkup && pObj != nil) ? NoteCardEditor.passage(for: a, on: pObj!) : ""
        let comment = pObj != nil
            ? NoteCardEditor.distinctComment(for: a, on: pObj!).trimmingCharacters(in: .whitespacesAndNewlines)
            : (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stripeColor: NSColor
        if a.type == "FreeText" {
            stripeColor = a.fontColor ?? AnnotColors.color(for: "text")
        } else if a.type == "Square", (a.border?.lineWidth ?? 0) == 0, let ic = a.interiorColor {
            stripeColor = ic
        } else {
            stripeColor = a.color
        }
        let id = NSUserInterfaceItemIdentifier("annotCard")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? AnnotationCardCell) ?? {
            let c = AnnotationCardCell()
            c.identifier = id
            return c
        }()
        cell.configure(header: "\(kind) · p. \(pageLabel)", quote: quote, comment: comment, color: stripeColor)
        return cell
    }

    @objc private func clicked() {
        guard let d = doc, table.clickedRow >= 0 else { return }
        let (i, a) = items[table.clickedRow]
        guard let page = d.document.page(at: i) else { return }
        d.jump(to: PDFDestination(page: page, at: NSPoint(x: a.bounds.minX, y: a.bounds.maxY + 40)))
    }

    @objc private func doubleClicked() {
        guard let d = doc, table.clickedRow >= 0 else { return }
        let (i, a) = items[table.clickedRow]
        guard let page = d.document.page(at: i) else { return }
        d.jump(to: PDFDestination(page: page, at: NSPoint(x: a.bounds.minX, y: a.bounds.maxY + 40)))
        if ["Text", "Highlight", "Underline", "StrikeOut", "Squiggly"].contains(a.type ?? "") {
            d.openNoteCard(for: a, on: page, isNew: false)
        } else if a.type == "FreeText" {
            d.editText(a, on: page, at: .zero)
        }
    }

    @objc private func editCommentClicked() {
        guard let d = doc, table.clickedRow >= 0 else { return }
        let (i, a) = items[table.clickedRow]
        guard let page = d.document.page(at: i) else { return }
        d.jump(to: PDFDestination(page: page, at: NSPoint(x: a.bounds.minX, y: a.bounds.maxY + 40)))
        if ["Text", "Highlight", "Underline", "StrikeOut", "Squiggly"].contains(a.type ?? "") {
            d.openNoteCard(for: a, on: page, isNew: false)
        } else if a.type == "FreeText" {
            d.editText(a, on: page, at: .zero)
        }
    }

    @objc private func deleteClicked() {
        guard let d = doc, table.clickedRow >= 0 else { return }
        let (_, a) = items[table.clickedRow]
        d.removeAnnotation(a)
    }
}

final class AnnotationCardCell: NSTableCellView {
    private let stripe = NSView()
    private let headerLabel = label("", size: 11, weight: .semibold, color: .secondaryLabelColor)
    private let quoteLabel = NSTextField(wrappingLabelWithString: "")
    private let commentLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        stripe.wantsLayer = true
        stripe.layer?.cornerRadius = 1.5
        stripe.translatesAutoresizingMaskIntoConstraints = false

        quoteLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 11.5), toHaveTrait: .italicFontMask)
        quoteLabel.textColor = .secondaryLabelColor
        quoteLabel.maximumNumberOfLines = 0
        quoteLabel.cell?.truncatesLastVisibleLine = false

        commentLabel.font = .systemFont(ofSize: 12)
        commentLabel.textColor = .labelColor
        commentLabel.maximumNumberOfLines = 0
        commentLabel.cell?.truncatesLastVisibleLine = false

        let stack = NSStackView(views: [headerLabel, quoteLabel, commentLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stripe)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stripe.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stripe.widthAnchor.constraint(equalToConstant: 3),

            stack.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(header: String, quote: String, comment: String, color: NSColor) {
        let opaque = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(1)
        stripe.layer?.backgroundColor = opaque.cgColor
        headerLabel.stringValue = header
        quoteLabel.stringValue = quote.isEmpty ? "" : "“\(quote)”"
        quoteLabel.isHidden = quote.isEmpty
        commentLabel.stringValue = comment
        commentLabel.isHidden = comment.isEmpty
    }
}
