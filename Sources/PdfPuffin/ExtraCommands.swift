import AppKit
import PDFKit
import UniformTypeIdentifiers

// Commands added to match PDF Expert's menus: new documents, import from iPhone,
// form and annotation clean-up, summary export, sharing, toolbar options, page
// themes and choosing split-view documents. Pan & Zoom is in PanZoom.swift.

// MARK: - page themes (View ▸ Theme)

enum PageTheme: Int, CaseIterable {
    case day, sepia, night
    var title: String { ["Day", "Sepia", "Night"][rawValue] }
    static let changed = Notification.Name("PdfPuffinThemeChanged")

    static var current: PageTheme {
        get { PageTheme(rawValue: UserDefaults.standard.integer(forKey: "pageTheme")) ?? .day }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "pageTheme")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Core Image filters for the page area. Sepia tints white paper cream and keeps
    /// black text black; Night inverts brightness but keeps hues (a red highlight stays red).
    var filters: [CIFilter] {
        switch self {
        case .day:
            return []
        case .sepia:
            let m = CIFilter(name: "CIColorMatrix")!
            m.setValue(CIVector(x: 0.97, y: 0, z: 0, w: 0), forKey: "inputRVector")
            m.setValue(CIVector(x: 0, y: 0.92, z: 0, w: 0), forKey: "inputGVector")
            m.setValue(CIVector(x: 0, y: 0, z: 0.80, w: 0), forKey: "inputBVector")
            return [m]
        case .night:
            let invert = CIFilter(name: "CIColorInvert")!
            let hue = CIFilter(name: "CIHueAdjust")!
            hue.setValue(Float.pi, forKey: "inputAngle")
            // Soften the contrast: black paper becomes dark grey, white text light grey.
            let soften = CIFilter(name: "CIColorMatrix")!
            soften.setValue(CIVector(x: 0.80, y: 0, z: 0, w: 0), forKey: "inputRVector")
            soften.setValue(CIVector(x: 0, y: 0.80, z: 0, w: 0), forKey: "inputGVector")
            soften.setValue(CIVector(x: 0, y: 0, z: 0.80, w: 0), forKey: "inputBVector")
            soften.setValue(CIVector(x: 0.11, y: 0.11, z: 0.12, w: 0), forKey: "inputBiasVector")
            return [invert, hue, soften]
        }
    }
}

extension PuffinPDFView {
    /// Applies the page theme to the scrolling page area only, so floating bars and
    /// note cards on top of the PDF keep their normal colours.
    func applyPageTheme() {
        guard let docView = documentView else { return }
        docView.wantsLayer = true
        docView.layerUsesCoreImageFilters = true
        docView.contentFilters = PageTheme.current.filters
    }
}

// MARK: - menus filled when opened (Share, split-view documents)

/// Fills a submenu each time it opens.
final class DynamicMenu: NSObject, NSMenuDelegate {
    private let fill: (NSMenu) -> Void
    init(_ fill: @escaping (NSMenu) -> Void) { self.fill = fill }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu)
    }
}

extension MainWindowController: NSServicesMenuRequestor {

    // MARK: new documents

    @objc func newEmptyDocument(_ sender: Any?) {
        let d = PDFDocument()
        let size = NSSize(width: 612, height: 792)   // US Letter
        let img = NSImage(size: size, flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
        if let page = PDFPage(image: img) {
            page.setBounds(NSRect(origin: .zero, size: size), for: .mediaBox)
            d.insert(page, at: 0)
        }
        addUntitled(d, name: "Untitled")
    }

    @objc func newFromImages(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image]
        p.message = "Choose images. Each becomes a page, in the order shown."
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let urls = p.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let d = Clipboard.document(fromFiles: urls) else { NSSound.beep(); return }
        addUntitled(d, name: urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Images")
    }

    @objc func newFromFile(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf, .image]
        p.message = "Choose PDFs or images. They are combined into a new, unsaved document."
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        guard let d = Clipboard.document(fromFiles: p.urls) else { NSSound.beep(); return }
        addUntitled(d, name: p.urls.count == 1 ? p.urls[0].deletingPathExtension().lastPathComponent + " copy" : "Combined")
    }

    private func addUntitled(_ d: PDFDocument, name: String) {
        let c = DocumentViewController(document: d, url: nil, name: name)
        addDocumentTab(c)
        c.isDirty = true
    }

    // MARK: File ▸ Import from iPhone or iPad (Continuity Camera)

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let r = returnType,
           [.pdf, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg")].contains(r) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let d = Clipboard.document(from: pboard) else { return false }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        addUntitled(d, name: "Scan \(f.string(from: Date()))")
        return true
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }

    // MARK: Edit menu

    @objc func insertBlankPageAction(_ sender: Any?) { current?.insertBlankPageAfterCurrent() }

    @objc func clearFormAction(_ sender: Any?) {
        guard let d = current else { return }
        d.clearForm()
        flash("Form cleared (⌘Z to undo)")
    }

    @objc func removeAllAnnotationsAction(_ sender: Any?) {
        guard let d = current else { return }
        let n = d.removeAllAnnotations()
        flash(n == 0 ? "No annotations to remove" : "Removed \(n) annotation\(n == 1 ? "" : "s") (⌘Z to undo)")
    }

    // MARK: Annotate ▸ Double Arrow, Color ▸ Custom…

    @objc func doubleArrowAction(_ sender: Any?) { armTool(.doubleArrow) }

    @objc func customColorAction(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = AnnotColors.color(for: colorKey)
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.isContinuous = false
        panel.orderFront(nil)
    }

    @objc func customColorChanged(_ sender: NSColorPanel) {
        AnnotColors.setCustom(sender.color, for: colorKey)
        if !inspector.isHidden, inspector.shownKey == colorKey { inspector.show(key: colorKey) }
        updateToolbar()
    }

    // MARK: File ▸ Export Annotation Summary (Text, HTML)

    @objc func saveSummaryText(_ sender: Any?) { saveSummary(ext: "txt", type: .plainText, ReadingNotes.plainText) }
    @objc func saveSummaryHTML(_ sender: Any?) { saveSummary(ext: "html", type: .html, ReadingNotes.html) }

    private func saveSummary(ext: String, type: UTType, _ render: (DocumentViewController) -> String?) {
        guard let doc = current else { return }
        guard let text = render(doc) else { flash("No annotations to export"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = doc.displayName + " (annotations).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { NSAlert(error: error).runModal() }
    }

    // MARK: File ▸ Share

    /// The file to share: the saved PDF, or (when there are unsaved changes or no
    /// file yet) a copy of the current state in a temporary folder.
    private func shareableURL() -> URL? {
        guard let d = current else { return nil }
        if let u = d.fileURL, !d.isDirty { return u }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PdfPuffin Share/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(d.displayName + ".pdf")
        return d.document.write(to: u) ? u : nil
    }

    func fillShareMenu(_ menu: NSMenu) {
        guard current != nil else {
            menu.addItem(withTitle: "Open a document to share it", action: nil, keyEquivalent: "")
            return
        }
        // Services offered for a PDF file. (The probe file is never written.)
        let probe = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe.pdf")
        for service in NSSharingService.sharingServices(forItems: [probe]) {
            let item = NSMenuItem(title: service.menuItemTitle, action: #selector(shareVia(_:)), keyEquivalent: "")
            item.image = service.image
            item.representedObject = service
            item.target = self
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No sharing services available", action: nil, keyEquivalent: "") }
    }

    @objc func shareVia(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService, let u = shareableURL() else { NSSound.beep(); return }
        service.perform(withItems: [u])
    }

    // MARK: View ▸ Hide Tools, Always Show Toolbar

    @objc func hideToolsAction(_ sender: Any?) {
        if toolsShown || altRow != nil { altRow = nil; toolsShown = false } else { toolsShown = true }
        focusPDF()
    }

    static var alwaysShowToolbar: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysShowToolbar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysShowToolbar") }
    }

    @objc func alwaysShowToolbarAction(_ sender: Any?) {
        Self.alwaysShowToolbar.toggle()
        for w in AppDelegate.shared?.windows ?? [self] { w.updateFullScreenChrome() }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    /// In full screen with Always Show Toolbar off, the tab bar and toolbars slide up
    /// out of view and come back while the pointer is at the top of the screen.
    func updateFullScreenChrome() {
        let tuck = isFullScreen && !Self.alwaysShowToolbar
        if tuck, fullScreenMonitor == nil {
            window?.acceptsMouseMovedEvents = true
            fullScreenMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
                guard let self, e.window === self.window, let root = self.window?.contentView else { return e }
                let fromTop = root.bounds.height - root.convert(e.locationInWindow, from: nil).y
                let chromeHeight = self.tabBar.frame.height + self.toolbar.frame.height + self.toolRow.frame.height
                if self.chromeTucked, fromTop < 6 { self.setChromeTucked(false) }
                else if !self.chromeTucked, fromTop > chromeHeight + 30 { self.setChromeTucked(true) }
                return e
            }
        } else if !tuck, let m = fullScreenMonitor {
            NSEvent.removeMonitor(m)
            fullScreenMonitor = nil
        }
        setChromeTucked(tuck)
    }

    private func setChromeTucked(_ tucked: Bool) {
        chromeTucked = tucked
        let height = tabBar.frame.height + toolbar.frame.height + toolRow.frame.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            chromeTop.animator().constant = tucked ? -height : 0
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { updateFullScreenChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { updateFullScreenChrome() }

    // MARK: View ▸ Theme

    @objc func themeAction(_ sender: NSMenuItem) {
        PageTheme.current = PageTheme(rawValue: sender.tag) ?? .day
    }

    // MARK: View ▸ Split View ▸ Change Left / Right Document

    func fillDocumentMenu(_ menu: NSMenu, side: Int) {
        let docs = documentControllers
        guard docs.count > 1 else {
            menu.addItem(withTitle: "Open another document to compare", action: nil, keyEquivalent: "")
            return
        }
        for (i, d) in docs.enumerated() {
            let item = NSMenuItem(title: d.displayName, action: #selector(compareChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = side
            item.representedObject = i
            item.state = d === current ? .on : .off
            menu.addItem(item)
        }
    }

    /// Opens Compare with the chosen document on that side and this tab (or, if the
    /// chosen one is this tab, the next tab) on the other.
    @objc func compareChosen(_ sender: NSMenuItem) {
        let docs = documentControllers
        guard docs.count > 1, let chosen = sender.representedObject as? Int, docs.indices.contains(chosen),
              let window else { return }
        let here = current.flatMap { c in docs.firstIndex { $0 === c } } ?? 0
        let other = here == chosen ? (chosen + 1) % docs.count : here
        let (left, right) = sender.tag == 0 ? (chosen, other) : (other, chosen)
        current?.textEditor?.commit()
        let comparison = DocumentComparison(tabs: docs, left: left, right: right)
        window.beginSheet(comparison.window) { [comparison] _ in comparison.window.orderOut(nil) }
    }

    // MARK: menu state

    /// Menu validation for the commands in this file; nil means "not one of mine".
    func validateExtraItem(_ item: NSMenuItem) -> Bool? {
        let d = current
        switch item.action {
        case #selector(newEmptyDocument(_:)), #selector(newFromImages(_:)), #selector(newFromFile(_:)):
            return true
        case #selector(clearFormAction(_:)):
            return d?.hasFilledForm ?? false
        case #selector(removeAllAnnotationsAction(_:)):
            return !(d?.userAnnotations.isEmpty ?? true)
        case #selector(doubleArrowAction(_:)):
            item.state = d?.shapeTool == .doubleArrow ? .on : .off
            return d != nil
        case #selector(customColorAction(_:)):
            item.state = AnnotColors.index(for: colorKey) == AnnotColors.customIndex ? .on : .off
            return d != nil
        case #selector(hideToolsAction(_:)):
            item.title = toolsShown || altRow != nil ? "Hide Tools" : "Show Tools"
            return d != nil
        case #selector(alwaysShowToolbarAction(_:)):
            item.state = Self.alwaysShowToolbar ? .on : .off
            return true
        case #selector(themeAction(_:)):
            item.state = PageTheme.current.rawValue == item.tag ? .on : .off
            return true
        case #selector(togglePanZoom(_:)):
            item.state = PanZoomPanel.isShown ? .on : .off
            return d != nil
        default:
            return nil
        }
    }
}
