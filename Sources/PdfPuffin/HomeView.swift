import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The Home tab, after PDF Expert's Home screen: a left sidebar (Home, Tools, Recents,
/// Favorites) and the page it selects on the right. Tool cards use PdfPuffin's own
/// look (an SF Symbol on a coloured tile), not PDF Expert's artwork.
final class HomeView: NSView {
    enum Page: Int, CaseIterable {
        case home, tools, recents, favorites
        var title: String { ["Home", "Tools", "Recents", "Favorites"][rawValue] }
        var symbol: String { ["house.fill", "square.stack.3d.up.fill", "clock.fill", "star.fill"][rawValue] }
    }

    weak var main: MainWindowController?
    private(set) var page: Page = .home
    private var navItems: [HomeNavItem] = []
    private var pages: [Page: (scroll: NSScrollView, stack: NSStackView)] = [:]
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let sidebar = ColorView(NSColor(srgbRed: 0.955, green: 0.955, blue: 0.962, alpha: 1))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let edge = ColorView(Theme.separator)
        edge.translatesAutoresizingMaskIntoConstraints = false
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        nav.translatesAutoresizingMaskIntoConstraints = false
        for p in Page.allCases {
            let item = HomeNavItem(title: p.title, symbol: p.symbol)
            item.onClick = { [weak self] in self?.show(p) }
            navItems.append(item)
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for v in [sidebar, edge, content] as [NSView] { addSubview(v) }
        sidebar.addSubview(nav)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 210),
            edge.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for p in Page.allCases {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(scroll)
            scroll.pinEdges(to: content)
            let doc = FlippedView()
            doc.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = doc
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(stack)
            NSLayoutConstraint.activate([
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 40),
                stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -40),
                stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 44),
                stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -44),
            ])
            pages[p] = (scroll, stack)
        }
        observer = NotificationCenter.default.addObserver(forName: Favorites.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        show(.home)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func show(_ p: Page) {
        page = p
        for (k, v) in pages { v.scroll.isHidden = k != p }
        for (i, item) in navItems.enumerated() { item.selected = i == p.rawValue }
    }

    // MARK: building the pages

    func refresh() {
        let recents = (main?.recentURLs ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
        let favorites = Favorites.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        build(.home) { s in
            s.add(label("Home", size: 32, weight: .bold))
            s.add(makeDropZone(), fullWidth: true)
            s.gap(30)
            s.add(header("Tools for You", links: [("View All", { [weak self] in self?.show(.tools) })]), fullWidth: true)
            s.add(FlowView(cardsFor: HomeTool.featured, home: self, maxRows: 1), fullWidth: true)
            s.gap(30)
            var recentLinks: [(String, () -> Void)] = []
            if !recents.isEmpty { recentLinks.append(("Clear All", { [weak self] in self?.main?.clearRecents(nil) })) }
            recentLinks.append(("View All", { [weak self] in self?.show(.recents) }))
            s.add(header("Recents", links: recentLinks), fullWidth: true)
            s.add(files(recents, empty: "Files you open appear here.", maxRows: 1), fullWidth: true)
            s.gap(30)
            s.add(header("Favorites", links: [("View All", { [weak self] in self?.show(.favorites) })]), fullWidth: true)
            s.add(files(favorites, empty: Favorites.hint, maxRows: 1), fullWidth: true)
        }
        build(.tools) { s in
            s.add(label("Tools", size: 32, weight: .bold))
            for (i, group) in HomeTool.groups.enumerated() {
                if i > 0 { s.gap(26) }
                s.add(label(group.title, size: 19, weight: .bold))
                s.add(FlowView(cardsFor: group.tools, home: self, maxRows: nil), fullWidth: true)
            }
        }
        build(.recents) { s in
            let clear: [(String, () -> Void)] = recents.isEmpty ? [] : [("Clear All", { [weak self] in self?.main?.clearRecents(nil) })]
            s.add(header("Recents", size: 32, links: clear), fullWidth: true)
            s.add(files(recents, empty: "Files you open appear here.", maxRows: nil), fullWidth: true)
        }
        build(.favorites) { s in
            s.add(label("Favorites", size: 32, weight: .bold))
            s.add(files(favorites, empty: Favorites.hint, maxRows: nil), fullWidth: true)
        }
    }

    private struct Builder {
        let stack: NSStackView
        func add(_ v: NSView, fullWidth: Bool = false) {
            stack.addArrangedSubview(v)
            if fullWidth { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        func gap(_ g: CGFloat) {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(g, after: last) }
        }
    }

    private func build(_ p: Page, _ fill: (Builder) -> Void) {
        guard let stack = pages[p]?.stack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fill(Builder(stack: stack))
    }

    private func header(_ title: String, size: CGFloat = 21, links: [(String, () -> Void)]) -> NSView {
        var views: [NSView] = [label(title, size: size, weight: .bold), NSView()]
        for (i, (text, action)) in links.enumerated() {
            if i > 0 { views.append(label("|", size: 14, color: Theme.separator)) }
            views.append(LinkButton(text, action))
        }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func files(_ urls: [URL], empty: String, maxRows: Int?) -> NSView {
        if urls.isEmpty { return label(empty, size: 13, color: .secondaryLabelColor) }
        let items: [NSView] = urls.map { u in
            let item = RecentItem(url: u)
            item.onOpen = { [weak self] in self?.main?.open(urls: [u]) }
            item.onRemoveRecent = { [weak self] in
                guard let main = self?.main else { return }
                main.recentURLs = main.recentURLs.filter { $0.standardizedFileURL != u.standardizedFileURL }
                self?.refresh()
            }
            return item
        }
        return FlowView(items: items, itemSize: RecentItem.size, spacing: NSSize(width: 22, height: 20), maxRows: maxRows)
    }

    private func makeDropZone() -> NSView {
        let drop = DropZone()
        drop.onDrop = { [weak self] urls in self?.main?.open(urls: urls) }
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 210).isActive = true
        let icon = NSImageView(image: Theme.symbol("doc.richtext", 50, weight: .light))
        icon.contentTintColor = Theme.accent.withAlphaComponent(0.55)
        let open = NSButton(title: "Open Files", target: nil, action: #selector(MainWindowController.openDocumentAction(_:)))
        open.bezelStyle = .push
        open.bezelColor = Theme.accent
        open.controlSize = .large
        open.refusesFirstResponder = true
        let clip = NSButton(title: "New from Clipboard", target: nil, action: #selector(MainWindowController.newFromClipboard(_:)))
        clip.bezelStyle = .push
        clip.controlSize = .large
        clip.refusesFirstResponder = true
        let buttons = NSStackView(views: [open, clip])
        buttons.spacing = 10
        let hint = label("or drop PDF or image files here", size: 14, color: Theme.accent)
        let inner = NSStackView(views: [icon, buttons, hint])
        inner.orientation = .vertical
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(inner)
        NSLayoutConstraint.activate([inner.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
                                     inner.centerYAnchor.constraint(equalTo: drop.centerYAnchor)])
        return drop
    }

    // MARK: running a tool

    /// Tools that work on a document ask for a PDF first (it opens in this tab),
    /// then run once the document is showing.
    func run(_ tool: HomeTool) {
        guard let main else { return }
        guard tool.documents > 0 else { tool.run(main); return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = tool.documents > 1
        p.message = tool.documents > 1 ? "Choose two or more PDFs to compare." : "Choose a PDF for \(tool.title)."
        p.prompt = "Open"
        guard p.runModal() == .OK, p.urls.count >= tool.documents else {
            if tool.documents > 1, !p.urls.isEmpty { NSSound.beep() }
            return
        }
        main.open(urls: p.urls)
        DispatchQueue.main.async { if main.current != nil { tool.run(main) } }
    }
}

// MARK: - tools

struct HomeTool {
    let title: String
    let symbol: String
    let tint: NSColor
    let tip: String
    /// How many documents it needs open first (0: none).
    let documents: Int
    let run: (MainWindowController) -> Void

    static let groups: [(title: String, tools: [HomeTool])] = {
        let edit = NSColor(srgbRed: 0.93, green: 0.45, blue: 0.20, alpha: 1)
        let organize = NSColor(srgbRed: 0.18, green: 0.56, blue: 0.86, alpha: 1)
        let convert = NSColor(srgbRed: 0.38, green: 0.62, blue: 0.30, alpha: 1)
        func t(_ title: String, _ symbol: String, _ tint: NSColor, _ tip: String, docs: Int = 1,
               _ run: @escaping (MainWindowController) -> Void) -> HomeTool {
            HomeTool(title: title, symbol: symbol, tint: tint, tip: tip, documents: docs, run: run)
        }
        return [
            ("Annotate and Sign", [
                t("Annotate", "highlighter", edit, "Highlight, underline, draw and add text") { m in
                    if m.altRow != nil || !m.toolsShown { m.toggleAnnotateTools(nil) }
                },
                t("Sign PDF", "signature", edit, "Place one of your signatures") { $0.signatureAction(nil) },
                t("Fill & Sign", "checklist", edit, "Text, dates, checkmarks and stamps for forms") { m in
                    if m.altRow != .fillSign { m.toggleFillSignTools(nil) }
                },
                t("Add Notes", "text.bubble", edit, "Click the page to place a sticky note") { $0.noteAction(nil) },
                t("Stamp", "seal", edit, "Approved, Reviewed, Draft and other stamps") { $0.stampToolAction(nil) },
                t("Crop Pages", "crop", edit, "Trim the margins of one page or all pages") { $0.cropPagesAction(nil) },
            ]),
            ("Organize and Optimize", [
                t("Manage Pages", "square.grid.2x2", organize, "Reorder, rotate, insert and delete pages") { m in
                    if m.current?.gridMode == false { m.toggleGridView(nil) }
                },
                t("Extract Pages", "doc.on.doc", organize, "Make a new PDF from a page range") { $0.excerptFromRange(nil) },
                t("Merge PDFs", "plus.rectangle.on.rectangle", organize, "Combine files into one packet", docs: 0) { $0.mergeFiles(nil) },
                t("Compare PDFs", "rectangle.split.2x1", organize, "Two documents side by side", docs: 2) { $0.compareDocuments(nil) },
                t("Recognize Text", "text.viewfinder", organize, "OCR scanned pages so they search and copy") { $0.recognizeText(nil) },
                t("Reduce File Size", "arrow.down.right.and.arrow.up.left", organize, "Save a smaller copy") { $0.reduceFileSize(nil) },
            ]),
            ("Convert and Protect", [
                t("PDF to Word", "doc.richtext", convert, "Export a .docx with the text and paragraphs") { $0.exportToWord(nil) },
                t("PDF to Images", "photo.on.rectangle", convert, "One PNG per page") { $0.exportToImages(nil) },
                t("Flatten", "square.3.layers.3d.down.right", convert, "Burn annotations and form entries into the pages") { $0.saveFlattened(nil) },
                t("Set Password", "lock.doc", convert, "Save a password-protected copy") { $0.setPassword(nil) },
                t("From Clipboard", "doc.on.clipboard", convert, "New PDF from a copied PDF or image", docs: 0) { $0.newFromClipboard(nil) },
                t("Properties", "info.circle", convert, "File details, page size and security") { $0.showProperties(nil) },
            ]),
        ]
    }()

    /// The row on the Home page.
    static var featured: [HomeTool] {
        let all = groups.flatMap(\.tools)
        return ["Annotate", "Manage Pages", "Sign PDF", "Recognize Text", "Merge PDFs", "PDF to Word", "Compare PDFs"]
            .compactMap { name in all.first { $0.title == name } }
    }
}

final class ToolCard: NSView {
    static let size = NSSize(width: 148, height: 122)
    /// Icon tile, placed so the tile and a one-line title sit centred in the card.
    static let tileRect = NSRect(x: (size.width - 46) / 2, y: size.height - 28 - 46, width: 46, height: 46)
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private let tint: NSColor

    init(_ tool: HomeTool) {
        tint = tool.tint
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = tool.tip
        let glyph = NSImageView(image: Theme.symbol(tool.symbol, 22, weight: .semibold))
        glyph.contentTintColor = .white
        glyph.frame = Self.tileRect
        glyph.imageAlignment = .alignCenter
        addSubview(glyph)
        let name = NSTextField(wrappingLabelWithString: tool.title)
        name.alignment = .center
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.maximumNumberOfLines = 0
        name.frame = NSRect(x: 6, y: 6, width: Self.size.width - 12, height: Self.tileRect.minY - 10 - 6)
        addSubview(name)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tool.title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: hovering ? 0.925 : 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        // The coloured tile behind the symbol (PdfPuffin's own style).
        let tile = Self.tileRect
        tint.setFill()
        NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - favorites

enum Favorites {
    static let changed = Notification.Name("PdfPuffinFavoritesChanged")
    static let hint = "Right-click a recent file, or choose File ▸ Add to Favorites, to keep it here."
    private static let key = "favorites"

    static var urls: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) } }
        set {
            UserDefaults.standard.set(newValue.map(\.path), forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    static func contains(_ url: URL) -> Bool { urls.contains { $0.standardizedFileURL == url.standardizedFileURL } }
    static func toggle(_ url: URL) {
        if contains(url) { urls = urls.filter { $0.standardizedFileURL != url.standardizedFileURL } }
        else { urls = [url] + urls }
    }
}

extension MainWindowController {
    @objc func toggleFavorite(_ sender: Any?) {
        guard let u = current?.fileURL else { return }
        Favorites.toggle(u)
        flash(Favorites.contains(u) ? "Added to Favorites" : "Removed from Favorites")
    }
}

// MARK: - small views

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A sidebar row: icon and title, with a rounded highlight when selected. Never takes focus.
final class HomeNavItem: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true; icon.contentTintColor = selected ? Theme.accent : NSColor(white: 0.2, alpha: 1) } }
    private let icon: NSImageView

    init(title: String, symbol: String) {
        icon = NSImageView(image: Theme.symbol(symbol, 17, weight: .medium))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = label(title, size: 15)
        addSubview(icon); addSubview(name)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        selected = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor(white: 0.885, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A text-only link ("View All", "Clear All").
final class LinkButton: NSButton {
    private var handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 14)
        contentTintColor = Theme.accent
        refusesFirstResponder = true
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Lays out same-size items in rows that fill the available width. With `maxRows`
/// set, items past those rows are hidden (the section's "View All" shows them).
final class FlowView: NSView {
    private let itemSize: NSSize
    private let spacing: NSSize
    private let maxRows: Int?
    private var height: NSLayoutConstraint!
    override var isFlipped: Bool { true }

    init(items: [NSView], itemSize: NSSize, spacing: NSSize, maxRows: Int?) {
        self.itemSize = itemSize
        self.spacing = spacing
        self.maxRows = maxRows
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: itemSize.height)
        height.isActive = true
        for v in items { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
    }
    convenience init(cardsFor tools: [HomeTool], home: HomeView, maxRows: Int?) {
        let cards: [NSView] = tools.map { tool in
            let c = ToolCard(tool)
            c.onClick = { [weak home] in home?.run(tool) }
            return c
        }
        self.init(items: cards, itemSize: ToolCard.size, spacing: NSSize(width: 14, height: 14), maxRows: maxRows)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let cols = max(1, Int((bounds.width + spacing.width) / (itemSize.width + spacing.width)))
        var rows = 0
        for (i, v) in subviews.enumerated() {
            let r = i / cols
            if let maxRows, r >= maxRows { v.isHidden = true; continue }
            v.isHidden = false
            v.frame = NSRect(x: CGFloat(i % cols) * (itemSize.width + spacing.width),
                             y: CGFloat(r) * (itemSize.height + spacing.height),
                             width: itemSize.width, height: itemSize.height)
            rows = r + 1
        }
        let h = rows == 0 ? 0 : CGFloat(rows) * itemSize.height + CGFloat(rows - 1) * spacing.height
        if height.constant != h { height.constant = h }
    }
}

final class RecentItem: NSView {
    static let size = NSSize(width: 125, height: 196)
    var onOpen: (() -> Void)?
    var onRemoveRecent: (() -> Void)?
    private let url: URL
    private let imageView = NSImageView()
    private static let cache = NSCache<NSString, NSImage>()
    private static let queue = DispatchQueue(label: "com.hs.PdfPuffin.homeThumbs", qos: .userInitiated)
    override var isFlipped: Bool { true }

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.borderColor = NSColor(white: 0.85, alpha: 1).cgColor
        imageView.layer?.borderWidth = 1
        imageView.frame = NSRect(x: (Self.size.width - 112) / 2, y: 0, width: 112, height: 145)
        addSubview(imageView)
        if Favorites.contains(url) {
            let star = NSImageView(image: Theme.symbol("star.fill", 12))
            star.contentTintColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.1, alpha: 1)
            star.frame = NSRect(x: imageView.frame.maxX - 20, y: 4, width: 16, height: 16)
            addSubview(star)
        }
        let name = NSTextField(wrappingLabelWithString: url.deletingPathExtension().lastPathComponent)
        name.alignment = .center
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 0, y: 153, width: Self.size.width, height: 34)
        addSubview(name)
        toolTip = url.path
        loadThumbnail()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func loadThumbnail() {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let img = Self.cache.object(forKey: key) { imageView.image = img; return }
        let url = self.url
        Self.queue.async { [weak self] in
            // A private PDFDocument, so drawing it off the main thread is safe.
            let doc = PDFDocument(url: url)   // keep it alive while its page draws
            let img = withExtendedLifetime(doc) {
                doc?.page(at: 0)?.thumbnail(of: NSSize(width: 224, height: 290), for: .cropBox)
            } ?? NSImage(contentsOf: url)
            DispatchQueue.main.async {
                let shown = img ?? NSWorkspace.shared.icon(forFile: url.path)
                if img != nil { Self.cache.setObject(shown, forKey: key) }
                self?.imageView.image = shown
            }
        }
    }

    override func mouseDown(with event: NSEvent) { if event.clickCount == 1 { onOpen?() } }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) { m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add("Open", #selector(openClicked))
        add(Favorites.contains(url) ? "Remove from Favorites" : "Add to Favorites", #selector(favoriteClicked))
        add("Show in Finder", #selector(finderClicked))
        if onRemoveRecent != nil, (UserDefaults.standard.stringArray(forKey: "recents") ?? []).contains(url.path) {
            m.addItem(.separator())
            add("Remove from Recents", #selector(removeClicked))
        }
        return m
    }
    @objc private func openClicked() { onOpen?() }
    @objc private func favoriteClicked() { Favorites.toggle(url) }
    @objc private func finderClicked() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func removeClicked() { onRemoveRecent?() }
}

final class DropZone: NSView {
    var onDrop: (([URL]) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let bg = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: hovering ? 1 : 0.8).setFill()
        bg.fill()
        let dash = NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 10, yRadius: 10)
        dash.setLineDash([10, 7], count: 2, phase: 0)
        dash.lineWidth = 2
        Theme.accent.withAlphaComponent(hovering ? 0.8 : 0.35).setStroke()
        dash.stroke()
    }
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = !urls(sender).isEmpty
        return hovering ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false
        let u = urls(sender)
        onDrop?(u)
        return !u.isEmpty
    }
}
