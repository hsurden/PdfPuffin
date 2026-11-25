import AppKit
import PDFKit
let app = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)
// Run with scripts/test-quick-wins.sh: the PDF Expert menu features added together
// (new documents, blank page, clear form, remove all, double arrow, custom colour,
// summary export, themes, hide tools, split-view documents, Pan & Zoom, iPhone import).
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
func settle(_ t: Double = 0.2) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

func makePDF(_ name: String, pages: Int, text: String = "Reliance damages protect the promisee.") -> URL {
    let url = root.appendingPathComponent(name)
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &media, nil)!
    for i in 0..<pages {
        ctx.beginPDFPage(nil)
        let s = NSAttributedString(string: "\(text) Page \(i + 1).", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

// Menus: every new item is where PDF Expert has it.
let delegate = AppDelegate()
app.delegate = delegate
delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
func menuPath(_ path: [String]) -> NSMenuItem? {
    var menu = app.mainMenu
    var found: NSMenuItem?
    for title in path {
        found = menu?.items.first { $0.title == title }
        menu = found?.submenu
    }
    return found
}
for path in [["File", "New", "Empty Document"], ["File", "New", "From Images…"], ["File", "New", "From File…"],
             ["File", "Import from iPhone or iPad"], ["File", "Share"],
             ["File", "Export Annotation Summary", "Save as Text…"], ["File", "Export Annotation Summary", "Save as HTML…"],
             ["Edit", "Insert Blank Page"], ["Edit", "Clear Form"], ["Edit", "Remove All Annotations"],
             ["View", "Theme", "Night"], ["View", "Hide Tools"], ["View", "Always Show Toolbar"],
             ["View", "Zoom", "Pan & Zoom"], ["View", "Split View", "Change Left/Top Document"],
             ["Annotate", "Double Arrow"], ["Annotate", "Color", "Custom…"]] {
    check(menuPath(path) != nil, "menu " + path.joined(separator: " ▸ "))
}
check(menuPath(["File", "Import from iPhone or iPad"])?.identifier == NSMenuItem.importFromDeviceIdentifier,
      "iPhone import uses Continuity Camera")

let win = MainWindowController(initialHome: true)
win.showWindow(nil)
settle()

// New ▸ Empty Document: one Letter page, unsaved.
win.newEmptyDocument(nil)
check(win.current?.pageCount == 1 && win.current?.document.page(at: 0)?.bounds(for: .mediaBox).size == NSSize(width: 612, height: 792)
      && win.current?.isDirty == true, "empty document is one unsaved Letter page")

// New ▸ From File / From Images combine PDFs and images in order.
let two = makePDF("two.pdf", pages: 2)
let png = root.appendingPathComponent("pic.png")
let img = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: png)
check(Clipboard.document(fromFiles: [two, png])?.pageCount == 3, "From File: 2 PDF pages + 1 image page")

// iPhone / iPad import: the window asks for images, and a returned photo becomes a document.
check((win.validRequestor(forSendType: nil, returnType: .png) as AnyObject?) === win, "accepts images from a device")
let board = NSPasteboard.withUniqueName()
board.clearContents()
board.writeObjects([img])
let before = win.documentControllers.count
check(win.readSelection(from: board) && win.documentControllers.count == before + 1, "imported photo opens as a new document")

// Open a real file for the editing checks.
win.open(urls: [makePDF("notes.pdf", pages: 3)])
settle()
let d = win.current!
check(d.pageCount == 3, "fixture open")

// Edit ▸ Insert Blank Page, with Undo.
d.jump(toPage: 0); settle()
d.insertBlankPageAfterCurrent()
check(d.pageCount == 4 && (d.document.page(at: 1)?.string ?? "").isEmpty, "blank page inserted after the current page")
d.editHistory.undo()
check(d.pageCount == 3, "undo removes the blank page")

// Annotate ▸ Double Arrow: arrowheads at both ends, and the inspector knows it.
let page0 = d.document.page(at: 0)!
let arrow = PuffinPDFView.makeAnnotation(.doubleArrow, from: NSPoint(x: 100, y: 100), to: NSPoint(x: 300, y: 200), points: [], page: page0)
check(arrow.startLineStyle == .openArrow && arrow.endLineStyle == .openArrow, "double arrow has two heads")
check(ToolInspector.inspectorKey(for: arrow) == "doubleArrow", "inspector edits it as a double arrow")
let single = PuffinPDFView.makeAnnotation(.arrow, from: NSPoint(x: 100, y: 100), to: NSPoint(x: 300, y: 200), points: [], page: page0)
check(single.startLineStyle == PDFLineStyle.none && single.endLineStyle == .openArrow, "single arrow unchanged")

// Annotate ▸ Color ▸ Custom…: a tool keeps its own custom colour.
let teal = NSColor(srgbRed: 0.1, green: 0.6, blue: 0.6, alpha: 1)
AnnotColors.setCustom(teal, for: "pen")
check(AnnotColors.index(for: "pen") == AnnotColors.customIndex && AnnotColors.color(for: "pen").isClose(to: teal), "custom colour stored per tool")
AnnotColors.set(0, for: "pen")
check(AnnotColors.color(for: "pen").isClose(to: AnnotColors.palette[0].1), "palette colour still works after a custom one")

// Edit ▸ Remove All Annotations: markup and notes go, links stay, one Undo restores.
let line = page0.selection(for: NSRange(location: 0, length: 8))!
d.pdfView.setCurrentSelection(line, animate: false)
d.applyMarkup(.highlight)
let note = PDFAnnotation(bounds: NSRect(x: 400, y: 600, width: 24, height: 24), forType: .text, withProperties: nil)
note.contents = "Ask about reliance"
d.addAnnotations([(page0, note)], name: "Add Note")
let link = PDFAnnotation(bounds: NSRect(x: 72, y: 50, width: 100, height: 20), forType: .link, withProperties: nil)
link.url = URL(string: "https://example.com")
page0.addAnnotation(link)
check(d.removeAllAnnotations() == 2, "removed the highlight and the note")
check(page0.annotations.count == 1 && page0.annotations.first?.type == "Link", "the link stays")
d.editHistory.undo()
let restored = Set(page0.annotations.compactMap(\.type))   // PDFKit gives a note its own Popup
check(restored.isSuperset(of: ["Link", "Highlight", "Text"]), "undo brings both back")

// Export Annotation Summary as Text and HTML.
let text = ReadingNotes.plainText(from: d) ?? ""
check(text.contains("PAGE 1") && text.contains("Reliance") && text.contains("Ask about reliance"), "text summary has quote and note")
let html = ReadingNotes.html(from: d) ?? ""
check(html.contains("<blockquote>Reliance") && html.contains("<p>Ask about reliance</p>") && html.hasPrefix("<!DOCTYPE html>"), "HTML summary has quote and note")
check(ReadingNotes.markdown(from: d)?.contains("> Reliance") == true, "Markdown unchanged")

// Edit ▸ Clear Form: text fields empty, checkboxes off, Undo restores.
let field = PDFAnnotation(bounds: NSRect(x: 72, y: 400, width: 200, height: 22), forType: .widget, withProperties: nil)
field.widgetFieldType = .text
field.widgetStringValue = "Jane Doe"
let box = PDFAnnotation(bounds: NSRect(x: 72, y: 360, width: 18, height: 18), forType: .widget, withProperties: nil)
box.widgetFieldType = .button
box.widgetControlType = .checkBoxControl
box.buttonWidgetState = .onState
page0.addAnnotation(field); page0.addAnnotation(box)
check(d.hasFilledForm, "form has entries")
d.clearForm()
check((field.widgetStringValue ?? "").isEmpty && box.buttonWidgetState == .offState, "form cleared")
d.editHistory.undo()
check(field.widgetStringValue == "Jane Doe" && box.buttonWidgetState == .onState, "undo restores the entries")
check(d.userAnnotations.allSatisfy { $0.1.type != "Widget" }, "Remove All leaves form fields alone")

// View ▸ Theme: filters on the page area only.
PageTheme.current = .night; settle()
check(d.pdfView.documentView?.contentFilters.count == 3, "night theme filters the pages")
PageTheme.current = .sepia; settle()
check(d.pdfView.documentView?.contentFilters.count == 1, "sepia theme")
PageTheme.current = .day; settle()
check(d.pdfView.documentView?.contentFilters.isEmpty == true, "day theme clears the filters")

// View ▸ Hide Tools / Show Tools.
win.toolsShown = true
win.hideToolsAction(nil)
check(!win.toolsShown, "Hide Tools hides the tool row")
win.hideToolsAction(nil)
check(win.toolsShown, "Show Tools brings it back")

// View ▸ Always Show Toolbar: on by default; off only matters in full screen.
check(MainWindowController.alwaysShowToolbar, "Always Show Toolbar is on by default")
MainWindowController.alwaysShowToolbar = false
win.updateFullScreenChrome()
check(!win.chromeTucked, "toolbar stays put outside full screen")
MainWindowController.alwaysShowToolbar = true

// View ▸ Split View ▸ Change Left/Top Document opens Compare with that document.
win.open(urls: [makePDF("other.pdf", pages: 1, text: "Expectation damages.")])
settle()
win.select(controller: d)
let leftMenu = NSMenu()
win.fillDocumentMenu(leftMenu, side: 0)
check(leftMenu.items.count == win.documentControllers.count, "document menu lists every open document")
let pick = leftMenu.items.first { $0.title == "other" }!
win.compareChosen(pick)
settle(0.4)
check(win.window?.attachedSheet != nil, "compare sheet opened with the chosen document")
if let sheet = win.window?.attachedSheet { win.window?.endSheet(sheet) }
settle()

// View ▸ Zoom ▸ Pan & Zoom.
PanZoomPanel.toggle()
settle(0.4)
check(PanZoomPanel.isShown, "Pan & Zoom panel shows")
PanZoomPanel.toggle()
check(!PanZoomPanel.isShown, "and hides again")

print("All passed")
exit(0)
