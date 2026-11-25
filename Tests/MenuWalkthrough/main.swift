import AppKit
import PDFKit
import CoreText
import ObjectiveC

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WALKTHROUGH_OUTPUT"]!)
let fixture = output.appendingPathComponent("fixtures/Walkthrough.pdf")
let report = output.appendingPathComponent("steps.md")
try "# PdfPuffin menu walkthrough\n\n".write(to: report, atomically: true, encoding: .utf8)
let logFile = try FileHandle(forWritingTo: report)
logFile.seekToEndOfFile()
func log(_ line: String) { logFile.write(Data((line + "\n").utf8)) }
func check(_ ok: Bool, _ name: String) { log("- \(ok ? "PASS" : "FAIL") | \(name)") }
func settle(_ duration: Double = 0.16) { RunLoop.current.run(until: Date().addingTimeInterval(duration)) }

func makeFixture() {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(fixture as CFURL, mediaBox: &box, nil)!
    for page in 1...6 {
        ctx.beginPDFPage(nil)
        for row in 0..<14 {
            let string = row == 0 ? "Walkthrough / Page \(page)" : "Sample paragraph \(row). Menu navigation, search and annotation checks."
            let text = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: row == 0 ? 24 : 13)])
            ctx.textPosition = CGPoint(x: 40, y: 720 - row * 33)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

// Route the application's general-pasteboard accesses to a private test board.
let board = NSPasteboard.withUniqueName()
extension NSPasteboard {
    @objc class func walkthroughBoard() -> NSPasteboard { board }
}
method_exchangeImplementations(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general))!,
                               class_getClassMethod(NSPasteboard.self, #selector(NSPasteboard.walkthroughBoard))!)

struct Entry {
    let name: String
    let item: NSMenuItem
    let menu: NSMenu
}
var entries: [Entry] = []
func inventory(_ menu: NSMenu, _ path: [String]) {
    for item in menu.items where !item.isSeparatorItem {
        let parts = path + [item.title]
        if let sub = item.submenu {
            sub.delegate?.menuNeedsUpdate?(sub)
            inventory(sub, parts)
        } else if item.action != nil && !item.isHidden {
            entries.append(Entry(name: parts.joined(separator: " › "), item: item, menu: menu))
        }
    }
}
var step = 0
var used = Set<String>()
var completed = Set<String>()
var base: MainWindowController!
var doc: DocumentViewController!
var seq = 0
var unavailable = Set<String>()

func shot(_ label: String, _ window: NSWindow? = nil) {
    guard let w = window ?? base.window, w.isVisible, let view = w.contentView else {
        check(false, "Missing window for screenshot " + label); return
    }
    seq += 1
    let file = String(format: "%03d-", seq) + label.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-") + ".png"
    let path = output.appendingPathComponent("screenshots/" + file)
    w.displayIfNeeded()
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(w.windowNumber), path.path]
    try? capture.run()
    if capture.isRunning { capture.waitUntilExit() }
    var method = "window"
    if !FileManager.default.fileExists(atPath: path.path) {
        method = "content view"
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check(false, label); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
    log("- [Screenshot \(seq): \(label)](screenshots/\(file)) (\(method))")
}

func focus() {
    base.select(controller: doc)
    base.window?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    base.window?.makeFirstResponder(doc.pdfView)
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

func invoke(_ e: Entry) {
    used.insert(e.name)
    step += 1
    log("\n### \(step). \(e.name)")
    log("- Started \(ISO8601DateFormatter().string(from: Date()))")
    e.menu.update()
    guard e.item.isEnabled, let action = e.item.action,
          let target = app.target(forAction: action, to: e.item.target, from: e.item) else {
        if e.name.hasPrefix("Edit › Writing Tools ›") || e.name.hasPrefix("Edit › AutoFill ›") || e.name.contains(" › Start Dictation") {
            unavailable.insert(e.name)
            log("- Unavailable | macOS service disabled in this context")
        } else { check(false, "Disabled or missing responder") }
        return
    }
    let timer = Timer(timeInterval: 0.35, repeats: true) { _ in
        guard let w = app.modalWindow ?? app.windows.compactMap(\.attachedSheet).first else { return }
        let buttons = w.contentView.map { descendants($0).compactMap { $0 as? NSButton } } ?? []
        if ["Go to Page…", "From Page Range…", "Set Printed Page Number…"].contains(e.item.title),
           let confirm = buttons.first(where: { ["Go", "Create Excerpt", "Apply"].contains($0.title) && $0.isEnabled }) {
            if confirm.title == "Create Excerpt" { shot("Page range dialog", w) }
            log("- Accepted fixture dialog: " + confirm.title)
            confirm.performClick(nil)
        } else if let panel = w as? NSSavePanel {
            log("- Opened \(type(of: panel)); cancelled"); panel.cancel(nil)
        } else if let cancel = buttons.first(where: { $0.title == "Don’t Save" || $0.title == "Don't Save" })
                    ?? buttons.first(where: { $0.title == "Cancel" }) {
            log("- Dialog button: \(cancel.title)"); cancel.performClick(nil)
        } else {
            log("- Modal dismissed with Cancel response"); app.stopModal(withCode: .cancel)
            if let parent = w.sheetParent { parent.endSheet(w, returnCode: .cancel) }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer { timer.invalidate() }
    if app.sendAction(action, to: target, from: e.item) {
        completed.insert(e.name)
        log("- Dispatched to \(type(of: target))")
    } else { check(false, "Dispatch failed") }
    settle()
}

func run(_ title: String) {
    guard let e = entries.first(where: { $0.name == title || $0.name.hasSuffix(" › " + title) }) else {
        check(false, "Menu missing: " + title); return
    }
    invoke(e)
}

func walkthrough() {
    makeFixture()
    base = delegate.windows.first!
    base.open(urls: [fixture])
    doc = base.current!
    focus()
    settle(0.5)
    inventory(app.mainMenu!, [])
    log("Discovered \(entries.count) menu entries. File pickers and Print exercise opening and cancellation. Navigation and excerpt dialogs accept fixture values. Screenshots capture the test window only.")
    shot("Opening document")
    // Compare needs two open documents; it runs after From Clipboard below.
    for e in entries where e.name.hasPrefix("View ›") && e.item.action != #selector(MainWindowController.compareDocuments(_:)) {
        invoke(e)
        if e.item.action == #selector(MainWindowController.setLayoutAction(_:)) { check(doc.layout.rawValue == e.item.tag, "Layout switched") }
        if e.item.action == #selector(MainWindowController.setReadingSplit(_:)) { check(doc.splitDirection == e.item.tag, "Split orientation") }
        if ["Vertical","Thumbnails","Annotation Summary","Convert"].contains(e.item.title) { shot(e.item.title) }
        if e.item.title == "Vertical" || doc.gridMode { settle(1.4); shot(e.item.title + " after redraw") }
        if doc.gridMode { doc.setGrid(false) }
        if e.item.action == #selector(NSWindow.toggleFullScreen(_:)) {
            settle(0.8)
            if base.window!.styleMask.contains(.fullScreen) { base.window!.toggleFullScreen(nil); settle(0.8) }
        }
    }
    let normalFrame = base.window!.frame
    base.window!.setContentSize(NSSize(width: 760, height: 520))
    doc.setGrid(true); settle(0.7); shot("Grid at minimum width")
    doc.setGrid(false); settle()
    shot("Reader at minimum width")
    let toolbar = base.toolbar
    let zoom = toolbar.zoomIn.convert(toolbar.zoomIn.bounds, to: toolbar)
    let annotate = toolbar.annotateTab.convert(toolbar.annotateTab.bounds, to: toolbar)
    let overlap = zoom.intersection(annotate)
    check(overlap.isNull || overlap.width <= 0, "Zoom In and Annotate are separate at 760 pt (overlap: \(overlap.isNull ? 0 : overlap.width) pt)")
    base.window!.setFrame(normalFrame, display: true)
    if base.altRow == .convert { base.toggleConvertTools(nil) }
    run("Rotate Current Page Right")
    let page = doc.pdfView.currentPage!
    let rotation = page.rotation
    run("Undo"); check(page.rotation != rotation, "Undo rotation")
    run("Redo"); check(page.rotation == rotation, "Redo rotation")
    run("Rotate Current Page Left"); run("Add Bookmark")
    run("First Page"); run("Next Page"); run("Last Page"); check(doc.currentPageIndex == 5, "Reached page six")
    run("Previous Page"); run("Up"); run("Down")
    doc.jump(toPage: 0); doc.jump(toPage: 3)
    run("Back"); run("Forward")
    run("Set Printed Page Number…"); run("Go to Page…")
    focus()
    for e in entries where e.name.hasPrefix("Annotate ›") {
        if ["Highlight","Underline","Strikeout"].contains(e.item.title) {
            let first = doc.document.page(at: 0)!
            doc.pdfView.setCurrentSelection(first.selection(for: NSRange(location: 0, length: 11)), animate: false)
        }
        invoke(e)
        if ["Underline","Pen","Signature","Purple"].contains(e.item.title) { shot(e.item.title) }
    }
    base.selectToolAction(nil)
    run("Find…")
    base.toolbar.searchField.stringValue = "Sample"
    base.toolbar.searchField.currentEditor()?.selectAll(nil)
    for title in ["Select All","Copy","Cut"] { run(title) }
    // Cutting the entire query can close the search field. Refocus it for Paste.
    run("Find…")
    board.clearContents(); board.setString("Sample", forType: .string)
    run("Paste")
    check(base.toolbar.searchField.stringValue.contains("Sample"), "Pasted text into the search field")
    let first = doc.document.page(at: 0)!
    doc.pdfView.setCurrentSelection(first.selection(for: NSRange(location: 0, length: 11)), animate: false)
    run("Use Selection for Find")
    let deadline = Date().addingTimeInterval(5)
    while base.searchPanel.isSearching && Date() < deadline { settle(0.05) }
    check(!base.searchPanel.hits.isEmpty, "Search returned fixture text")
    run("Find Next"); run("Find Previous"); shot("Search results"); base.closeSearch()
    run("Save"); check(!doc.isDirty, "Saved fixture")
    run("Copy as Markdown"); check(board.string(forType: .string)?.isEmpty == false, "Markdown on test pasteboard")
    for title in ["Save As…","Save Copy Without Annotations…","Word Document (.docx)…","Save as Markdown…","Merge Files…","Open…","From Page Range…","Print…"] { run(title) }
    // Document commands from Fill & Sign / Scan & OCR need the fixture open; later steps close it.
    for title in ["Save as Flattened…","Reduce File Size…","Text…","Rich Text Format…","HTML…","Image (PNG per page)…",
                  "Set Password…","Properties…","Recognize Text"] { focus(); run(title) }
    focus()
    focus()
    doc.sidebar.thumbnails.table.selectRowIndexes([0,1], byExtendingSelection: false)
    run("From Selected Pages"); check(base.current?.pageCount == 2, "Created two-page excerpt")
    focus()
    board.clearContents(); board.setData(try! Data(contentsOf: fixture), forType: .pdf)
    run("From Clipboard"); check(base.current !== doc && base.current?.pageCount == 6, "Created clipboard PDF")
    focus()
    run("Compare Open Documents…"); focus()
    run("New Tab"); run("Go to Previous Tab"); run("Go to Next Tab"); run("Close Tab")
    focus(); run("Move Tab to New Window")
    check(delegate.windows.count == 2 && delegate.main?.current === doc, "Detached document owns the key window")
    if let owner = doc.main { base = owner }
    focus(); shot("Detached document")
    run("New Window"); run("Close Window"); focus()
    base.newHomeTab(nil); focus(); run("Close Other Tabs")
    run("Show in Finder"); focus()
    for e in entries where e.name.contains("Open Recent ›") { invoke(e) }
    focus()
    run("Minimize"); base.window?.deminiaturize(nil); focus()
    run("Zoom"); run("Bring All to Front")
    run("About PdfPuffin")
    if let about = app.keyWindow, about !== base.window { shot("About panel", about); about.close() }
    focus()
    run("Hide PdfPuffin"); app.unhide(nil); focus()
    let previouslyHidden = NSWorkspace.shared.runningApplications.filter(\.isHidden)
    run("Hide Others"); run("Show All")
    for process in previouslyHidden where !process.isHidden { process.hide() }
    focus()
    // AppKit can add window-list entries. Exercise them before quitting as well.
    let quit = entries.first { $0.item.action == #selector(NSApplication.terminate(_:)) }!
    shot("End of walkthrough")
    // Bring the document back in front first: a cancelled save panel leaves no key window.
    for e in entries where !used.contains(e.name) && e.name != quit.name && e.item.title != "Close All" { focus(); settle(0.1); invoke(e) }
    if let closeAll = entries.first(where: { $0.item.title == "Close All" }) { invoke(closeAll) }
    log("- Disabled macOS services: \(unavailable.count)")
    log("\nAttempted \(used.count) of \(entries.count) entries before Quit; dispatched \(completed.count).")
    for e in entries where !used.contains(e.name) && e.name != quit.name { log("- Not attempted: " + e.name) }
    // Report any remaining fixture prompts before the real Quit action.
    for controller in delegate.windows {
        for tab in controller.documentControllers where tab.isDirty && tab.fileURL == nil {
            // The test dismisses the normal unsaved-changes prompt in invoke().
            log("- Quit will prompt for \(tab.displayName)")
        }
    }
    invoke(quit)
    check(false, "Quit returned without terminating")
    exit(1)
}
let ending = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: app, queue: .main) { _ in
    check(used.count == entries.count, "All discovered menu entries attempted")
    log("\nWalkthrough complete (Quit delivered willTerminate).")
    board.releaseGlobally()
}
let launched = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: app, queue: .main) { _ in
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in walkthrough() }
}
app.run()
