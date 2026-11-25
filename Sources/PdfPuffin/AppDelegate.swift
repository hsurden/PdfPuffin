import AppKit

/// Menus mirror PDF Expert 3.13's names and shortcuts (read from its menu bar
/// with docs/reference/read-menus.applescript). Items PdfPuffin does not have are left out.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?
    static let sessionKey = "savedSession"

    private(set) var windows: [MainWindowController] = []
    var main: MainWindowController? {
        (NSApp.keyWindow?.windowController as? MainWindowController)
            ?? (NSApp.mainWindow?.windowController as? MainWindowController)
            ?? windows.first
    }
    private var finishedLaunching = false
    private var pendingURLs: [URL] = []
    private let recentMenu = NSMenu(title: "Open Recent")
    private var isTerminating = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        finishedLaunching = true
        // Files given on the command line (run.sh passes one).
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let fromClipboard = CommandLine.arguments.contains("--from-clipboard")
        if !urls.isEmpty || !pendingURLs.isEmpty || fromClipboard {
            let win = makeWindow(initialHome: true)
            win.showWindow(nil)
            win.open(urls: urls + pendingURLs)
            pendingURLs = []
            // `PdfPuffin --from-clipboard` runs File ▸ New ▸ From Clipboard at launch.
            if fromClipboard { win.newFromClipboard(nil) }
        } else if !restoreSession() {
            let win = makeWindow(initialHome: true)
            win.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        UpdateController.shared.checkAtLaunch()
    }

    func makeWindow(initialHome: Bool = true) -> MainWindowController {
        let hadWindow = !windows.isEmpty
        let w = MainWindowController(initialHome: initialHome)
        if hadWindow, let prev = windows.last?.window {
            w.window?.setFrameTopLeftPoint(NSPoint(x: prev.frame.minX + 26, y: prev.frame.maxY - 26))
        }
        windows.append(w)
        return w
    }

    func windowClosed(_ controller: MainWindowController) {
        windows.removeAll { $0 === controller }
        if !isTerminating { saveSession() }
    }

    func saveSession() {
        guard !isTerminating else { return }
        let payload: [[String: Any]] = windows.compactMap { win in
            let docTabs = win.tabs.compactMap(\.controller)
            let paths = docTabs.compactMap { $0.fileURL?.path }
            guard !paths.isEmpty else { return nil }
            var selectedIdx = 0
            if let cur = win.current, let url = cur.fileURL, let idx = paths.firstIndex(of: url.path) {
                selectedIdx = idx
            }
            return ["paths": paths, "selected": selectedIdx]
        }
        UserDefaults.standard.set(payload, forKey: Self.sessionKey)
    }

    @discardableResult
    func restoreSession() -> Bool {
        guard let saved = UserDefaults.standard.array(forKey: Self.sessionKey) as? [[String: Any]], !saved.isEmpty else {
            return false
        }
        var restoredAny = false
        for entry in saved {
            let paths = (entry["paths"] as? [String]) ?? []
            let savedURLs = paths.map { URL(fileURLWithPath: $0) }
            let urls = savedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { continue }
            let win = makeWindow(initialHome: false)
            win.open(urls: urls)
            if !win.documentControllers.isEmpty {
                let sel = (entry["selected"] as? Int) ?? 0
                let targetURL = savedURLs.indices.contains(sel) ? savedURLs[sel] : nil
                if let targetURL, let tabIdx = win.tabs.firstIndex(where: { $0.controller?.fileURL == targetURL }) {
                    win.selectTab(tabIdx)
                } else {
                    win.selectTab(0)
                }
                win.showWindow(nil)
                restoredAny = true
            } else {
                win.close()
            }
        }
        return restoredAny
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard finishedLaunching else {
            pendingURLs += urls
            return
        }
        guard !urls.isEmpty else { return }
        let target = main ?? makeWindow()
        target.showWindow(nil)
        target.open(urls: urls, bringToFront: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty {
            let win = makeWindow(initialHome: true)
            win.showWindow(nil)
        } else {
            (main ?? windows.first)?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        let snapshot = windows.map { ($0, $0.tabs.compactMap(\.controller), $0.current) }
        for w in Array(windows) {
            if !w.confirmCloseAll() {
                isTerminating = false
                return .terminateCancel
            }
        }
        let payload: [[String: Any]] = snapshot.compactMap { (_, docTabs, cur) in
            let paths = docTabs.compactMap { $0.fileURL?.path }
            guard !paths.isEmpty else { return nil }
            var selectedIdx = 0
            if let cur, let url = cur.fileURL, let idx = paths.firstIndex(of: url.path) {
                selectedIdx = idx
            }
            return ["paths": paths, "selected": selectedIdx]
        }
        UserDefaults.standard.set(payload, forKey: Self.sessionKey)
        return .terminateNow
    }

    @objc func newWindowAction(_ sender: Any?) {
        let win = makeWindow(initialHome: true)
        win.showWindow(nil)
        win.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func checkForUpdates(_ sender: Any?) { UpdateController.shared.check(quietly: false) }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        UpdateController.checksAutomatically.toggle()
        sender.state = UpdateController.checksAutomatically ? .on : .off
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateController.shared.installIfStaged()
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for u in main?.recentURLs ?? [] {
            let i = menu.addItem(withTitle: u.lastPathComponent, action: #selector(MainWindowController.openRecentItem(_:)), keyEquivalent: "")
            i.representedObject = u
            i.toolTip = u.path
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(MainWindowController.clearRecents(_:)), keyEquivalent: "")
    }

    // MARK: menu bar

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.tag = tag
        return i
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    private func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem { menu(title, items) }

    /// A submenu rebuilt each time it opens (Share, split-view documents).
    private func dynamicSub(_ title: String, _ delegate: DynamicMenu) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        m.delegate = delegate
        top.submenu = m
        return top
    }
    private lazy var shareMenu = DynamicMenu { [weak self] m in self?.main?.fillShareMenu(m) }
    private lazy var leftDocMenu = DynamicMenu { [weak self] m in self?.main?.fillDocumentMenu(m, side: 0) }
    private lazy var rightDocMenu = DynamicMenu { [weak self] m in self?.main?.fillDocumentMenu(m, side: 1) }

    private func key(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }

    private func buildMenu() -> NSMenu {
        typealias M = MainWindowController
        let bar = NSMenu()
        let appName = "PdfPuffin"

        bar.addItem(menu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Check for Updates…", #selector(checkForUpdates(_:))),
            {
                let i = item("Check for Updates Automatically", #selector(toggleAutomaticUpdates(_:)))
                i.state = UpdateController.checksAutomatically ? .on : .off
                return i
            }(),
            item("Make PdfPuffin the Default PDF App", #selector(makeDefaultPDFApp(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu

        bar.addItem(menu("File", [
            sub("New", [
                // PDF Expert has no shortcut for From Clipboard. ⌘N matches Preview's
                // "New from Clipboard" (⌥⌘V is often taken system-wide).
                item("Empty Document", #selector(M.newEmptyDocument(_:))),
                item("From Clipboard", #selector(M.newFromClipboard(_:)), "n"),
                item("From Images…", #selector(M.newFromImages(_:))),
                item("From File…", #selector(M.newFromFile(_:))),
                item("From Page Range…", #selector(M.excerptFromRange(_:))),
                item("From Selected Pages", #selector(M.newDocFromSelectedPages(_:))),
            ]),
            item("New Tab", #selector(M.newHomeTab(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindowAction(_:)), "n", [.command, .shift]),
            item("Open…", #selector(M.openDocumentAction(_:)), "o"),
            recent,
            {
                // Continuity Camera: AppKit fills this with nearby iPhones and iPads.
                let i = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
                i.identifier = NSMenuItem.importFromDeviceIdentifier
                return i
            }(),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item("Close Tab", #selector(M.closeTabAction(_:)), "w"),
            item("Close Other Tabs", #selector(M.closeOtherTabs(_:)), "w", [.command, .option]),
            .separator(),
            item("Save", #selector(M.saveAction(_:)), "s"),
            item("Save As…", #selector(M.saveAsAction(_:)), "s", [.command, .shift]),
            .separator(),
            item("Save Copy Without Annotations…", #selector(M.saveCleanCopy(_:))),
            item("Save as Flattened…", #selector(M.saveFlattened(_:))),
            item("Reduce File Size…", #selector(M.reduceFileSize(_:))),
            sub("Export To", [
                item("Word Document (.docx)…", #selector(M.exportToWord(_:))),
                item("Text…", #selector(M.exportToText(_:))),
                item("Rich Text Format…", #selector(M.exportToRTF(_:))),
                item("HTML…", #selector(M.exportToHTML(_:))),
                item("Image (PNG per page)…", #selector(M.exportToImages(_:))),
            ]),
            sub("Export Annotation Summary", [
                item("Copy as Markdown", #selector(M.copyReadingNotes(_:))),
                item("Save as Markdown…", #selector(M.saveReadingNotes(_:))),
                item("Save as Text…", #selector(M.saveSummaryText(_:))),
                item("Save as HTML…", #selector(M.saveSummaryHTML(_:))),
            ]),
            item("Merge Files…", #selector(M.mergeFiles(_:))),
            item("Set Password…", #selector(M.setPassword(_:))),
            .separator(),
            item("Show in Finder", #selector(M.showInFinder(_:))),
            dynamicSub("Share", shareMenu),
            item("Add to Favorites", #selector(M.toggleFavorite(_:))),
            item("Properties…", #selector(M.showProperties(_:))),
            item("Print…", #selector(M.printAction(_:)), "p"),
        ]))

        bar.addItem(menu("Edit", [
            item("Undo", #selector(M.undoAction(_:)), "z"),
            item("Redo", #selector(M.redoAction(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Add Bookmark", #selector(M.addBookmarkAction(_:)), "d"),
            item("Rotate Current Page Left", #selector(M.rotateLeftAction(_:)), "l"),
            item("Rotate Current Page Right", #selector(M.rotateRightAction(_:)), "r"),
            item("Insert Blank Page", #selector(M.insertBlankPageAction(_:))),
            .separator(),
            item("Clear Form", #selector(M.clearFormAction(_:))),
            item("Remove All Annotations", #selector(M.removeAllAnnotationsAction(_:))),
            .separator(),
            sub("Find", [
                item("Find…", #selector(M.findAction(_:)), "f"),
                item("Find Next", #selector(M.findNext(_:)), "g"),
                item("Find Previous", #selector(M.findPrevious(_:)), "g", [.command, .shift]),
                item("Use Selection for Find", #selector(M.useSelectionForFind(_:)), "e"),
            ]),
        ]))

        bar.addItem(menu("View", [
            item("Single Page", #selector(M.setLayoutAction(_:)), "1", tag: 1),
            item("Two Pages", #selector(M.setLayoutAction(_:)), "2", tag: 2),
            item("Two Pages but First Single", #selector(M.setLayoutAction(_:)), "3", tag: 3),
            sub("Split View", [
                item("Horizontal", #selector(M.setReadingSplit(_:)), tag: 1),
                item("Vertical", #selector(M.setReadingSplit(_:)), tag: 2),
                item("Compare Open Documents…", #selector(M.compareDocuments(_:))),
                dynamicSub("Change Left/Top Document", leftDocMenu),
                dynamicSub("Change Right/Bottom Document", rightDocMenu),
                item("Disable Split View", #selector(M.setReadingSplit(_:)), tag: 0),
            ]),
            item("Thumbnails", #selector(M.toggleGridView(_:)), "4"),
            item("Continuous Scroll", #selector(M.toggleContinuous(_:))),
            .separator(),
            item("Bookmarks", #selector(M.showBookmarks(_:)), "1", [.command, .option]),
            item("Outline", #selector(M.showOutline(_:)), "2", [.command, .option]),
            item("Annotation Summary", #selector(M.showAnnotations(_:)), "3", [.command, .option]),
            item("Thumbnails Panel", #selector(M.showThumbnails(_:)), "4", [.command, .option]),
            item("Hide Left Panel", #selector(M.toggleLeftPanel(_:)), "0", [.command, .option]),
            .separator(),
            item("Annotate", #selector(M.toggleAnnotateTools(_:))),
            item("Convert", #selector(M.toggleConvertTools(_:))),
            item("Fill & Sign", #selector(M.toggleFillSignTools(_:))),
            item("Hide Tools", #selector(M.hideToolsAction(_:))),
            item("Always Show Toolbar", #selector(M.alwaysShowToolbarAction(_:))),
            sub("Zoom", [
                item("Zoom In", #selector(M.zoomInAction(_:)), "+"),
                item("Zoom Out", #selector(M.zoomOutAction(_:)), "-"),
                item("Zoom to 100%", #selector(M.zoomActualAction(_:)), "0"),
                item("Zoom to Fit Width", #selector(M.zoomFitWidthAction(_:)), "9"),
                item("Zoom to Fit Page", #selector(M.zoomFitPageAction(_:)), "8"),
                .separator(),
                item("Pan & Zoom", #selector(M.togglePanZoom(_:))),
            ]),
            sub("Theme", PageTheme.allCases.map { item($0.title, #selector(M.themeAction(_:)), tag: $0.rawValue) }),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        bar.addItem(menu("Annotate", [
            item("Crop Pages…", #selector(M.cropPagesAction(_:))),
            item("Highlight", #selector(M.highlightAction(_:)), "h", [.command, .control]),
            item("Underline", #selector(M.underlineAction(_:)), "u", [.command, .control]),
            item("Strikeout", #selector(M.strikeoutAction(_:)), "s", [.command, .control]),
            item("Text", #selector(M.textToolAction(_:)), "t", [.command, .control]),
            item("Pen", #selector(M.penAction(_:)), "p", [.command, .control]),
            item("Eraser", #selector(M.eraserAction(_:)), "e", [.command, .control]),
            item("Note", #selector(M.noteAction(_:)), "n", [.command, .control]),
            item("Signature", #selector(M.signatureAction(_:))),
            item("Date", #selector(M.dateToolAction(_:))),
            item("Checkmark", #selector(M.checkToolAction(_:))),
            item("Cross", #selector(M.crossToolAction(_:))),
            item("Stamp", #selector(M.stampToolAction(_:))),
            .separator(),
            item("Rectangle", #selector(M.rectangleAction(_:)), "r", [.command, .control]),
            item("Oval", #selector(M.ovalAction(_:)), "o", [.command, .control]),
            item("Line", #selector(M.lineAction(_:)), "l", [.command, .control]),
            item("Arrow", #selector(M.arrowAction(_:)), "a", [.command, .control]),
            item("Double Arrow", #selector(M.doubleArrowAction(_:))),
            item("Highlight Area", #selector(M.areaAction(_:))),
            .separator(),
            sub("Color", [
                item("Red", #selector(M.colorAction(_:)), "1", [.command, .control, .option], tag: 0),
                item("Orange", #selector(M.colorAction(_:)), "2", [.command, .control, .option], tag: 1),
                item("Yellow", #selector(M.colorAction(_:)), "3", [.command, .control, .option], tag: 2),
                item("Green", #selector(M.colorAction(_:)), "4", [.command, .control, .option], tag: 3),
                item("Blue", #selector(M.colorAction(_:)), "5", [.command, .control, .option], tag: 4),
                item("Purple", #selector(M.colorAction(_:)), "6", [.command, .control, .option], tag: 5),
                item("Black", #selector(M.colorAction(_:)), "7", [.command, .control, .option], tag: 6),
                .separator(),
                item("Custom…", #selector(M.customColorAction(_:))),
            ]),
        ]))

        bar.addItem(menu("Scan & OCR", [
            item("Recognize Text", #selector(M.recognizeText(_:))),
        ]))

        bar.addItem(menu("Go", [
            item("Previous Page", #selector(M.previousPageAction(_:)), key(NSUpArrowFunctionKey), [.option]),
            item("Next Page", #selector(M.nextPageAction(_:)), key(NSDownArrowFunctionKey), [.option]),
            item("First Page", #selector(M.firstPageAction(_:)), key(NSHomeFunctionKey), []),
            item("Last Page", #selector(M.lastPageAction(_:)), key(NSEndFunctionKey), []),
            item("Up", #selector(M.pageUpAction(_:)), key(NSPageUpFunctionKey), []),
            item("Down", #selector(M.pageDownAction(_:)), key(NSPageDownFunctionKey), []),
            .separator(),
            item("Set Printed Page Number…", #selector(M.setPrintedPage(_:))),
            item("Go to Page…", #selector(M.goToPageDialog(_:)), "g", [.command, .option]),
            item("Back", #selector(M.goBackAction(_:)), "["),
            item("Forward", #selector(M.goForwardAction(_:)), "]"),
        ]))

        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Go to Previous Tab", #selector(M.previousTab(_:)), "[", [.command, .shift]),
            item("Go to Next Tab", #selector(M.nextTab(_:)), "]", [.command, .shift]),
            item("Move Tab to New Window", #selector(M.moveTabToNewWindow(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        bar.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return bar
    }
}
