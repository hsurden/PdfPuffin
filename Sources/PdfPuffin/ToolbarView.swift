import AppKit
import PDFKit

/// The dark main toolbar: sidebar / layout / zoom on the left, the Annotate
/// mode tab in the middle, Search on the right. Nothing here keeps focus
/// except the search field while you type in it.
final class ToolbarView: NSView, NSSearchFieldDelegate {
    weak var main: MainWindowController?
    let sidebarButton: NSButton
    let gridButton: NSButton
    let layoutButton: NSButton
    private let settings = NSPopover()
    let zoomButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let zoomOut: NSButton
    let zoomIn: NSButton
    let annotateTab = ModeTab(title: "Annotate", symbol: "character.textbox")
    let convertTab = ModeTab(title: "Convert", symbol: "square.and.arrow.up")
    let fillTab = ModeTab(title: "Fill & Sign", symbol: "signature")
    let searchField = NSSearchField()
    private var docControls: [NSView] = []

    init() {
        layoutButton = iconButton("slider.horizontal.3", tip: "View Settings", target: nil, action: nil, tint: Theme.toolbarIcon, size: 16, width: 34)
        gridButton = iconButton("square.grid.2x2", tip: "Page Thumbnails (⌘4): view, reorder, rotate, insert and delete pages", target: nil, action: #selector(MainWindowController.toggleGridView(_:)), tint: Theme.toolbarIcon, size: 15, width: 34)
        sidebarButton = iconButton("sidebar.left", tip: "Show / Hide Left Panel (⌥⌘0)", target: nil, action: #selector(MainWindowController.toggleLeftPanel(_:)), tint: Theme.toolbarIcon, size: 16, width: 34)
        zoomOut = iconButton("minus", tip: "Zoom Out (⌘−)", target: nil, action: #selector(MainWindowController.zoomOutAction(_:)), tint: Theme.toolbarIcon, size: 13)
        zoomIn = iconButton("plus", tip: "Zoom In (⌘+)", target: nil, action: #selector(MainWindowController.zoomInAction(_:)), tint: Theme.toolbarIcon, size: 13)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.toolbar.cgColor
        appearance = NSAppearance(named: .darkAqua)

        layoutButton.target = self
        layoutButton.action = #selector(showSettings)
        layoutButton.setAccessibilityLabel("View Settings")
        settings.behavior = .transient

        // Zoom menu
        zoomButton.refusesFirstResponder = true
        zoomButton.toolTip = "Zoom"
        zoomButton.bezelStyle = .flexiblePush
        zoomButton.controlSize = .regular
        let zm = zoomButton.menu!
        zm.addItem(withTitle: "100%", action: nil, keyEquivalent: "")
        for (t, sel) in [("Zoom to Fit Width", #selector(MainWindowController.zoomFitWidthAction(_:))),
                         ("Zoom to Fit Page", #selector(MainWindowController.zoomFitPageAction(_:))),
                         ("Automatic", #selector(MainWindowController.zoomAutoAction(_:)))] {
            zm.addItem(withTitle: t, action: sel, keyEquivalent: "")
        }
        zm.addItem(.separator())
        for p in [50, 75, 100, 125, 150, 200, 300, 400] {
            let i = zm.addItem(withTitle: "\(p)%", action: #selector(MainWindowController.zoomPercentAction(_:)), keyEquivalent: "")
            i.tag = p
        }

        annotateTab.target = nil
        annotateTab.action = #selector(MainWindowController.toggleAnnotateTools(_:))
        annotateTab.toolTip = "Show / Hide Annotate Tools"
        convertTab.target = nil
        convertTab.action = #selector(MainWindowController.toggleConvertTools(_:))
        convertTab.toolTip = "Convert: export this PDF to Word"
        fillTab.target = nil
        fillTab.action = #selector(MainWindowController.toggleFillSignTools(_:))
        fillTab.toolTip = "Fill & Sign: text, signature, date, checkmark, cross, stamp"
        let modeTabs = NSStackView(views: [annotateTab, convertTab, fillTab])
        modeTabs.spacing = 0

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = nil
        searchField.action = #selector(MainWindowController.searchFieldAction(_:))
        searchField.controlSize = .regular
        searchField.focusRingType = .none

        let left = NSStackView(views: [sidebarButton, gridButton, layoutButton, zoomButton, zoomOut, zoomIn])
        left.spacing = 6
        left.setCustomSpacing(14, after: layoutButton)
        left.setCustomSpacing(10, after: zoomButton)
        for v in [left, modeTabs, searchField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // Keep the mode tabs centered when space permits and preserve both gaps
        // as the window narrows. Search gives up its extra width first.
        let centerTabs = modeTabs.centerXAnchor.constraint(equalTo: centerXAnchor)
        centerTabs.priority = NSLayoutConstraint.Priority(700)
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 200)
        searchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 84),
            centerTabs,
            modeTabs.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 10),
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: modeTabs.trailingAnchor, constant: 10),
            modeTabs.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            modeTabs.bottomAnchor.constraint(equalTo: bottomAnchor),
            annotateTab.heightAnchor.constraint(equalTo: modeTabs.heightAnchor),
            convertTab.heightAnchor.constraint(equalTo: modeTabs.heightAnchor),
            fillTab.heightAnchor.constraint(equalTo: modeTabs.heightAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchWidth,
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        docControls = [layoutButton, zoomButton, zoomOut, zoomIn, annotateTab, convertTab, fillTab, sidebarButton, gridButton]
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(doc: DocumentViewController?, toolsShown: Bool, altRow: AltRow?) {
        for c in docControls { (c as? NSControl)?.isEnabled = doc != nil; c.alphaValue = doc == nil ? 0.35 : 1 }
        annotateTab.isOn = toolsShown && altRow == nil && doc != nil
        convertTab.isOn = altRow == .convert && doc != nil
        fillTab.isOn = altRow == .fillSign && doc != nil
        guard let d = doc else { zoomButton.menu?.item(at: 0)?.title = "—"; return }
        zoomButton.menu?.item(at: 0)?.title = "\(Int((d.pdfView.scaleFactor * 100).rounded()))%"
        zoomButton.synchronizeTitleAndSelectedItem()
        sidebarButton.contentTintColor = d.sidebarVisible ? .white : Theme.toolbarIcon
        // Grid open: highlight its button; reading controls don't apply.
        gridButton.wantsLayer = true
        gridButton.layer?.cornerRadius = 5
        gridButton.layer?.backgroundColor = d.gridMode ? NSColor(white: 1, alpha: 0.22).cgColor : NSColor.clear.cgColor
        gridButton.contentTintColor = d.gridMode ? .white : Theme.toolbarIcon
        for c in [layoutButton, zoomButton, zoomOut, zoomIn, annotateTab, convertTab, fillTab] as [NSView] {
            (c as? NSControl)?.isEnabled = !d.gridMode
            c.alphaValue = d.gridMode ? 0.35 : 1
        }
    }

    @objc func showSettings() {
        if settings.isShown { settings.performClose(nil); return }
        guard let main, let doc = main.current else { return }
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.alignment = .leading
        panel.spacing = 8
        panel.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        func heading(_ text: String) { panel.addArrangedSubview(label(text, size: 12, weight: .semibold)) }
        func choices(_ labels: [String], value: Int, action: Selector) {
            let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
            control.selectedSegment = value
            panel.addArrangedSubview(control)
        }
        heading("Page Layout")
        choices(["Single Page", "Two Pages", "First Page Single"], value: doc.layout.rawValue - 1, action: #selector(changeLayout(_:)))
        let scroll = NSButton(checkboxWithTitle: "Continuous Scroll", target: main,
                              action: #selector(MainWindowController.toggleContinuous(_:)))
        scroll.state = doc.continuous ? .on : .off
        panel.addArrangedSubview(scroll)
        heading("Split View")
        choices(["No Split", "Horizontal", "Vertical"], value: doc.splitDirection, action: #selector(changeSplit(_:)))
        let compare = NSButton(title: "Compare Open Documents…", target: self, action: #selector(compareTabs))
        compare.isEnabled = main.documentControllers.count > 1
        compare.toolTip = "Open two PDF tabs to compare them."
        panel.addArrangedSubview(compare)
        let vc = NSViewController()
        vc.view = panel
        settings.contentViewController = vc
        settings.contentSize = panel.fittingSize
        settings.show(relativeTo: layoutButton.bounds, of: layoutButton, preferredEdge: .minY)
    }

    @objc private func changeLayout(_ control: NSSegmentedControl) {
        let item = NSMenuItem()
        item.tag = control.selectedSegment + 1
        main?.setLayoutAction(item)
    }
    @objc private func changeSplit(_ control: NSSegmentedControl) {
        let item = NSMenuItem()
        item.tag = control.selectedSegment
        main?.setReadingSplit(item)
    }
    @objc private func compareTabs() {
        settings.performClose(nil)
        main?.compareDocuments(nil)
    }

    // Esc in the search field closes the panel; ↑/↓ step through results.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): main?.closeSearch(); return true
        case #selector(NSResponder.moveDown(_:)): main?.findNext(nil); return true
        case #selector(NSResponder.moveUp(_:)): main?.findPrevious(nil); return true
        case #selector(NSResponder.insertNewline(_:)):
            main?.searchEnter(); return true
        default: return false
        }
    }
}

/// The light "Annotate" tab that sits in the dark toolbar like PDF Expert's mode tabs.
final class ModeTab: NSControl {
    let title: String
    let symbol: String
    var isOn = true { didSet { needsDisplay = true } }
    init(title: String, symbol: String) {
        self.title = title; self.symbol = symbol
        super.init(frame: .zero)
        let w = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]).width
        widthAnchor.constraint(equalToConstant: max(124, ceil(w) + 56)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            Theme.toolbarSelected.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 0) , xRadius: 0, yRadius: 0).fill()
        }
        let color = isOn ? NSColor(white: 0.1, alpha: 1) : Theme.toolbarIcon
        let img = Theme.symbol(symbol, 14).tinted(color)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color]
        let s = (title as NSString).size(withAttributes: attrs)
        let total = img.size.width + 8 + s.width
        let x = (bounds.width - total) / 2
        img.draw(in: NSRect(x: x, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        (title as NSString).draw(at: NSPoint(x: x + img.size.width + 8, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

/// Which row replaces the Annotate bar (PDF Expert's mode tabs).
enum AltRow { case convert, fillSign }

/// The light second row in Convert mode: PDF Expert's export row.
final class ConvertRowView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.toolRow.cgColor
        func button(_ title: String, _ img: NSImage, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, image: img, target: nil, action: sel)
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.font = .systemFont(ofSize: 14)
            b.contentTintColor = NSColor(white: 0.22, alpha: 1)
            b.toolTip = tip
            b.refusesFirstResponder = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        typealias M = MainWindowController
        let word = NSStackView(views: [
            button("to Word", Self.letterBox("W"), "Convert this PDF to a Word document (.docx)", #selector(M.exportToWord(_:))),
            button("to Text", Self.letterBox("T"), "Save the text as a plain-text file", #selector(M.exportToText(_:))),
            button("to RTF", Self.letterBox("R"), "Save the text with fonts as Rich Text (.rtf)", #selector(M.exportToRTF(_:))),
            button("to HTML", Self.letterBox("H"), "Save the text as a web page (.html)", #selector(M.exportToHTML(_:))),
            button("to Image", Theme.symbol("photo", 16).tinted(NSColor(white: 0.22, alpha: 1)), "Save each page as a PNG image", #selector(M.exportToImages(_:))),
        ])
        word.spacing = 28
        let line = ColorView(Theme.separator)
        for v in [word, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            word.centerXAnchor.constraint(equalTo: centerXAnchor),
            word.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// PDF Expert's outlined letter-in-a-box format icons.
    static func letterBox(_ letter: String) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { r in
            let ink = NSColor(white: 0.22, alpha: 1)
            ink.setStroke()
            let box = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 17, height: 17), xRadius: 2.5, yRadius: 2.5)
            box.lineWidth = 1.4
            box.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ink]
            let a = letter as NSString
            let sz = a.size(withAttributes: attrs)
            a.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2), withAttributes: attrs)
            return true
        }
    }
}

/// The light second row: PDF Expert's annotate bar.
/// A-highlight, A-underline, A-strikeout | Pen, Eraser | Text, Shapes | Note, Signature.
final class ToolRowView: NSView {
    weak var main: MainWindowController?
    private var markupButtons: [(PDFAnnotationSubtype, NSButton)] = []
    private var toolButtons: [(Set<ShapeTool>, NSButton)] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.toolRow.cgColor
        let tint = NSColor(white: 0.22, alpha: 1)
        typealias M = MainWindowController
        func tool(_ img: NSImage, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: img, target: nil, action: sel)
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = tint
            b.toolTip = tip
            b.refusesFirstResponder = true
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        let select = tool(Theme.symbol("hand.raised", 15), "Hand: scroll and select (Esc)", #selector(M.selectToolAction(_:)))
        let hl = tool(Self.letterA(.highlight), "Highlight (⌃⌘H)", #selector(M.highlightAction(_:)))
        let ul = tool(Self.letterA(.underline), "Underline (⌃⌘U)", #selector(M.underlineAction(_:)))
        let st = tool(Self.letterA(.strikeOut), "Strikeout (⌃⌘S)", #selector(M.strikeoutAction(_:)))
        let pen = tool(Theme.symbol("pencil.tip", 16), "Pen (⌃⌘P)", #selector(M.penAction(_:)))
        let eraser = tool(Theme.symbol("eraser", 16), "Eraser (⌃⌘E)", #selector(M.eraserAction(_:)))
        let text = tool(Theme.symbol("character.textbox", 16), "Text (⌃⌘T): click on the page and type", #selector(M.textToolAction(_:)))
        let shapes = tool(Theme.symbol("square.on.circle", 16), "Shapes: rectangle (⌃⌘R), oval (⌃⌘O), line (⌃⌘L), arrow (⌃⌘A), highlight area", #selector(M.shapesAction(_:)))
        let note = tool(Theme.symbol("text.bubble", 16), "Note (⌃⌘N)", #selector(M.noteAction(_:)))
        let sig = tool(Theme.symbol("signature", 16), "Signature", #selector(M.signatureAction(_:)))
        let bm = tool(Theme.symbol("bookmark", 15), "Add Bookmark (⌘D)", #selector(M.addBookmarkAction(_:)))
        markupButtons = [(.highlight, hl), (.underline, ul), (.strikeOut, st)]
        toolButtons = [([.pen], pen), ([.eraser], eraser), ([.text], text), (Set(ShapeTool.shapes), shapes), ([.note], note), ([.signature], sig)]

        let tools = NSStackView(views: [hl, ul, st, pen, eraser, text, shapes, note, sig])
        tools.spacing = 4
        for after in [st, eraser, shapes] { tools.setCustomSpacing(30, after: after) }
        for v in [select, tools, bm] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let line = ColorView(Theme.separator)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            select.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            select.centerYAnchor.constraint(equalTo: centerYAnchor),
            tools.centerXAnchor.constraint(equalTo: centerXAnchor),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            bm.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bm.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// PDF Expert's "A" icons: on a block (highlight), underlined, struck through.
    static func letterA(_ kind: PDFAnnotationSubtype) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { r in
            let ink = NSColor(white: 0.18, alpha: 1)
            if kind == .highlight {
                NSColor(white: 0.62, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 18, height: 18), xRadius: 2, yRadius: 2).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .regular),
                                                         .foregroundColor: ink]
            let a = "A" as NSString
            let sz = a.size(withAttributes: attrs)
            a.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2 + (kind == .underline ? 2 : 0)), withAttributes: attrs)
            ink.setFill()
            if kind == .underline { NSRect(x: 4, y: 2, width: 14, height: 1.4).fill() }
            if kind == .strikeOut { NSRect(x: 3, y: 10.5, width: 16, height: 1.3).fill() }
            return true
        }
    }

    func update(markup: PDFAnnotationSubtype?, shape: ShapeTool?, colorKey: String) {
        func style(_ b: NSButton, _ on: Bool) {
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.layer?.backgroundColor = on ? NSColor(white: 0.84, alpha: 1).cgColor : NSColor.clear.cgColor
            b.layer?.borderWidth = on ? 1 : 0
            b.layer?.borderColor = Theme.accent.cgColor
        }
        for (t, b) in markupButtons { style(b, t == markup) }
        for (set, b) in toolButtons { style(b, shape.map { set.contains($0) } ?? false) }
    }
}
