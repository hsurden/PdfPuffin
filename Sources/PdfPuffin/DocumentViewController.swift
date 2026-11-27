import AppKit
import PDFKit

enum PageLayout: Int { case single = 1, two = 2, twoFirstSingle = 3 }

/// One open document: sidebar on the left, PDF view with page badge on the right.
final class DocumentViewController: NSViewController, NSSplitViewDelegate {
    let document: PDFDocument
    private(set) var fileURL: URL?
    var untitledName: String
    var isDirty = false { didSet { if oldValue != isDirty { main?.tabsChanged() } } }
    let editHistory = UndoManager()
    private var revision = UUID()
    private var savedRevision: UUID?

    weak var main: MainWindowController?

    private(set) var pdfView = PuffinPDFView()
    private let readingSplit = NSSplitView()
    var readingPanes: [PuffinPDFView] { readingSplit.arrangedSubviews.compactMap { $0 as? PuffinPDFView } }
    var splitDirection: Int { readingPanes.count == 2 ? (readingSplit.isVertical ? 2 : 1) : 0 }
    let sidebar = SidebarView()
    private let split = NSSplitView()
    private let pdfContainer = NSView()
    private let badge = PillButton()
    private let backPill = PillButton()
    /// Previous / pause / next / stop while reading aloud (Edit ▸ Speech, right-click).
    let readAloudBar = ReadAloudBar()
    private var backTarget: Int?

    /// True after a click in the thumbnail list: ↑/↓ then step one page, like
    /// moving through the list. A click in the page turns it off (↑/↓ scroll again).
    var thumbnailsActive = false { didSet { if thumbnailsActive { annotationsActive = false } } }
    /// After clicking an annotation in the sidebar list, ↑/↓ step through the list.
    var annotationsActive = false { didSet { if annotationsActive { thumbnailsActive = false } } }
    /// The text box being typed on the page, if any.
    var textEditor: InlineTextEditor?
    /// The floating note/comment card being edited, if any.
    var noteEditor: NoteCardEditor?
    /// The full-window page grid, while it is open.
    var grid: PageGridView?
    /// The floating selection markup bar, when text is selected.
    private(set) var selectionBar: SelectionBarView?
    private var selectionBarScrollObserver: NSObjectProtocol?

    /// The placed annotation selected for moving / resizing, if any.
    var selection: AnnotationSelection? {
        didSet {
            if oldValue !== selection {
                oldValue?.end()
                if selection != nil { hideSelectionBar() }
                main?.updateToolbar()
            }
        }
    }
    var layout: PageLayout = .single
    var continuous = true
    var bookmarks: [Int] = [] { didSet { saveBookmarks(); sidebar.bookmarks.reload() } }
    var markupTool: PDFAnnotationSubtype? {
        didSet {
            if markupTool != nil, shapeTool != nil { shapeTool = nil }
            if markupTool != nil { hideSelectionBar() }
            main?.updateToolbar()
        }
    }
    /// Armed shape tool: drag on the page to draw. Stays armed until Esc / the hand tool.
    var shapeTool: ShapeTool? {
        didSet {
            if shapeTool != nil, markupTool != nil { markupTool = nil }
            if shapeTool != nil { selection = nil; hideSelectionBar() }
            pdfView.window?.invalidateCursorRects(for: pdfView)
            main?.updateToolbar()
        }
    }

    private var printedOffset: Int?
    private var printedOffsetKey: String? { fileURL.map { "printedOffset:" + $0.path } }

    func setPrintedOffset(_ offset: Int?) {
        printedOffset = offset
        if let key = printedOffsetKey { UserDefaults.standard.set(offset, forKey: key) }
        pageChanged()
    }

    func printedLabel(at index: Int) -> String {
        if let offset = printedOffset { return String(index + 1 + offset) }
        return document.page(at: index)?.label ?? String(index + 1)
    }

    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? untitledName }
    var pageCount: Int { document.pageCount }
    var currentPageIndex: Int {
        guard let p = pdfView.currentPage else { return 0 }
        return document.index(for: p)
    }

    init(document: PDFDocument, url: URL?, name: String = "Untitled") {
        self.document = document
        self.fileURL = url
        self.untitledName = name
        super.init(nibName: nil, bundle: nil)
        savedRevision = url == nil ? nil : revision
        editHistory.groupsByEvent = false
        loadBookmarks()
        if let key = printedOffsetKey { printedOffset = UserDefaults.standard.object(forKey: key) as? Int }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        split.pinEdges(to: root)

        pdfView.owner = self
        pdfView.document = document
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = Theme.pageBG
        pdfView.pageShadowsEnabled = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        readingSplit.dividerStyle = .thin
        pdfContainer.addSubview(readingSplit)
        readingSplit.pinEdges(to: pdfContainer)
        readingSplit.addArrangedSubview(pdfView)

        badge.target = self; badge.action = #selector(badgeClicked)
        badge.toolTip = "Go to Page… (⌥⌘G)"
        backPill.target = self; backPill.action = #selector(backPillClicked)
        backPill.showsChevron = true
        backPill.isHidden = true
        for v in [badge, backPill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pdfContainer.addSubview(v)
        }
        pdfContainer.addSubview(readAloudBar)
        NSLayoutConstraint.activate([
            readAloudBar.centerXAnchor.constraint(equalTo: pdfContainer.centerXAnchor),
            readAloudBar.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor, constant: -14),
            badge.trailingAnchor.constraint(equalTo: pdfContainer.trailingAnchor, constant: -28),
            badge.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor, constant: -10),
            backPill.leadingAnchor.constraint(equalTo: pdfContainer.leadingAnchor, constant: 10),
            backPill.bottomAnchor.constraint(equalTo: pdfContainer.bottomAnchor, constant: -10),
        ])

        sidebar.doc = self
        sidebar.frame = NSRect(x: 0, y: 0, width: 232, height: 700)
        pdfContainer.frame = NSRect(x: 233, y: 0, width: 900, height: 700)
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pdfContainer)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        view = root

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        sidebar.reloadAll()
        pageChanged()
    }

    private var restored = false
    /// Called once the tab is on screen at its real size: reopen where you left
    /// off (like PDF Expert); new files start on page 1.
    func restoreInitialPageIfNeeded() {
        guard !restored else { return }
        restored = true
        let start = lastPageKey.map { UserDefaults.standard.integer(forKey: $0) } ?? 0
        guard let p = document.page(at: min(max(0, start), max(0, pageCount - 1))) else { return }
        if let k = zoomKey, let zoom = UserDefaults.standard.object(forKey: k) as? Double, zoom > 0 {
            setScale(CGFloat(zoom) * pdfView.actualSizeScale)
        }
        pdfView.go(to: p)
        // Auto-zoom settles on the next pass and can shift the view; jump again then.
        let initialPane = pdfView
        DispatchQueue.main.async { [weak self, weak initialPane] in
            guard let initialPane, initialPane === self?.pdfView, self?.splitDirection == 0 else { return }
            initialPane.layoutDocumentView()
            self?.pdfView.go(to: PDFDestination(page: p, at: NSPoint(x: 0, y: p.bounds(for: .cropBox).maxY)))
            self?.pageChanged()
        }
    }

    private var lastPageKey: String? { fileURL.map { "lastPage:" + $0.path } }
    private var zoomKey: String? { fileURL.map { "zoom:" + $0.path } }

    // MARK: split view

    /// 0 = single pane, 1 = horizontal divider, 2 = vertical divider.
    func setReadingSplit(_ direction: Int) {
        guard direction != splitDirection else { return }
        let locations = readingPanes.map { ($0, $0.currentPage, $0.currentDestination) }
        func restoreLocations() {
            readingSplit.layoutSubtreeIfNeeded()
            for pane in readingPanes {
                let saved = locations.first { $0.0 === pane } ?? locations.first
                pane.layoutDocumentView()
                if let destination = saved?.2 { pane.go(to: destination) }
                if let page = saved?.1, pane.currentPage !== page { pane.go(to: page) }
            }
        }
        if direction == 0 {
            for pane in readingPanes where pane !== pdfView {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: pane)
                NotificationCenter.default.removeObserver(self, name: .PDFViewScaleChanged, object: pane)
                pane.removeFromSuperview()
                pane.document = nil
            }
            restoreLocations()
            pdfView.layer?.borderWidth = 0
            return
        }
        readingSplit.isVertical = direction == 2
        if readingPanes.count == 1 {
            let other = PuffinPDFView(frame: readingSplit.bounds)
            other.owner = self
            other.displayMode = pdfView.displayMode
            other.displaysAsBook = pdfView.displaysAsBook
            other.displayBox = pdfView.displayBox
            other.displayDirection = pdfView.displayDirection
            other.backgroundColor = pdfView.backgroundColor
            other.pageBreakMargins = pdfView.pageBreakMargins
            other.document = document
            other.autoScales = pdfView.autoScales
            if !other.autoScales { other.scaleFactor = pdfView.scaleFactor }
            other.highlightedSelections = pdfView.highlightedSelections
            readingSplit.addArrangedSubview(other)
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: other)
            nc.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: other)
        }
        readingSplit.layoutSubtreeIfNeeded()
        let length = readingSplit.isVertical ? readingSplit.bounds.width : readingSplit.bounds.height
        readingSplit.setPosition((length - readingSplit.dividerThickness) / 2, ofDividerAt: 0)
        restoreLocations()
        indicateActivePane()
    }

    func activatePane(_ pane: PuffinPDFView) {
        guard pane !== pdfView, readingPanes.contains(pane) else { return }
        textEditor?.commit()          // both live on the old pane's view
        noteEditor?.commit()
        selection = nil
        pdfView = pane
        continuous = pane.displayMode.isContinuous
        layout = [.twoUp, .twoUpContinuous].contains(pane.displayMode) ? (pane.displaysAsBook ? .twoFirstSingle : .two) : .single
        backTarget = nil
        backPill.isHidden = true
        thumbnailsActive = false
        annotationsActive = false
        indicateActivePane()
        pageChanged()
    }

    private func indicateActivePane() {
        for pane in readingPanes {
            pane.wantsLayer = true
            pane.layer?.borderColor = NSColor.controlAccentColor.cgColor
            pane.layer?.borderWidth = pane === pdfView ? 1 : 0
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 170 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 460 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    var sidebarVisible: Bool {
        get { !sidebar.isHidden }
        set { sidebar.isHidden = !newValue; split.adjustSubviews(); main?.updateToolbar() }
    }

    func showSidebar(tab: SidebarTab) {
        sidebarVisible = true
        sidebar.select(tab)
    }

    // MARK: notifications

    @objc private func pageChanged() {
        hideSelectionBar()
        let i = currentPageIndex
        if restored, let k = lastPageKey { UserDefaults.standard.set(i, forKey: k) }
        badge.title = "\(i + 1) of \(pageCount)"
        let printed = printedLabel(at: i)
        if printed != String(i + 1) { badge.title += " · p. " + printed }
        sidebar.thumbnails.setCurrent(i)
        main?.updateToolbar()
    }

    @objc private func scaleChanged() {
        hideSelectionBar()
        // Remember this document's zoom (as shown: 1 = actual size); Automatic zoom stores nothing.
        if restored, let k = zoomKey {
            if pdfView.autoScales { UserDefaults.standard.removeObject(forKey: k) }
            else { UserDefaults.standard.set(Double(pdfView.displayZoom), forKey: k) }
        }
        main?.updateToolbar()
    }

    // MARK: navigation

    func previousPage() { if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) } }
    func nextPage() { if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) } }
    func firstPage() { pdfView.goToFirstPage(nil) }
    func lastPage() { pdfView.goToLastPage(nil) }

    /// A jump (thumbnail, outline, search, Go to Page). Shows "Back to p. N".
    func jump(toPage index: Int) {
        guard let page = document.page(at: index) else { return }
        noteJump(from: currentPageIndex, to: index)
        pdfView.go(to: page)
    }

    func jump(to destination: PDFDestination) {
        if let p = destination.page { noteJump(from: currentPageIndex, to: document.index(for: p)) }
        pdfView.go(to: destination)
    }

    func jump(to selection: PDFSelection) {
        if let p = selection.pages.first { noteJump(from: currentPageIndex, to: document.index(for: p)) }
        pdfView.go(to: selection)
    }

    private func noteJump(from: Int, to: Int) {
        guard abs(from - to) > 1 else { return }
        backTarget = from
        backPillIsForward = false
        backPill.showsChevron = true
        backPill.title = "Back to p. \(from + 1)"
        backPill.isHidden = false
    }

    @objc private func backPillClicked() {
        guard let t = backTarget, let page = document.page(at: t) else { return }
        let here = currentPageIndex
        pdfView.go(to: page)
        // The pill now offers the way back to where you were.
        backTarget = here
        backPillIsForward.toggle()
        backPill.title = (backPillIsForward ? "Forward to p. " : "Back to p. ") + "\(here + 1)"
        backPill.showsChevron = !backPillIsForward
    }
    private var backPillIsForward = false

    @objc private func badgeClicked() { main?.goToPageDialog(nil) }

    // MARK: layout & zoom

    func applyLayout() {
        let page = pdfView.currentPage
        switch (layout, continuous) {
        case (.single, true): pdfView.displayMode = .singlePageContinuous
        case (.single, false): pdfView.displayMode = .singlePage
        case (_, true): pdfView.displayMode = .twoUpContinuous
        case (_, false): pdfView.displayMode = .twoUp
        }
        pdfView.displaysAsBook = layout == .twoFirstSingle
        pdfView.autoScales = true
        if let page { pdfView.go(to: page) }
        main?.updateToolbar()
    }

    private var pageSize: NSSize {
        guard let p = pdfView.currentPage ?? document.page(at: 0) else { return NSSize(width: 612, height: 792) }
        let b = p.bounds(for: pdfView.displayBox)
        return (p.rotation % 180 == 0) ? b.size : NSSize(width: b.height, height: b.width)
    }

    private var visibleSize: NSSize {
        pdfView.documentView?.enclosingScrollView?.contentView.bounds.size ?? pdfView.bounds.size
    }

    func zoomFitWidth() {
        let cols: CGFloat = layout == .single ? 1 : 2
        let w = visibleSize.width - 40
        setScale(w / (pageSize.width * cols))
    }

    func zoomFitPage() {
        let cols: CGFloat = layout == .single ? 1 : 2
        let s = min((visibleSize.width - 40) / (pageSize.width * cols), (visibleSize.height - 24) / pageSize.height)
        setScale(s)
    }

    func setScale(_ s: CGFloat) {
        let page = pdfView.currentPage
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.1, min(s, 10))
        if let page, !pdfView.displayMode.isContinuous { pdfView.go(to: page) }
    }

    // MARK: bookmarks (stored per file path in UserDefaults)

    private var bookmarkKey: String? { fileURL.map { "bookmarks:" + $0.path } }
    private func loadBookmarks() {
        if let k = bookmarkKey { bookmarks = (UserDefaults.standard.array(forKey: k) as? [Int]) ?? [] }
    }
    private func saveBookmarks() {
        if let k = bookmarkKey { UserDefaults.standard.set(bookmarks, forKey: k) }
    }

    func toggleBookmark() {
        let i = currentPageIndex
        if let at = bookmarks.firstIndex(of: i) { bookmarks.remove(at: at) } else { bookmarks = (bookmarks + [i]).sorted() }
        main?.updateToolbar()
    }

    // MARK: annotations

    // A revision identifies document contents even across Save, Undo and Redo.
    private typealias Change = (DocumentViewController) -> Void

    private func edit(_ name: String, to next: UUID = UUID(),
                      apply: @escaping Change, reverse: @escaping Change) {
        let previous = revision
        editHistory.beginUndoGrouping()
        editHistory.registerUndo(withTarget: self) { doc in
            doc.edit(name, to: previous, apply: reverse, reverse: apply)
        }
        editHistory.setActionName(name)
        editHistory.endUndoGrouping()
        apply(self)
        revision = next
        isDirty = revision != savedRevision
    }

    func addAnnotations(_ annotations: [(PDFPage, PDFAnnotation)], name: String) {
        guard !annotations.isEmpty else { return }
        edit(name) { doc in
            for (page, annotation) in annotations { page.addAnnotation(annotation) }
            doc.annotationsChanged()
        } reverse: { doc in
            for (page, annotation) in annotations { page.removeAnnotation(annotation) }
            doc.annotationsChanged()
        }
    }

    func applyMarkup(_ type: PDFAnnotationSubtype, colorOverride: NSColor? = nil) {
        guard let sel = pdfView.currentSelection, let s = sel.string,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        var annotations: [(PDFPage, PDFAnnotation)] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5 else { continue }
                let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                let key = AnnotColors.key(for: type)
                let c = colorOverride ?? AnnotColors.color(for: key), o = AnnotColors.opacity(for: key)
                a.color = c.withAlphaComponent(type == .highlight ? 0.55 * o : o)
                a.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: b.width, y: 0)),
                ]
                a.contents = line.string ?? ""
                a.userName = NSFullUserName()
                a.modificationDate = Date()
                annotations.append((page, a))
            }
        }
        pdfView.clearSelection()
        let name = type == .highlight ? "Highlight" : (type == .underline ? "Underline" : "Strikeout")
        addAnnotations(annotations, name: name)
    }

    func showSelectionBar(for selection: PDFSelection) {
        guard let page = selection.pages.first,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hideSelectionBar()
            return
        }
        let bar = selectionBar ?? {
            let b = SelectionBarView()
            b.onHighlight = { [weak self] color in
                self?.applyMarkup(.highlight, colorOverride: color)
                self?.hideSelectionBar()
            }
            b.onUnderline = { [weak self] in
                self?.applyMarkup(.underline)
                self?.hideSelectionBar()
            }
            b.onStrikeout = { [weak self] in
                self?.applyMarkup(.strikeOut)
                self?.hideSelectionBar()
            }
            b.onNote = { [weak self] in
                guard let self else { return }
                let sel = self.pdfView.currentSelection
                self.hideSelectionBar()
                self.addNote(at: sel)
            }
            b.onCopy = { [weak self] in
                guard let self, let str = self.pdfView.currentSelection?.string, !str.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
                self.hideSelectionBar()
                self.main?.flash("Copied")
            }
            selectionBar = b
            return b
        }()

        if bar.superview !== pdfView {
            bar.removeFromSuperview()
            pdfView.addSubview(bar)
        }
        if selectionBarScrollObserver == nil,
           let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            selectionBarScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                self?.hideSelectionBar()
            }
        }

        // Some selections report a null or infinite rect for their page; converted,
        // that becomes NaN, and AppKit aborts on a NaN frame. No usable rect, no bar.
        let size = bar.fittingSize
        let pageRect = selection.bounds(for: page)
        let viewRect = pdfView.convert(pageRect, from: page)
        let bounds = pdfView.bounds.insetBy(dx: 8, dy: 8)
        guard pageRect.isUsableGeometry, viewRect.isUsableGeometry, bounds.isUsableGeometry,
              size.width.isFinite, size.height.isFinite else {
            hideSelectionBar()
            return
        }
        let x = min(max(viewRect.midX - size.width / 2, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        var y: CGFloat
        if pdfView.isFlipped {
            y = viewRect.minY - size.height - 8
            if y < bounds.minY { y = viewRect.maxY + 8 }
        } else {
            y = viewRect.maxY + 8
            if y + size.height > bounds.maxY { y = viewRect.minY - size.height - 8 }
        }
        y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        guard x.isFinite, y.isFinite else { hideSelectionBar(); return }
        bar.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        bar.isHidden = false
    }

    func hideSelectionBar() {
        if let obs = selectionBarScrollObserver {
            NotificationCenter.default.removeObserver(obs)
            selectionBarScrollObserver = nil
        }
        selectionBar?.removeFromSuperview()
        selectionBar = nil
    }

    func selectionBarContains(windowPoint p: NSPoint) -> Bool {
        guard let bar = selectionBar, !bar.isHidden, bar.superview != nil else { return false }
        return bar.bounds.contains(bar.convert(p, from: nil))
    }

    func openNoteCard(for annotation: PDFAnnotation, on page: PDFPage, isNew: Bool) {
        textEditor?.commit()
        noteEditor?.commit()
        selection = nil
        hideSelectionBar()
        let ed = NoteCardEditor(doc: self, page: page, annotation: annotation, isNew: isNew)
        noteEditor = ed
        ed.start()
    }

    func addNote(at selection: PDFSelection? = nil) {
        guard let page = selection?.pages.first ?? pdfView.currentPage else { return }
        let pb = page.bounds(for: pdfView.displayBox)
        let x: CGFloat
        let y: CGFloat
        if let selection {
            let sb = selection.bounds(for: page)
            x = max(pb.minX + 12, min(sb.maxX + 6, pb.maxX - 36))
            y = min(pb.maxY - 36, max(sb.maxY - 24, pb.minY + 12))
        } else {
            let visible = pdfView.convert(pdfView.bounds, to: page)
            x = max(pb.minX + 12, min(visible.minX + 24, pb.maxX - 36))
            y = min(pb.maxY - 36, max(visible.maxY - 48, pb.minY + 12))
        }
        let a = PDFAnnotation(bounds: NSRect(x: x, y: y, width: 24, height: 24), forType: .text, withProperties: nil)
        a.color = AnnotColors.color(for: "note")
        a.iconType = .comment
        a.userName = NSFullUserName()
        a.modificationDate = Date()
        page.addAnnotation(a)
        pdfView.repaint(page)
        openNoteCard(for: a, on: page, isNew: true)
    }

    func removeAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        edit("Delete Annotation") { doc in
            page.removeAnnotation(annotation)
            doc.annotationsChanged()
        } reverse: { doc in
            page.addAnnotation(annotation)
            doc.annotationsChanged()
        }
    }

    // Page tools (shapes, pen, text, signatures, move/resize) change the page while
    // you drag or type, then record the finished change here so Undo / Redo work.

    /// An annotation the user has just put on `page`.
    func recordAdded(_ a: PDFAnnotation, on page: PDFPage, name: String) {
        edit(name) { doc in
            if !page.annotations.contains(where: { $0 === a }) { page.addAnnotation(a) }
            doc.pdfView.refresh(a, on: page)
            doc.annotationsChanged()
        } reverse: { doc in
            page.removeAnnotation(a)
            doc.pdfView.repaint(page)
            doc.annotationsChanged()
        }
    }

    /// An annotation whose bounds / text / style changed from `old` to `new`.
    func recordChanged(_ a: PDFAnnotation, on page: PDFPage, name: String, from old: AnnotSnapshot, to new: AnnotSnapshot) {
        edit(name) { doc in
            new.apply(to: a)
            if !page.annotations.contains(where: { $0 === a }) { page.addAnnotation(a) }
            doc.pdfView.refresh(a, on: page)
            doc.selection?.layout()
            doc.annotationsChanged()
        } reverse: { doc in
            old.apply(to: a)
            if !page.annotations.contains(where: { $0 === a }) { page.addAnnotation(a) }
            doc.pdfView.refresh(a, on: page)
            doc.selection?.layout()
            doc.annotationsChanged()
        }
    }

    /// An annotation already taken off `page` (e.g. a text box emptied while editing);
    /// Undo puts it back as it was (`old`).
    func recordRemoved(_ a: PDFAnnotation, from page: PDFPage, name: String, restoring old: AnnotSnapshot) {
        edit(name) { doc in
            page.removeAnnotation(a)
            doc.pdfView.repaint(page)
            doc.annotationsChanged()
        } reverse: { doc in
            old.apply(to: a)
            page.addAnnotation(a)
            doc.pdfView.refresh(a, on: page)
            doc.annotationsChanged()
        }
    }

    private func annotationsChanged() {
        for pane in readingPanes { pane.needsDisplay = true }
        sidebar.annotations.reload()
        sidebar.thumbnails.reloadImages()
    }

    // MARK: pages

    func copies(of indices: IndexSet) -> [PDFPage] {
        indices.compactMap { document.page(at: $0)?.copy() as? PDFPage }
    }

    func excerptName(for pages: IndexSet, printed: Bool = false) -> String {
        guard printed else { return "\(displayName) (pages \(ThumbnailsPane.describe(pages)))" }
        let ranges = pages.rangeView.map { range -> String in
            let first = printedLabel(at: range.lowerBound)
            return range.count == 1 ? first : first + "–" + printedLabel(at: range.upperBound - 1)
        }
        let description = ranges.joined(separator: ", ").replacingOccurrences(of: "/", with: "-")
        return "\(displayName) (pages \(description))"
    }

    func copySelectedPagesToPasteboard() {
        let sel = sidebar.thumbnails.selectedPages
        guard writeExcerpt(sel, to: .general) else { NSSound.beep(); return }
        main?.flash("Copied \(sel.count) page\(sel.count == 1 ? "" : "s") (\(ThumbnailsPane.describe(sel)))")
    }

    func writeExcerpt(_ sel: IndexSet, to pb: NSPasteboard) -> Bool {
        let out = PDFDocument()
        for p in copies(of: sel) { out.insert(p, at: out.pageCount) }
        guard !sel.isEmpty, out.pageCount == sel.count, let data = out.dataRepresentation() else { return false }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .pdf),
              item.setString(excerptName(for: sel), forType: Clipboard.excerptName) else { return false }
        pb.clearContents()
        return pb.writeObjects([item])
    }

    func append(pages: [PDFPage]) {
        guard !pages.isEmpty else { return }
        let start = document.pageCount
        edit("Append Pages") { doc in
            for page in pages { doc.document.insert(page, at: doc.document.pageCount) }
            doc.refreshPageList()
        } reverse: { doc in
            for index in (start..<(start + pages.count)).reversed() { doc.document.removePage(at: index) }
            doc.refreshPageList()
        }
    }

    // Keep the original PDFPage objects so annotations and prior undo actions
    // continue to address the same pages after a move or restoration.
    @discardableResult
    func changePages(_ indices: IndexSet, before destination: Int?) -> Bool {
        guard !indices.isEmpty, let last = indices.last, last < pageCount,
              indices.count < pageCount else { return false }
        let moved = indices.compactMap { document.page(at: $0) }
        guard moved.count == indices.count else { return false }
        let target: IndexSet
        if let destination {
            guard (0...pageCount).contains(destination) else { return false }
            let start = destination - indices.count(in: 0..<destination)
            target = IndexSet(integersIn: start..<(start + moved.count))
            if target == indices { return false }
        } else { target = [] }
        let removedBookmarks = indices.filter { bookmarks.contains($0) }
        edit(destination == nil ? "Remove Pages" : "Move Pages") { doc in
            doc.place(moved, from: indices, at: target, restoring: [])
        } reverse: { doc in
            doc.place(moved, from: target, at: indices, restoring: target.isEmpty ? removedBookmarks : [])
        }
        return true
    }

    /// Swaps in rebuilt pages (Recognize Text) at their indices, keeping each page's
    /// rotation, crop and annotations. Undoable.
    func replacePages(_ replacements: [Int: PDFPage], name: String) {
        let pairs: [(Int, PDFPage, PDFPage)] = replacements.keys.sorted().compactMap { i in
            guard let old = document.page(at: i), let new = replacements[i] else { return nil }
            new.rotation = old.rotation
            let crop = old.bounds(for: .cropBox)
            if crop != old.bounds(for: .mediaBox) { new.setBounds(crop, for: .cropBox) }
            return (i, old, new)
        }
        guard !pairs.isEmpty else { return }
        func swap(_ doc: DocumentViewController, toNew: Bool) {
            let current = doc.currentPageIndex
            for (i, old, new) in pairs {
                let (from, to) = toNew ? (old, new) : (new, old)
                let moving = from.annotations
                doc.document.removePage(at: i)
                doc.document.insert(to, at: i)
                for a in moving { from.removeAnnotation(a); to.addAnnotation(a) }
            }
            if let page = doc.document.page(at: current) { doc.pdfView.go(to: page) }
            for pane in doc.readingPanes { pane.layoutDocumentView() }
            doc.refreshPageList()
            doc.sidebar.thumbnails.reloadImages()
        }
        edit(name) { swap($0, toNew: true) } reverse: { swap($0, toNew: false) }
    }

    private func place(_ pages: [PDFPage], from old: IndexSet, at new: IndexSet, restoring: [Int]) {
        let marked = bookmarks.compactMap { document.page(at: $0) }
        let current = pdfView.currentPage
        let fallback = currentPageIndex
        for i in old.reversed() { document.removePage(at: i) }
        for (i, page) in zip(new, pages) { document.insert(page, at: i) }
        let remapped = marked.compactMap { page -> Int? in
            let i = document.index(for: page)
            return (0..<pageCount).contains(i) ? i : nil
        }
        bookmarks = Array(Set(remapped + restoring)).sorted()
        let index = current.map { document.index(for: $0) } ?? NSNotFound
        let next = (0..<pageCount).contains(index) ? index : min(fallback, pageCount - 1)
        backTarget = nil
        backPill.isHidden = true
        if let page = document.page(at: next) { pdfView.go(to: page) }
        refreshPageList()
        if !new.isEmpty { sidebar.thumbnails.table.selectRowIndexes(new, byExtendingSelection: false) }
    }

    private func refreshPageList() {
        grid?.reload()
        for pane in readingPanes { pane.layoutDocumentView() }
        sidebar.reloadAll()
        pageChanged()
        main?.rerunSearch(keepPosition: true)
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        let original = page.rotation
        func rotate(_ doc: DocumentViewController, to angle: Int) {
            page.rotation = angle
            for pane in doc.readingPanes { pane.layoutDocumentView() }
            doc.sidebar.thumbnails.reloadImages()
        }
        edit("Rotate Page") { rotate($0, to: (original + degrees + 360) % 360) }
            reverse: { rotate($0, to: original) }
    }

    // MARK: saving

    /// True if two URLs name the same file on disk (resolving aliases/symlinks).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let ra = a.resolvingSymlinksInPath().standardizedFileURL, rb = b.resolvingSymlinksInPath().standardizedFileURL
        if ra == rb { return true }
        let ia = try? ra.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let ib = try? rb.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let ia, let ib { return ia.isEqual(ib) }
        return false
    }

    /// Saves to the file, or asks for a location. Returns true on success.
    @discardableResult
    func save(forceAsk: Bool) -> Bool {
        textEditor?.commit()
        noteEditor?.commit()
        var target = fileURL
        while forceAsk || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = displayName + ".pdf"
            if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            // Refuse a file that another open tab (in any window) is showing (same file, even via an alias).
            let allDocs = AppDelegate.shared?.windows.flatMap(\.documentControllers) ?? main?.documentControllers ?? []
            if let other = allDocs.first(where: { $0 !== self && $0.fileURL.map { Self.sameFile($0, u) } == true }) {
                let a = NSAlert()
                a.messageText = "“\(u.lastPathComponent)” is open in another tab."
                a.informativeText = "Saving here would overwrite “\(other.displayName)”. Choose a different name or location."
                a.addButton(withTitle: "Choose Another…")
                a.addButton(withTitle: "Cancel")
                if a.runModal() != .alertFirstButtonReturn { return false }
                continue
            }
            target = u
            break
        }
        guard let url = target else { return false }
        // Write beside the real file and swap it in. A symlinked path is resolved
        // first: replaceItemAt fails on a symlink, and replacing the link itself
        // would leave the file it points to unsaved.
        let disk = url.resolvingSymlinksInPath()
        let dir = disk.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".\(disk.lastPathComponent).puffin-tmp-\(UUID().uuidString)")
        let fm = FileManager.default
        if document.write(to: tempURL) {
            let replaced: Bool
            do {
                if fm.fileExists(atPath: disk.path) {
                    _ = try fm.replaceItemAt(disk, withItemAt: tempURL, backupItemName: nil, options: [])
                } else {
                    try fm.moveItem(at: tempURL, to: disk)
                }
                replaced = true
            } catch {
                try? fm.removeItem(at: tempURL)
                replaced = false
            }
            if replaced {
                let oldKey = bookmarkKey
                fileURL = url
                if let key = printedOffsetKey { UserDefaults.standard.set(printedOffset, forKey: key) }
                if oldKey == nil || oldKey != bookmarkKey { saveBookmarks() }
                savedRevision = revision
                isDirty = false
                main?.noteRecent(url)
                main?.tabsChanged()
                return true
            }
        } else {
            try? fm.removeItem(at: tempURL)
        }
        let a = NSAlert()
        a.messageText = "Could not save “\(url.lastPathComponent)”."
        a.informativeText = "PDFKit refused to write the file. Try Save As… to another folder."
        a.runModal()
        return false
    }
}

/// The dark rounded "1 of 90" badge and "‹ Back to p. 17" pill.
final class PillButton: NSControl {
    var title = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var showsChevron = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let pillFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: pillFont]).width
        return NSSize(width: ceil(w) + 40 + (showsChevron ? 22 : 0), height: 34)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        Theme.pill.setFill(); path.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attrs)
        var x = (bounds.width - size.width) / 2
        if showsChevron {
            x += 10
            let img = Theme.symbol("chevron.left", 12, weight: .semibold)
            let tinted = img.tinted(.white)
            tinted.draw(in: NSRect(x: 16, y: (bounds.height - 13) / 2, width: 8, height: 13))
        }
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) {
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.isTemplate = false
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}


// MARK: - Page grid (View ▸ Thumbnails, ⌘4)

extension DocumentViewController {
    var gridMode: Bool { grid != nil }

    /// Shows or hides PDF Expert's full-window page grid over this tab.
    func setGrid(_ on: Bool) {
        guard on != gridMode else { return }
        if on {
            textEditor?.commit()
            noteEditor?.commit()
            selection = nil
            hideSelectionBar()
            shapeTool = nil
            markupTool = nil
            let g = PageGridView(doc: self)
            view.addSubview(g)
            g.pinEdges(to: view)
            grid = g
            view.layoutSubtreeIfNeeded()
            g.scrollToCurrent()
        } else {
            let page = grid?.current ?? currentPageIndex
            grid?.removeFromSuperview()
            grid = nil
            if let p = document.page(at: page), p !== pdfView.currentPage { pdfView.go(to: p) }
            main?.focusPDF()
        }
        main?.gridModeChanged()
    }

    func openPageFromGrid(_ i: Int) {
        setGrid(false)
        jump(toPage: i)
    }

    /// Inserts pages at `index` (undoable). The pages become the grid selection.
    func insertPages(_ pages: [PDFPage], at index: Int, name: String) {
        guard !pages.isEmpty else { return }
        let at = min(max(0, index), pageCount)
        // Bookmarks are page indices: keep each on its page as pages shift.
        func remapBookmarks(_ doc: DocumentViewController, _ change: () -> Void) {
            let marked = doc.bookmarks.compactMap { doc.document.page(at: $0) }
            change()
            doc.bookmarks = marked.map { doc.document.index(for: $0) }.filter { $0 != NSNotFound && $0 < doc.pageCount }.sorted()
        }
        edit(name) { doc in
            remapBookmarks(doc) { for (k, p) in pages.enumerated() { doc.document.insert(p, at: at + k) } }
            doc.refreshPageList()
            doc.grid?.selection = IndexSet(integersIn: at..<(at + pages.count))
            doc.grid?.current = at
        } reverse: { doc in
            remapBookmarks(doc) {
                for p in pages.reversed() {
                    let i = doc.document.index(for: p)
                    if i != NSNotFound, i < doc.pageCount { doc.document.removePage(at: i) }
                }
            }
            doc.refreshPageList()
        }
    }

    func cropPages(_ indices: IndexSet, keeping rect: CGRect) {
        guard rect.width > 0, rect.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect) else { return }
        let pages = indices.filter { $0 < pageCount }.compactMap { document.page(at: $0) }
        let original = pages.map { $0.bounds(for: .cropBox) }
        let cropped = pages.map { PageCrop.bounds(on: $0, keeping: rect) }
        guard cropped != original else { return }
        func apply(_ doc: DocumentViewController, _ boxes: [CGRect]) {
            for (page, box) in zip(pages, boxes) { page.setBounds(box, for: .cropBox) }
            for pane in doc.readingPanes { pane.layoutDocumentView() }
            doc.selection?.layout()
            doc.sidebar.thumbnails.reloadImages()
            doc.grid?.reload()
        }
        edit("Crop Pages") { apply($0, cropped) } reverse: { apply($0, original) }
    }

    /// Rotates the given pages (undoable).
    func rotatePages(_ indices: IndexSet, by degrees: Int) {
        let pages = indices.compactMap { document.page(at: $0) }
        guard !pages.isEmpty else { return }
        let original = pages.map(\.rotation)
        func apply(_ doc: DocumentViewController, _ angles: [Int]) {
            for (p, a) in zip(pages, angles) { p.rotation = a }
            for pane in doc.readingPanes { pane.layoutDocumentView() }
            doc.sidebar.thumbnails.reloadImages()
            doc.grid?.reload()
        }
        let rotated = original.map { ($0 + degrees + 360) % 360 }
        edit(pages.count == 1 ? "Rotate Page" : "Rotate Pages") { apply($0, rotated) } reverse: { apply($0, original) }
    }

    /// A blank page the size of the page it follows.
    func blankPage(like index: Int) -> PDFPage {
        let ref = document.page(at: min(max(0, index), max(0, pageCount - 1)))
        let box = ref?.bounds(for: .mediaBox) ?? NSRect(x: 0, y: 0, width: 612, height: 792)
        let img = NSImage(size: box.size, flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
        let page = PDFPage(image: img) ?? PDFPage()
        page.setBounds(box, for: .mediaBox)
        page.rotation = ref?.rotation ?? 0
        return page
    }
}

// MARK: - whole-document annotation commands (Edit ▸ Clear Form, Remove All Annotations)

extension DocumentViewController {
    /// Form widgets with something filled in.
    private var filledWidgets: [(PDFPage, PDFAnnotation, String?, PDFWidgetCellState)] {
        var out: [(PDFPage, PDFAnnotation, String?, PDFWidgetCellState)] = []
        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where a.type == "Widget" {
                let text = a.widgetStringValue
                let state = a.buttonWidgetState
                let filled = a.widgetFieldType == .button ? state == .onState : !(text ?? "").isEmpty
                if filled { out.append((page, a, text, state)) }
            }
        }
        return out
    }

    var hasFilledForm: Bool { !filledWidgets.isEmpty }

    /// Empties every text field and unticks every checkbox / radio button. Undoable.
    func clearForm() {
        let widgets = filledWidgets
        guard !widgets.isEmpty else { NSSound.beep(); return }
        edit("Clear Form") { doc in
            for (_, a, _, _) in widgets {
                if a.widgetFieldType == .button { a.buttonWidgetState = .offState } else { a.widgetStringValue = "" }
            }
            doc.annotationsChanged()
        } reverse: { doc in
            for (_, a, text, state) in widgets {
                if a.widgetFieldType == .button { a.buttonWidgetState = state } else { a.widgetStringValue = text ?? "" }
            }
            doc.annotationsChanged()
        }
        for (page, _, _, _) in widgets { pdfView.repaint(page) }
    }

    /// Markup, notes, drawings, stamps and signatures (links and form fields stay).
    var userAnnotations: [(PDFPage, PDFAnnotation)] {
        var out: [(PDFPage, PDFAnnotation)] = []
        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where AnnotationsPane.kinds.contains(a.type ?? "") || a.type == "Popup" {
                out.append((page, a))
            }
        }
        return out
    }

    /// Removes every user annotation in one undoable step; returns how many went.
    @discardableResult
    func removeAllAnnotations() -> Int {
        textEditor?.commit()
        noteEditor?.commit()
        selection = nil
        let all = userAnnotations
        guard !all.isEmpty else { return 0 }
        edit("Remove All Annotations") { doc in
            for (page, a) in all { page.removeAnnotation(a) }
            doc.annotationsChanged()
        } reverse: { doc in
            for (page, a) in all { page.addAnnotation(a) }
            doc.annotationsChanged()
        }
        return all.filter { $0.1.type != "Popup" }.count
    }

    /// Edit ▸ Insert Blank Page: a blank page the size of the current one, after it.
    func insertBlankPageAfterCurrent() {
        let i = currentPageIndex
        insertPages([blankPage(like: i)], at: i + 1, name: "Insert Blank Page")
        jump(toPage: i + 1)
    }
}

extension DocumentViewController {
    /// Removes the given annotations in one undoable step.
    func removeAnnotations(_ items: [(PDFPage, PDFAnnotation)], name: String) {
        guard !items.isEmpty else { return }
        textEditor?.commit()
        selection = nil
        edit(name) { doc in
            for (page, a) in items { page.removeAnnotation(a) }
            doc.annotationsChanged()
        } reverse: { doc in
            for (page, a) in items { page.addAnnotation(a) }
            doc.annotationsChanged()
        }
    }
}

extension NSRect {
    /// Not null, not infinite, and every coordinate finite (safe to use for a view frame).
    var isUsableGeometry: Bool {
        !isNull && !isInfinite
            && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
