import AppKit
import PDFKit
import UniformTypeIdentifiers

final class DocTab {
    var controller: DocumentViewController?
    var home: HomeView?
    var isHome: Bool { controller == nil }
    init(controller: DocumentViewController?) { self.controller = controller }
}

/// The single PdfPuffin window: tab bar, toolbar, tool row, content and search panel.
///
/// Focus rule (the PdfCraft bug): after any click in the window that does not land
/// in a text field, keyboard focus goes back to the PDF view, and the paging keys
/// (← → ↑ ↓ Space Page Up/Down Home End) are routed to the PDF view from a key
/// monitor whenever no text field is being edited.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) var tabs: [DocTab] = []
    private(set) var selected = -1
    let tabBar = TabBarView()
    let toolbar = ToolbarView()
    let toolRow = ToolRowView()
    let convertRow = ConvertRowView()
    let fillRow = FillSignRowView()
    let pageToolsRow = PageToolsRow()
    let content = NSView()
    let searchPanel = SearchPanel()
    private var toolRowHeight: NSLayoutConstraint!
    private var searchWidth: NSLayoutConstraint!
    let inspector = ToolInspector()
    private var inspectorWidth: NSLayoutConstraint!
    private var monitors: [Any] = []
    private var movingSelection = false
    private var toastView: NSTextField?
    private var searchDebounce: DispatchWorkItem?
    var toolsShown = UserDefaults.standard.object(forKey: "toolsShown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(toolsShown, forKey: "toolsShown"); layoutChrome() }
    }
    /// Convert mode swaps the annotate row for the export row (PDF Expert's mode tabs).
    var altRow: AltRow? {
        didSet {
            // A tool from a row that is now hidden must not keep acting on clicks
            // (an armed Eraser in Convert mode erased what you clicked).
            if altRow != oldValue, let d = current { putDownHiddenTools(d) }
            layoutChrome()
        }
    }

    /// Tools each row offers; any other armed tool is put down when the row changes.
    private func putDownHiddenTools(_ d: DocumentViewController) {
        let fillTools: Set<ShapeTool> = [.text, .signature, .date, .check, .cross, .stamp]
        let keep: Bool
        switch altRow {
        case .convert?: keep = false
        case .fillSign?: keep = d.markupTool == nil && (d.shapeTool.map { fillTools.contains($0) } ?? true)
        case nil: keep = !(d.shapeTool?.isClickPlaced ?? false)
        }
        if !keep {
            d.textEditor?.commit()
            d.markupTool = nil
            d.shapeTool = nil
        }
    }

    var current: DocumentViewController? { tabs.indices.contains(selected) ? tabs[selected].controller : nil }
    var documentControllers: [DocumentViewController] { tabs.compactMap(\.controller) }

    init(initialHome: Bool = true) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "PdfPuffin"
        w.minSize = NSSize(width: 760, height: 480)
        w.isReleasedWhenClosed = false
        if AppDelegate.shared?.windows.isEmpty ?? true {
            w.setFrameAutosaveName("PdfPuffinMain")
        }
        super.init(window: w)
        w.delegate = self
        buildLayout()
        installMonitors()
        if initialHome { newHomeTab(nil) }
        if w.frame.origin == .zero { w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let root = window?.contentView else { return }
        tabBar.main = self
        toolbar.main = self
        toolRow.main = self
        searchPanel.main = self
        inspector.main = self
        for v in [tabBar, toolbar, toolRow, convertRow, fillRow, pageToolsRow, content, inspector, searchPanel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        toolRowHeight = toolRow.heightAnchor.constraint(equalToConstant: 44)
        searchWidth = searchPanel.widthAnchor.constraint(equalToConstant: 0)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 38),
            toolbar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            toolRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolRowHeight,
            convertRow.topAnchor.constraint(equalTo: toolRow.topAnchor),
            convertRow.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
            convertRow.trailingAnchor.constraint(equalTo: toolRow.trailingAnchor),
            convertRow.bottomAnchor.constraint(equalTo: toolRow.bottomAnchor),
            fillRow.topAnchor.constraint(equalTo: toolRow.topAnchor),
            fillRow.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
            fillRow.trailingAnchor.constraint(equalTo: toolRow.trailingAnchor),
            fillRow.bottomAnchor.constraint(equalTo: toolRow.bottomAnchor),
            pageToolsRow.topAnchor.constraint(equalTo: toolRow.topAnchor),
            pageToolsRow.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
            pageToolsRow.trailingAnchor.constraint(equalTo: toolRow.trailingAnchor),
            pageToolsRow.bottomAnchor.constraint(equalTo: toolRow.bottomAnchor),
            content.topAnchor.constraint(equalTo: toolRow.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.topAnchor.constraint(equalTo: toolRow.bottomAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: searchPanel.leadingAnchor),
            inspectorWidth,
            searchPanel.topAnchor.constraint(equalTo: toolRow.bottomAnchor),
            searchPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchPanel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            searchWidth,
        ])
        searchPanel.isHidden = true
        inspector.isHidden = true
        layoutChrome()
    }

    private func layoutChrome() {
        let grid = current?.gridMode == true
        let alt = grid || current == nil ? nil : altRow
        let showTools = (toolsShown || grid || alt != nil) && current != nil
        toolRow.isHidden = !showTools || grid || alt != nil
        convertRow.isHidden = alt != .convert
        fillRow.isHidden = alt != .fillSign
        pageToolsRow.isHidden = !grid              // PDF Expert swaps in the page tools
        toolRowHeight.constant = showTools ? 44 : 0
        updateToolbar()
    }

    // MARK: focus guard

    private func installMonitors() {
        let up = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] e in
            if e.window === self?.window, let self {
                // Where did the click land? A click in the page ends thumbnail mode.
                if let d = self.current, let root = self.window?.contentView?.superview,
                   let hit = root.hitTest(root.convert(e.locationInWindow, from: nil)) {
                    if let pane = d.readingPanes.first(where: { hit === $0 || hit.isDescendant(of: $0) }) {
                        d.activatePane(pane)
                        d.thumbnailsActive = false
                    }
                    else if !hit.isDescendant(of: d.sidebar.thumbnails) { d.thumbnailsActive = false }
                }
                DispatchQueue.main.async { self.afterClick() }
            }
            return e
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return self.handleKeyDown(e) ? nil : e
        }
        // Shape tools: PDFKit's inner view eats drags, so draw from the window level.
        let shapes = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self, e.window === self.window, let d = self.current, !d.gridMode else { return e }
            // Split view: a press in the other pane makes it the active one first,
            // so tools and selection act where you clicked.
            if e.type == .leftMouseDown, d.readingPanes.count > 1,
               let pane = d.readingPanes.first(where: { $0.bounds.contains($0.convert(e.locationInWindow, from: nil)) }),
               pane !== d.pdfView {
                d.activatePane(pane)
            }
            let pdf = d.pdfView
            // Typing on the page: a click outside the box (or its style bar) finishes it.
            if let ed = d.textEditor {
                guard e.type == .leftMouseDown else { return e }
                if ed.contains(windowPoint: e.locationInWindow) { return e }
                ed.commit()
                let p = pdf.convert(e.locationInWindow, from: nil)
                return pdf.bounds.contains(p) ? nil : e      // a click on the page only ends typing
            }
            // Floating note/comment card: a click outside commits it.
            if let ne = d.noteEditor {
                guard e.type == .leftMouseDown else { return e }
                if ne.contains(windowPoint: e.locationInWindow) { return e }
                ne.commit()
                let p = pdf.convert(e.locationInWindow, from: nil)
                return pdf.bounds.contains(p) ? nil : e
            }
            // Double-click a text box, sticky note, or markup annotation to edit it.
            if e.type == .leftMouseDown, e.clickCount == 2 {
                let p = pdf.convert(e.locationInWindow, from: nil)
                if pdf.bounds.contains(p), let page = pdf.page(for: p, nearest: false),
                   let a = AnnotationSelection.hit(page, pdf.convert(p, to: page)) {
                    if a.type == "FreeText" {
                        DispatchQueue.main.async { d.editText(a, on: page, at: .zero) }
                        return nil
                    }
                    if ["Text", "Highlight", "Underline", "StrikeOut"].contains(a.type ?? "") {
                        DispatchQueue.main.async { d.openNoteCard(for: a, on: page, isNew: false) }
                        return nil
                    }
                }
            }
            // Hand tool: select, move and resize placed annotations (signatures, shapes…).
            if d.shapeTool == nil, d.markupTool == nil {
                if d.selectionBarContains(windowPoint: e.locationInWindow) { return e }
                switch e.type {
                case .leftMouseDown:
                    if let sel = d.selection, sel.begin(at: e.locationInWindow) { self.movingSelection = true; return nil }
                    let p = pdf.convert(e.locationInWindow, from: nil)
                    if pdf.bounds.contains(p), let page = pdf.page(for: p, nearest: false),
                       let a = AnnotationSelection.hit(page, pdf.convert(p, to: page)) {
                        d.selection = AnnotationSelection(doc: d, page: page, annotation: a)
                        self.movingSelection = d.selection?.begin(at: e.locationInWindow) ?? false
                        self.window?.makeFirstResponder(pdf)
                        return self.movingSelection ? nil : e
                    }
                    d.selection = nil
                    return e
                case .leftMouseDragged:
                    guard self.movingSelection, let sel = d.selection else { return e }
                    sel.dragged(to: e.locationInWindow, shift: e.modifierFlags.contains(.shift))
                    return nil
                default:
                    guard self.movingSelection else { return e }
                    self.movingSelection = false
                    d.selection?.finish()
                    return nil
                }
            }
            guard d.shapeTool != nil else { return e }
            switch e.type {
            case .leftMouseDown:
                let p = pdf.convert(e.locationInWindow, from: nil)
                let scroller = pdf.documentView?.enclosingScrollView?.verticalScroller
                let onScroller = scroller.map { !$0.isHidden && $0.convert($0.bounds, to: pdf).contains(p) } ?? false
                guard pdf.bounds.contains(p), !onScroller, pdf.page(for: p, nearest: false) != nil else { return e }
                self.window?.makeFirstResponder(pdf)
                return pdf.shapeMouse(e, phase: 0) ? nil : e
            case .leftMouseDragged:
                let active = pdf.drawing != nil || pdf.signatureStart != nil || pdf.eraserPage != nil
                return active && pdf.shapeMouse(e, phase: 1) ? nil : e
            default:
                let active = pdf.drawing != nil || pdf.signatureStart != nil || pdf.eraserPage != nil
                return active && pdf.shapeMouse(e, phase: 2) ? nil : e
            }
        }
        monitors = [up as Any, key as Any, shapes as Any]
    }

    /// True if a text field / text view is being edited (its keys must not be stolen).
    private var isEditingText: Bool {
        guard let fr = window?.firstResponder else { return false }
        if let tv = fr as? NSTextView { return tv.isEditable || tv.isFieldEditor }
        return fr is NSTextField
    }

    private func afterClick() {
        if let d = current {
            let sel = d.pdfView.currentSelection
            let hasText = !(sel?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let t = d.markupTool, hasText {
                d.applyMarkup(t)
                d.hideSelectionBar()
            } else if d.markupTool == nil, d.shapeTool == nil, d.textEditor == nil, let sel, hasText {
                d.selection = nil
                d.showSelectionBar(for: sel)
            } else {
                d.hideSelectionBar()
            }
        }
        focusPDF()
    }

    /// Puts keyboard focus back on the PDF unless the user is typing in a text field.
    func focusPDF() {
        guard let w = window, let pdf = current?.pdfView, !isEditingText else { return }
        if let v = w.firstResponder as? NSView, v === pdf || v.isDescendant(of: pdf) { return }
        w.makeFirstResponder(pdf)
    }

    private func handleKeyDown(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        // ⌃Tab / ⌃⇧Tab switch tabs, everywhere.
        if e.keyCode == 48, m == .control { nextTab(nil); return true }
        if e.keyCode == 48, m == [.control, .shift] { previousTab(nil); return true }
        // ⌘= also zooms in (PDF Expert shows ⌘+).
        if m == .command, e.charactersIgnoringModifiers == "=" { zoomInAction(nil); return true }
        if isEditingText { return false }
        // Page grid: arrows move through the grid, Return opens, Delete removes, Esc leaves.
        if let g = current?.grid {
            if e.keyCode == 53, m.isEmpty { current?.setGrid(false); return true }
            if m == .command, e.keyCode == 8 { gridCopy(nil); return true }      // ⌘C
            if m == .command, e.keyCode == 9 { gridPaste(nil); return true }     // ⌘V
            return g.handleKey(e)
        }
        guard let pdf = current?.pdfView else { return false }
        // A selected annotation: Delete removes it, Esc deselects.
        if let sel = current?.selection, m.isEmpty, [51, 117, 53].contains(e.keyCode) {
            if e.keyCode != 53 { sel.delete() }
            current?.selection = nil
            return true
        }
        if e.keyCode == 53, m.isEmpty, current?.shapeTool != nil || current?.markupTool != nil {
            current?.shapeTool = nil; current?.markupTool = nil   // Esc puts the tools down
            return true
        }
        if e.keyCode == 53, m.isEmpty, current?.selectionBar != nil {
            current?.hideSelectionBar()
            current?.pdfView.clearSelection()
            return true
        }
        // After clicking a thumbnail, ↑/↓ step one page (like moving through the list).
        if current?.thumbnailsActive == true, m.isEmpty, e.keyCode == 126 || e.keyCode == 125 {
            if e.keyCode == 126 { current?.previousPage() } else { current?.nextPage() }
            window?.makeFirstResponder(pdf)
            return true
        }
        if let v = window?.firstResponder as? NSView, v === pdf || v.isDescendant(of: pdf) {
            return pdf.handleKey(e)
        }
        // Focus was somewhere else (sidebar, button…): pull it back and page anyway.
        if pdf.handleKey(e) { window?.makeFirstResponder(pdf); return true }
        return false
    }

    // MARK: tabs

    func tabsChanged() {
        tabBar.items = tabs.map { t in
            TabBarView.Item(title: t.controller?.displayName ?? "Home", dirty: t.controller?.isDirty ?? false, isHome: t.isHome)
        }
        tabBar.selected = selected
        window?.title = current?.displayName ?? "PdfPuffin"
        window?.representedURL = current?.fileURL
        window?.isDocumentEdited = current?.isDirty ?? false
        AppDelegate.shared?.saveSession()
    }

    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        current?.textEditor?.commit()
        current?.noteEditor?.commit()
        current?.selection = nil
        selected = i
        content.subviews.forEach { $0.removeFromSuperview() }
        let t = tabs[i]
        let v: NSView
        if let c = t.controller {
            v = c.view
        } else {
            if t.home == nil { let h = HomeView(); h.main = self; t.home = h }
            t.home!.refresh()
            v = t.home!
        }
        content.addSubview(v)
        v.pinEdges(to: content)
        tabsChanged()
        layoutChrome()
        // "This Document" results belong to the tab you are looking at. (All Tabs
        // results already cover every tab; result clicks switch tabs on purpose.)
        if !searchPanel.isHidden, !searchPanel.allTabs, let c = t.controller, !searchPanel.covers(c) {
            DispatchQueue.main.async { self.rerunSearch(keepPosition: true) }
        } else if !searchPanel.isHidden, !searchPanel.allTabs, t.isHome {
            searchPanel.reset()
        }
        if let c = t.controller {
            content.layoutSubtreeIfNeeded()
            c.restoreInitialPageIfNeeded()
            window?.makeFirstResponder(c.pdfView)
            c.sidebar.thumbnails.setCurrent(c.currentPageIndex)
        } else {
            window?.makeFirstResponder(nil)
        }
    }

    func select(controller: DocumentViewController) {
        if let i = tabs.firstIndex(where: { $0.controller === controller }), i != selected { selectTab(i) }
    }

    @objc func newHomeTab(_ sender: Any?) {
        tabs.append(DocTab(controller: nil))
        selectTab(tabs.count - 1)
    }

    /// Adds a document tab; replaces the current Home tab if one is showing.
    func addDocumentTab(_ c: DocumentViewController) {
        c.main = self
        if tabs.indices.contains(selected), tabs[selected].isHome {
            tabs[selected] = DocTab(controller: c)
            selectTab(selected)
        } else {
            tabs.insert(DocTab(controller: c), at: selected + 1)
            selectTab(selected + 1)
        }
    }

    /// Closes a tab, asking about unsaved changes. Returns false if the user
    /// cancelled (or the save failed / its Save panel was cancelled).
    @discardableResult
    func closeTab(at i: Int) -> Bool {
        guard tabs.indices.contains(i) else { return false }
        if let c = tabs[i].controller, c.isDirty {
            selectTab(i)
            let a = NSAlert()
            a.messageText = "Save changes to “\(c.displayName)”?"
            a.informativeText = "If you don’t save, your changes will be lost."
            a.addButton(withTitle: "Save")
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Don’t Save")
            switch a.runModal() {
            case .alertFirstButtonReturn: if !c.save(forceAsk: false) { return false }
            case .alertThirdButtonReturn: break            // Don't Save: the only way to discard
            default: return false                          // Cancel, or anything unexpected
            }
        }
        let closing = tabs[i].controller
        closing?.pdfView.highlightedSelections = nil
        tabs.remove(at: i)
        if tabs.isEmpty { tabs.append(DocTab(controller: nil)) }
        selectTab(min(i > selected ? selected : max(0, selected - (i <= selected ? 1 : 0)), tabs.count - 1))
        if let closing { searchPanel.documentClosed(closing) }
        return true
    }

    @objc func closeTabAction(_ sender: Any?) { closeTab(at: selected) }

    @objc func closeOtherTabs(_ sender: Any?) {
        guard tabs.indices.contains(selected) else { return }
        let keep = tabs[selected]
        for t in tabs.reversed() where t !== keep {
            guard let i = tabs.firstIndex(where: { $0 === t }) else { continue }
            if !closeTab(at: i) { break }   // Cancel or failed save stops the whole command
        }
        if let k = tabs.firstIndex(where: { $0 === keep }) { selectTab(k) }
    }

    func detachTab(at i: Int, screenPoint: NSPoint? = nil) {
        guard tabs.indices.contains(i), tabs.count > 1, let c = tabs[i].controller else { return }
        c.textEditor?.commit()
        c.noteEditor?.commit()
        c.selection = nil
        c.hideSelectionBar()
        c.pdfView.highlightedSelections = nil
        tabs.remove(at: i)
        let nextIdx = min(i > selected ? selected : max(0, selected - (i <= selected ? 1 : 0)), tabs.count - 1)
        selectTab(nextIdx)
        searchPanel.documentClosed(c)

        let newWin = AppDelegate.shared?.makeWindow(initialHome: false) ?? MainWindowController(initialHome: false)
        newWin.addDocumentTab(c)
        if let sp = screenPoint {
            newWin.window?.setFrameTopLeftPoint(NSPoint(x: sp.x - 140, y: sp.y + 20))
        }
        newWin.showWindow(nil)
        newWin.window?.makeKeyAndOrderFront(nil)
        AppDelegate.shared?.saveSession()
    }

    @objc func moveTabToNewWindow(_ sender: Any?) { detachTab(at: selected) }

    @objc func nextTab(_ sender: Any?) { if tabs.count > 1 { selectTab((selected + 1) % tabs.count) } }
    @objc func previousTab(_ sender: Any?) { if tabs.count > 1 { selectTab((selected - 1 + tabs.count) % tabs.count) } }

    var hasUnsavedChanges: Bool { documentControllers.contains { $0.isDirty } }

    /// Asks about each unsaved tab (closing it). Returns false if the user cancelled.
    func confirmCloseAll() -> Bool {
        for t in tabs.reversed() where t.controller?.isDirty == true {
            guard let i = tabs.firstIndex(where: { $0 === t }) else { continue }
            if !closeTab(at: i) { return false }
        }
        return true
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { current?.editHistory }

    /// Edit ▸ Undo / Redo: the tab's own history, or the text field's while you type.
    /// (PDFKit answers undo: itself, so the standard responder-chain route never
    /// reached the tab's history.)
    @objc func undoAction(_ sender: Any?) {
        if isEditingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: sender); return }
        current?.textEditor?.commit()
        current?.noteEditor?.commit()
        current?.selection = nil
        if current?.editHistory.canUndo == true { current?.editHistory.undo() }
    }
    @objc func redoAction(_ sender: Any?) {
        if isEditingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: sender); return }
        current?.selection = nil
        if current?.editHistory.canRedo == true { current?.editHistory.redo() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmCloseAll() }

    func windowWillClose(_ notification: Notification) {
        searchDebounce?.cancel()
        searchDebounce = nil
        searchPanel.cancelSearch()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        AppDelegate.shared?.windowClosed(self)
    }

    // MARK: opening

    func open(urls: [URL], bringToFront: Bool = false) {
        for url in urls {
            let allWindows = AppDelegate.shared?.windows ?? [self]
            if let ownerWin = allWindows.first(where: { $0.documentControllers.contains { $0.fileURL.map { DocumentViewController.sameFile($0, url) } == true } }),
               let existing = ownerWin.documentControllers.first(where: { $0.fileURL.map { DocumentViewController.sameFile($0, url) } == true }) {
                ownerWin.select(controller: existing)
                ownerWin.window?.makeKeyAndOrderFront(nil)
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            var doc: PDFDocument?
            if type?.conforms(to: .pdf) ?? false || url.pathExtension.lowercased() == "pdf" {
                doc = PDFDocument(url: url)
            } else if let img = NSImage(contentsOf: url), let page = PDFPage(image: img) {
                let d = PDFDocument(); d.insert(page, at: 0)
                let c = DocumentViewController(document: d, url: nil, name: url.deletingPathExtension().lastPathComponent)
                addDocumentTab(c)
                if bringToFront { window?.makeKeyAndOrderFront(nil) }
                c.isDirty = true
                continue
            }
            guard let d = doc else {
                let a = NSAlert()
                a.messageText = "PdfPuffin can’t open “\(url.lastPathComponent)”."
                a.informativeText = "It is not a readable PDF or image."
                a.runModal()
                continue
            }
            if d.isLocked {
                let a = NSAlert()
                a.messageText = "“\(url.lastPathComponent)” is password protected."
                let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
                a.accessoryView = f
                a.addButton(withTitle: "Unlock"); a.addButton(withTitle: "Cancel")
                a.window.initialFirstResponder = f
                guard a.runModal() == .alertFirstButtonReturn, d.unlock(withPassword: f.stringValue) else { continue }
            }
            addDocumentTab(DocumentViewController(document: d, url: url))
            if bringToFront { window?.makeKeyAndOrderFront(nil) }
            noteRecent(url)
        }
    }

    func newDocument(fromPages pages: [PDFPage], name: String) {
        guard !pages.isEmpty else { return }
        let d = PDFDocument()
        for p in pages { d.insert(p, at: d.pageCount) }
        let c = DocumentViewController(document: d, url: nil, name: name)
        c.isDirty = true
        tabs.insert(DocTab(controller: c), at: selected + 1)
        c.main = self
        selectTab(selected + 1)
        tabsChanged()
    }

    @objc func openDocumentAction(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf, .image]
        if p.runModal() == .OK { open(urls: p.urls) }
    }

    @objc func newFromClipboard(_ sender: Any?) {
        guard let d = Clipboard.document(from: .general) else {
            let a = NSAlert()
            a.messageText = "Nothing to make a document from."
            a.informativeText = "Copy a PDF, an image, a screenshot, or PDF/image files in Finder, then try again."
            a.runModal()
            return
        }
        let c = DocumentViewController(document: d, url: nil, name: Clipboard.suggestedName(from: .general))
        addDocumentTab(c)
        c.isDirty = true
    }

    // MARK: recents (own list, newest first)

    var recentURLs: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "recents") ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "recents") }
    }

    func noteRecent(_ url: URL) {
        var list = recentURLs.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        recentURLs = Array(list.prefix(30))   // keeps the 30 most recent files
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { open(urls: [u]) }
    }

    @objc func clearRecents(_ sender: Any?) {
        recentURLs = []
        NSDocumentController.shared.clearRecentDocuments(sender)
        for t in tabs { t.home?.refresh() }
    }

    // MARK: saving / printing / finder

    @objc func copyReadingNotes(_ sender: Any?) {
        guard let doc = current else { return }
        if ReadingNotes.copy(from: doc, to: .general) { flash("Copied reading notes") }
        else { flash("No reading notes to copy") }
    }

    @objc func saveReadingNotes(_ sender: Any?) {
        guard let doc = current else { return }
        guard let text = ReadingNotes.markdown(from: doc) else { flash("No reading notes to export"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = doc.displayName + " (reading notes).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func saveCleanCopy(_ sender: Any?) {
        guard let doc = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = doc.displayName + " (student copy).pdf"
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        panel.message = "Remove PDF annotations, including notes, highlights, link annotations, and form fields. Existing page content stays visible."
        while panel.runModal() == .OK, let url = panel.url {
            do {
                let openURLs = (AppDelegate.shared?.windows.flatMap(\.documentControllers) ?? documentControllers).compactMap(\.fileURL)
                try ReadingPacket.writeCleanCopy(of: doc.document, to: url, protecting: openURLs)
                noteRecent(url)
                flash("Saved “\(url.lastPathComponent)”")
                return
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func mergeFiles(_ sender: Any?) {
        guard let sections = PacketDialog(tabs: documentControllers).run() else { return }
        do {
            let pdf = try ReadingPacket.merge(sections)
            let tab = DocumentViewController(document: pdf, url: nil, name: "Reading Packet")
            tab.isDirty = true
            addDocumentTab(tab)
            tab.showSidebar(tab: .outline)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func saveAction(_ sender: Any?) { current?.save(forceAsk: false) }
    @objc func saveAsAction(_ sender: Any?) { current?.save(forceAsk: true) }
    @objc func printAction(_ sender: Any?) {
        current?.pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
    }
    @objc func showInFinder(_ sender: Any?) {
        if let u = current?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    // MARK: toolbar state

    func updateToolbar() {
        toolbar.update(doc: current, toolsShown: toolsShown, altRow: altRow)
        toolRow.update(markup: current?.markupTool, shape: current?.shapeTool, colorKey: colorKey)
        fillRow.update(shape: current?.shapeTool)
        // PDF Expert-style inspector for the armed tool, or the selected annotation.
        let key: String? = current?.shapeTool?.rawValue ?? current?.markupTool.map { AnnotColors.key(for: $0) }
            ?? (current?.textEditor != nil ? "text" : nil)
        if let key {
            if inspector.isHidden || inspector.shownKey != key { inspector.show(key: key) }
            if inspector.isHidden { keepingZoom { inspector.isHidden = false; inspectorWidth.constant = 250 } }
        } else if let sel = current?.selection, ToolInspector.inspectorKey(for: sel.annotation) != nil {
            if inspector.isHidden || inspector.editingAnnotation !== sel.annotation { inspector.show(selection: sel) }
            if inspector.isHidden { keepingZoom { inspector.isHidden = false; inspectorWidth.constant = 250 } }
        } else if !inspector.isHidden {
            keepingZoom { inspector.isHidden = true; inspectorWidth.constant = 0 }
        }
    }

    /// Opening or closing the inspector must not re-zoom the page under the pointer
    /// (that moved a signature off its line): hold the scale and scroll position.
    private func keepingZoom(_ change: () -> Void) {
        guard let pdf = current?.pdfView else { change(); return }
        let scale = pdf.scaleFactor
        let page = pdf.currentPage
        let clip = pdf.documentView?.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        pdf.autoScales = false
        change()
        window?.contentView?.layoutSubtreeIfNeeded()
        pdf.scaleFactor = scale
        if let clip, let origin { clip.scroll(to: origin); pdf.documentView?.enclosingScrollView?.reflectScrolledClipView(clip) }
        else if let page { pdf.go(to: page) }
    }

    /// Arms a page tool (shapes, pen, eraser, text, signature).
    func armTool(_ t: ShapeTool) {
        guard let d = current else { return }
        // Show the row the tool lives on (a shortcut can arm it from another tab).
        if t.isClickPlaced { if altRow != .fillSign { altRow = .fillSign } }
        else if altRow == .convert || (altRow == .fillSign && t != .text && t != .signature) { altRow = nil; toolsShown = true }
        d.markupTool = nil
        d.shapeTool = t
        lastToolKey = t.rawValue
        if t.isShape { UserDefaults.standard.set(t.rawValue, forKey: "lastShape") }
        inspector.show(key: t.rawValue)
        updateToolbar()
        focusPDF()
    }

    @objc func toggleAnnotateTools(_ sender: Any?) {
        if altRow != nil { altRow = nil; toolsShown = true } else { toolsShown.toggle() }
        focusPDF()
    }
    @objc func toggleConvertTools(_ sender: Any?) { altRow = altRow == .convert ? nil : .convert; focusPDF() }
    @objc func toggleFillSignTools(_ sender: Any?) { altRow = altRow == .fillSign ? nil : .fillSign; focusPDF() }

    /// Convert ▸ to Word: writes a .docx next to the PDF and opens it.
    @objc func exportToWord(_ sender: Any?) {
        guard let doc = current else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = doc.displayName + ".docx"
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        panel.message = "Text, fonts and paragraphs are converted; images and drawings are not."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WordExport.write(doc.document, to: url)
            flash("Saved “\(url.lastPathComponent)”")
            NSWorkspace.shared.open(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: view

    // MARK: page grid

    @objc func toggleGridView(_ sender: Any?) {
        guard let d = current else { return }
        d.setGrid(!d.gridMode)
    }

    /// The grid opened or closed: swap the annotate bar and the page-tools bar.
    func gridModeChanged() { layoutChrome() }

    private var gridTargets: IndexSet { current?.grid?.targetPages ?? [] }

    @objc func gridInsertBlank(_ sender: Any?) {
        guard let d = current else { return }
        let after = gridTargets.last ?? (d.pageCount - 1)
        d.insertPages([d.blankPage(like: after)], at: after + 1, name: "Insert Page")
    }
    @objc func gridAppendFile(_ sender: Any?) {
        guard let d = current else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        var pages: [PDFPage] = []
        for u in p.urls {
            guard let src = PDFDocument(url: u) else { continue }
            for i in 0..<src.pageCount { if let pg = src.page(at: i)?.copy() as? PDFPage { pages.append(pg) } }
        }
        let after = gridTargets.last ?? (d.pageCount - 1)
        d.insertPages(pages, at: after + 1, name: "Append File")
    }
    @objc func gridRotate(_ sender: Any?) {
        let ccw = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        current?.rotatePages(gridTargets, by: ccw ? -90 : 90)
    }
    @objc func gridCopy(_ sender: Any?) {
        guard let d = current, !gridTargets.isEmpty else { return }
        if d.writeExcerpt(gridTargets, to: .general) {
            flash("Copied \(gridTargets.count) page\(gridTargets.count == 1 ? "" : "s") (\(ThumbnailsPane.describe(gridTargets)))")
        } else { NSSound.beep() }
    }
    @objc func gridPaste(_ sender: Any?) {
        guard let d = current, let src = Clipboard.document(from: .general) else { NSSound.beep(); return }
        let pages = (0..<src.pageCount).compactMap { src.page(at: $0)?.copy() as? PDFPage }
        let after = gridTargets.last ?? (d.pageCount - 1)
        d.insertPages(pages, at: after + 1, name: "Paste Pages")
    }
    @objc func gridExtract(_ sender: Any?) {
        guard let d = current, !gridTargets.isEmpty else { return }
        newDocument(fromPages: d.copies(of: gridTargets), name: d.excerptName(for: gridTargets))
    }
    @objc func gridDelete(_ sender: Any?) {
        guard let d = current, !gridTargets.isEmpty else { return }
        if gridTargets.count >= d.pageCount { flash("A document must keep at least one page"); NSSound.beep(); return }
        d.changePages(gridTargets, before: nil)
    }

    @objc func toggleLeftPanel(_ sender: Any?) {
        guard let d = current else { return }
        // In the page grid the sidebar button leaves the grid (as ⌘4 does) and
        // shows the sidebar.
        if d.gridMode { d.setGrid(false); d.sidebarVisible = true; return }
        d.sidebarVisible.toggle()
    }
    @objc func showBookmarks(_ sender: Any?) { current?.showSidebar(tab: .bookmarks) }
    @objc func showOutline(_ sender: Any?) { current?.showSidebar(tab: .outline) }
    @objc func showAnnotations(_ sender: Any?) { current?.showSidebar(tab: .annotations) }
    @objc func showThumbnails(_ sender: Any?) { current?.showSidebar(tab: .thumbnails) }

    @objc func setLayoutAction(_ sender: NSMenuItem) {
        guard let d = current, let l = PageLayout(rawValue: sender.tag) else { return }
        d.layout = l
        d.applyLayout()
    }
    @objc func cropPagesAction(_ sender: Any?) {
        guard let doc = current, doc.pageCount > 0 else { return }
        doc.textEditor?.commit()
        CropDialog(doc).run()
        focusPDF()
    }

    @objc func compareDocuments(_ sender: Any?) {
        guard let doc = current, documentControllers.count > 1, let window else { return }
        doc.textEditor?.commit()
        let comparison = DocumentComparison(tabs: documentControllers, current: doc)
        window.beginSheet(comparison.window) { [comparison] _ in comparison.window.orderOut(nil) }
    }

    @objc func setReadingSplit(_ sender: NSMenuItem) {
        current?.setReadingSplit(sender.tag)
        focusPDF()
    }

    @objc func toggleContinuous(_ sender: Any?) {
        guard let d = current else { return }
        d.continuous.toggle()
        d.applyLayout()
    }

    @objc func zoomInAction(_ sender: Any?) { current?.pdfView.zoomIn(nil) }
    @objc func zoomOutAction(_ sender: Any?) { current?.pdfView.zoomOut(nil) }
    @objc func zoomActualAction(_ sender: Any?) { current?.setScale(1) }
    @objc func zoomFitWidthAction(_ sender: Any?) { current?.zoomFitWidth() }
    @objc func zoomFitPageAction(_ sender: Any?) { current?.zoomFitPage() }
    @objc func zoomAutoAction(_ sender: Any?) { current?.pdfView.autoScales = true }
    @objc func zoomPercentAction(_ sender: NSMenuItem) { current?.setScale(CGFloat(sender.tag) / 100) }

    // MARK: go

    @objc func previousPageAction(_ sender: Any?) { current?.previousPage() }
    @objc func nextPageAction(_ sender: Any?) { current?.nextPage() }
    @objc func firstPageAction(_ sender: Any?) { current?.firstPage() }
    @objc func lastPageAction(_ sender: Any?) { current?.lastPage() }
    @objc func pageUpAction(_ sender: Any?) { current?.pdfView.pageScroll(down: false) }
    @objc func pageDownAction(_ sender: Any?) { current?.pdfView.pageScroll(down: true) }
    @objc func goBackAction(_ sender: Any?) { current?.pdfView.goBack(nil) }
    @objc func goForwardAction(_ sender: Any?) { current?.pdfView.goForward(nil) }

    @objc func goToPageDialog(_ sender: Any?) {
        guard let d = current else { return }
        if let index = PageRangeDialog(doc: d, single: true).run()?.first { d.jump(toPage: index) }
        focusPDF()
    }

    @objc func excerptFromRange(_ sender: Any?) {
        guard let d = current else { return }
        let dialog = PageRangeDialog(doc: d, single: false)
        guard let pages = dialog.run() else { return }
        newDocument(fromPages: d.copies(of: pages), name: d.excerptName(for: pages, printed: dialog.usesPrintedPages))
    }

    @objc func setPrintedPage(_ sender: Any?) {
        guard let d = current else { return }
        let a = NSAlert()
        a.messageText = "Set Printed Page Number"
        let index = d.currentPageIndex
        a.informativeText = "Enter the number printed on PDF page \(index + 1). PdfPuffin counts other pages from here. Clear the field to use the PDF’s own labels."
        let field = NSTextField(string: d.printedLabel(at: index))
        field.frame.size = NSSize(width: 240, height: 24)
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.addButton(withTitle: "Apply")
        a.addButton(withTitle: "Cancel")
        while a.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { d.setPrintedOffset(nil); break }
            if let n = Int32(value), n > 0 { d.setPrintedOffset(Int(n) - index - 1); break }
            a.informativeText = "Enter a positive whole number or clear the field."
        }
        focusPDF()
    }

    // MARK: edit

    @objc func addBookmarkAction(_ sender: Any?) {
        guard let d = current else { return }
        let had = d.bookmarks.contains(d.currentPageIndex)
        d.toggleBookmark()
        flash(had ? "Bookmark removed from page \(d.currentPageIndex + 1)" : "Bookmarked page \(d.currentPageIndex + 1)")
    }
    @objc func rotateLeftAction(_ sender: Any?) { current?.rotateCurrentPage(by: -90) }
    @objc func rotateRightAction(_ sender: Any?) { current?.rotateCurrentPage(by: 90) }

    // MARK: annotate

    private func markup(_ t: PDFAnnotationSubtype) {
        guard let d = current else { return }
        lastToolKey = AnnotColors.key(for: t)
        if let sel = d.pdfView.currentSelection, !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d.applyMarkup(t)
        } else {
            // No selection: arm the tool; the next text you select gets marked.
            if d.markupTool != t, altRow != nil { altRow = nil; toolsShown = true }   // show the Annotate row
            d.markupTool = d.markupTool == t ? nil : t
        }
        focusPDF()
    }
    @objc func highlightAction(_ sender: Any?) { markup(.highlight) }
    @objc func underlineAction(_ sender: Any?) { markup(.underline) }
    @objc func strikeoutAction(_ sender: Any?) { markup(.strikeOut) }
    @objc func noteAction(_ sender: Any?) {
        guard let d = current else { return }
        if let sel = d.pdfView.currentSelection,
           !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            d.addNote(at: sel)
            focusPDF()
        } else {
            toggleShape(.note)
        }
    }
    @objc func selectToolAction(_ sender: Any?) {
        current?.markupTool = nil; current?.shapeTool = nil; current?.selection = nil; focusPDF()
    }

    private func toggleShape(_ t: ShapeTool) {
        guard let d = current else { return }
        if d.shapeTool == t { d.shapeTool = nil; updateToolbar(); focusPDF() } else { armTool(t) }
    }
    @objc func penAction(_ sender: Any?) { toggleShape(.pen) }
    @objc func eraserAction(_ sender: Any?) { toggleShape(.eraser) }
    @objc func lineAction(_ sender: Any?) { toggleShape(.line) }
    @objc func arrowAction(_ sender: Any?) { toggleShape(.arrow) }
    /// The Shapes button arms the shape used last (pick another in the inspector).
    @objc func shapesAction(_ sender: Any?) {
        if current?.shapeTool?.isShape == true { current?.shapeTool = nil; updateToolbar(); focusPDF(); return }
        armTool(ShapeTool(rawValue: UserDefaults.standard.string(forKey: "lastShape") ?? "") ?? .rectangle)
    }
    /// Signature: shows your signatures (imports PDF Expert's the first time).
    @objc func signatureAction(_ sender: Any?) {
        if current?.shapeTool == .signature { current?.shapeTool = nil; updateToolbar(); focusPDF(); return }
        if SignatureStore.all().isEmpty {
            let n = SignatureStore.importFromPDFExpert()
            if n > 0 { flash("Imported \(n) signature\(n == 1 ? "" : "s") from PDF Expert") }
        }
        if SignatureStore.selected == nil { SignatureStore.selected = SignatureStore.all().first }
        armTool(.signature)
    }
    @objc func rectangleAction(_ sender: Any?) { toggleShape(.rectangle) }
    @objc func ovalAction(_ sender: Any?) { toggleShape(.oval) }
    @objc func areaAction(_ sender: Any?) { toggleShape(.area) }
    @objc func textToolAction(_ sender: Any?) { toggleShape(.text) }
    @objc func dateToolAction(_ sender: Any?) { toggleShape(.date) }
    @objc func checkToolAction(_ sender: Any?) { toggleShape(.check) }
    @objc func crossToolAction(_ sender: Any?) { toggleShape(.cross) }
    @objc func stampToolAction(_ sender: Any?) { toggleShape(.stamp) }

    /// The tool whose colour the colour menu shows and changes: the armed tool,
    /// else the one used last.
    var lastToolKey = UserDefaults.standard.string(forKey: "lastToolKey") ?? "rectangle" {
        didSet { UserDefaults.standard.set(lastToolKey, forKey: "lastToolKey") }
    }
    var colorKey: String {
        if let s = current?.shapeTool { return s.rawValue }
        if let m = current?.markupTool { return AnnotColors.key(for: m) }
        return lastToolKey
    }
    @objc func colorAction(_ sender: NSMenuItem) {
        AnnotColors.set(sender.tag, for: colorKey)
        // The inspector only rebuilds when its tool changes; redraw its swatches now.
        if !inspector.isHidden, inspector.shownKey == colorKey { inspector.show(key: colorKey) }
        updateToolbar()
        focusPDF()
    }

    // MARK: pages (thumbnail selection)

    @objc func newDocFromSelectedPages(_ sender: Any?) { current?.sidebar.thumbnails.newDocFromSelection() }

    // MARK: search

    @objc func findAction(_ sender: Any?) {
        guard current != nil || !documentControllers.isEmpty else { NSSound.beep(); return }
        showSearchPanel()
        window?.makeFirstResponder(toolbar.searchField)
        toolbar.searchField.currentEditor()?.selectAll(nil)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let s = current?.pdfView.currentSelection?.string, !s.isEmpty else { NSSound.beep(); return }
        searchDebounce?.cancel()
        searchDebounce = nil
        toolbar.searchField.stringValue = s
        runSearch(s)
    }

    private func showSearchPanel() {
        searchPanel.isHidden = false
        searchWidth.constant = 310
    }

    func closeSearch() {
        searchDebounce?.cancel()
        searchDebounce = nil
        searchPanel.reset()
        searchPanel.isHidden = true
        searchWidth.constant = 0
        toolbar.searchField.stringValue = ""
        window?.makeFirstResponder(current?.pdfView)
    }

    @objc func searchFieldAction(_ sender: Any?) {
        searchDebounce?.cancel()
        searchDebounce = nil
        let q = toolbar.searchField.stringValue
        if q.isEmpty { closeSearch(); return }
        if q != searchPanel.query {
            let item = DispatchWorkItem { [weak self] in self?.runSearch(q) }
            searchDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }
    }

    /// Enter in the search box: search, or go to the next result for the same text.
    func searchEnter() {
        searchDebounce?.cancel()
        searchDebounce = nil
        let q = toolbar.searchField.stringValue
        if q.isEmpty { return }
        if q == searchPanel.query && !searchPanel.hits.isEmpty { searchPanel.next() } else { runSearch(q) }
    }

    func runSearch(_ q: String, jump: Bool = true) {
        showSearchPanel()
        let docs = searchPanel.allTabs ? documentControllers : (current.map { [$0] } ?? [])
        searchPanel.search(q, in: docs, autoJump: jump, preferredDoc: current, preferredPage: current?.currentPageIndex ?? 0)
    }

    /// Searches again with the same text (scope change, tab switch, tab closed).
    /// With keepPosition the view does not jump to a result.
    func rerunSearch(keepPosition: Bool = false) {
        searchDebounce?.cancel()
        searchDebounce = nil
        let q = toolbar.searchField.stringValue
        if q.isEmpty || searchPanel.isHidden { searchPanel.reset(); return }
        runSearch(q, jump: !keepPosition)
    }

    @objc func findNext(_ sender: Any?) {
        if searchPanel.hits.isEmpty { rerunSearch() } else { showSearchPanel(); searchPanel.next() }
    }
    @objc func findPrevious(_ sender: Any?) {
        if searchPanel.hits.isEmpty { rerunSearch() } else { showSearchPanel(); searchPanel.previous() }
    }

    // MARK: toast

    func flash(_ text: String) {
        toastView?.removeFromSuperview()
        let t = NSTextField(labelWithString: "  \(text)  ")
        t.font = .systemFont(ofSize: 13, weight: .medium)
        t.textColor = .white
        t.wantsLayer = true
        t.drawsBackground = true
        t.backgroundColor = Theme.pill
        t.layer?.cornerRadius = 7
        t.layer?.masksToBounds = true
        t.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(t)
        NSLayoutConstraint.activate([
            t.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            t.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            t.heightAnchor.constraint(equalToConstant: 30),
        ])
        toastView = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak t] in t?.removeFromSuperview() }
    }

    // MARK: menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let d = current
        switch item.action {
        case #selector(cropPagesAction(_:)): return (d?.pageCount ?? 0) > 0
        case #selector(compareDocuments(_:)): return d != nil && documentControllers.count > 1
        case #selector(setLayoutAction(_:)):
            item.state = d?.layout.rawValue == item.tag ? .on : .off
            return d != nil
        case #selector(setReadingSplit(_:)):
            item.state = d?.splitDirection == item.tag ? .on : .off
            return d != nil
        case #selector(toggleContinuous(_:)):
            item.state = d?.continuous == true ? .on : .off
            return d != nil
        case #selector(toggleGridView(_:)):
            item.state = d?.gridMode == true ? .on : .off
            return d != nil
        case #selector(gridInsertBlank(_:)), #selector(gridAppendFile(_:)), #selector(gridRotate(_:)),
             #selector(gridCopy(_:)), #selector(gridExtract(_:)):
            return d?.gridMode == true
        case #selector(gridPaste(_:)):
            return d?.gridMode == true && Clipboard.hasImportable(.general)
        case #selector(gridDelete(_:)):
            return d?.gridMode == true && (d.map { gridTargets.count < $0.pageCount } ?? false)
        case #selector(toggleLeftPanel(_:)):
            item.title = d?.sidebarVisible == false ? "Show Left Panel" : "Hide Left Panel"
            return d != nil
        case #selector(toggleAnnotateTools(_:)):
            item.state = toolsShown && altRow == nil ? .on : .off
            return d != nil
        case #selector(toggleConvertTools(_:)):
            item.state = altRow == .convert ? .on : .off
            return d != nil
        case #selector(toggleFillSignTools(_:)):
            item.state = altRow == .fillSign ? .on : .off
            return d != nil
        case #selector(dateToolAction(_:)): item.state = d?.shapeTool == .date ? .on : .off; return d != nil
        case #selector(checkToolAction(_:)): item.state = d?.shapeTool == .check ? .on : .off; return d != nil
        case #selector(crossToolAction(_:)): item.state = d?.shapeTool == .cross ? .on : .off; return d != nil
        case #selector(stampToolAction(_:)): item.state = d?.shapeTool == .stamp ? .on : .off; return d != nil
        case #selector(exportToText(_:)), #selector(exportToRTF(_:)), #selector(exportToHTML(_:)), #selector(exportToImages(_:)),
             #selector(recognizeText(_:)), #selector(saveFlattened(_:)), #selector(reduceFileSize(_:)),
             #selector(setPassword(_:)), #selector(showProperties(_:)):
            return d != nil
        case #selector(exportToWord(_:)):
            return d != nil
        case #selector(showBookmarks(_:)), #selector(showOutline(_:)), #selector(showAnnotations(_:)), #selector(showThumbnails(_:)):
            let tab: SidebarTab = [#selector(showBookmarks(_:)): .bookmarks, #selector(showOutline(_:)): .outline,
                                   #selector(showAnnotations(_:)): .annotations, #selector(showThumbnails(_:)): .thumbnails][item.action!]!
            item.state = (d?.sidebarVisible == true && d?.sidebar.current == tab) ? .on : .off
            return d != nil
        case #selector(highlightAction(_:)): item.state = d?.markupTool == .highlight ? .on : .off; return d != nil
        case #selector(underlineAction(_:)): item.state = d?.markupTool == .underline ? .on : .off; return d != nil
        case #selector(strikeoutAction(_:)): item.state = d?.markupTool == .strikeOut ? .on : .off; return d != nil
        case #selector(rectangleAction(_:)): item.state = d?.shapeTool == .rectangle ? .on : .off; return d != nil
        case #selector(ovalAction(_:)): item.state = d?.shapeTool == .oval ? .on : .off; return d != nil
        case #selector(areaAction(_:)): item.state = d?.shapeTool == .area ? .on : .off; return d != nil
        case #selector(textToolAction(_:)): item.state = d?.shapeTool == .text ? .on : .off; return d != nil
        case #selector(penAction(_:)): item.state = d?.shapeTool == .pen ? .on : .off; return d != nil
        case #selector(eraserAction(_:)): item.state = d?.shapeTool == .eraser ? .on : .off; return d != nil
        case #selector(lineAction(_:)): item.state = d?.shapeTool == .line ? .on : .off; return d != nil
        case #selector(arrowAction(_:)): item.state = d?.shapeTool == .arrow ? .on : .off; return d != nil
        case #selector(signatureAction(_:)): item.state = d?.shapeTool == .signature ? .on : .off; return d != nil
        case #selector(noteAction(_:)): item.state = d?.shapeTool == .note ? .on : .off; return d != nil
        case #selector(colorAction(_:)):
            item.state = AnnotColors.index(for: colorKey) == item.tag ? .on : .off
            return d != nil
        case #selector(saveAction(_:)): return d?.isDirty == true || (d != nil && d?.fileURL == nil)
        case #selector(showInFinder(_:)): return d?.fileURL != nil
        case #selector(newDocFromSelectedPages(_:)):
            let n = d?.sidebar.thumbnails.selectedPages.count ?? 0
            return n > 0
        case #selector(undoAction(_:)):
            if isEditingText { item.title = "Undo"; return true }
            let h = current?.editHistory
            item.title = h?.canUndo == true ? h!.undoMenuItemTitle : "Undo"
            return h?.canUndo == true
        case #selector(redoAction(_:)):
            if isEditingText { item.title = "Redo"; return true }
            let h = current?.editHistory
            item.title = h?.canRedo == true ? h!.redoMenuItemTitle : "Redo"
            return h?.canRedo == true
        case #selector(closeOtherTabs(_:)), #selector(nextTab(_:)), #selector(previousTab(_:)): return tabs.count > 1
        case #selector(moveTabToNewWindow(_:)): return tabs.count > 1 && current != nil
        case #selector(newFromClipboard(_:)):
            return Clipboard.hasImportable(.general)
        case #selector(mergeFiles(_:)), #selector(newHomeTab(_:)), #selector(openDocumentAction(_:)),
             #selector(closeTabAction(_:)), #selector(clearRecents(_:)), #selector(openRecentItem(_:)):
            return true
        case #selector(addBookmarkAction(_:)):
            item.title = (d.map { $0.bookmarks.contains($0.currentPageIndex) } ?? false) ? "Remove Bookmark" : "Add Bookmark"
            return d != nil
        case #selector(goBackAction(_:)): return d?.pdfView.canGoBack ?? false
        case #selector(goForwardAction(_:)): return d?.pdfView.canGoForward ?? false
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return !toolbar.searchField.stringValue.isEmpty
        default:
            return d != nil
        }
    }
}
