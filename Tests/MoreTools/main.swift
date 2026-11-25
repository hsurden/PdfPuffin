import AppKit
import PDFKit
let app = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)
// Run with scripts/test-more-tools.sh: Split into Files, watermarks, blank pages,
// images inside a PDF, Remove Password, permissions, per-document zoom, and ↑/↓
// through the annotation list. (Speech is not exercised: it would talk out loud.)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }
func settle(_ t: Double = 0.25) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

/// A PDF whose pages have text, except the page numbers listed in `blank`; page 2 gets a photo.
func makePDF(_ name: String, pages: Int, blank: Set<Int> = [], photoOnPage: Int? = nil) -> URL {
    let url = root.appendingPathComponent(name)
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &media, nil)!
    for i in 1...pages {
        ctx.beginPDFPage(nil)
        if !blank.contains(i) {
            let s = NSAttributedString(string: "Chapter text on page \(i).", attributes: [.font: NSFont.systemFont(ofSize: 14)])
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        if i == photoOnPage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 3,
                                       hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<40 { for y in 0..<30 { rep.setColor(NSColor(deviceRed: CGFloat(x) / 40, green: 0.5, blue: CGFloat(y) / 30, alpha: 1), atX: x, y: y) } }
            ctx.draw(rep.cgImage!, in: CGRect(x: 100, y: 300, width: 200, height: 150))
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

let delegate = AppDelegate()
app.delegate = delegate
delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
func menuPath(_ path: [String]) -> NSMenuItem? {
    var menu = app.mainMenu, found: NSMenuItem?
    for t in path { found = menu?.items.first { $0.title == t }; menu = found?.submenu }
    return found
}
for path in [["File", "Split into Files…"], ["File", "Remove Password…"], ["File", "Export To", "Images in PDF…"],
             ["Edit", "Remove Blank Pages…"], ["Edit", "Add Watermark…"], ["Edit", "Remove Watermark"],
             ["Edit", "Speech", "Start Speaking"], ["Edit", "Speech", "Stop Speaking"]] {
    check(menuPath(path) != nil, "menu " + path.joined(separator: " ▸ "))
}

// Split plans.
check(SplitPlan.every(10, pageCount: 25) == [0...9, 10...19, 20...24], "every 10 pages of 25: three files")
let numbers = PageNumbers(labels: (1...30).map(String.init))
check(SplitPlan.ranges("1-3, 5, 7–9", numbers: numbers) == [0...2, 4...4, 6...8], "page ranges, one file each")
check(SplitPlan.ranges("3-1", numbers: numbers) == nil && SplitPlan.ranges("40", numbers: numbers) == nil, "bad ranges refused")
let booked = PDFDocument(url: makePDF("book.pdf", pages: 9))!
let outline = PDFOutline()
for (k, (label, page)) in [("Part One", 2), ("Part Two", 5)].enumerated() {
    let o = PDFOutline(); o.label = label; o.destination = PDFDestination(page: booked.page(at: page)!, at: .zero)
    outline.insertChild(o, at: k)
}
booked.outlineRoot = outline
let parts = SplitPlan.bookmarks(booked)
check(parts.map(\.0) == ["Front matter", "Part One", "Part Two"] && parts.map(\.1) == [0...1, 2...4, 5...8],
      "bookmarks split at each top-level entry, with front matter first")

// Blank pages.
let withBlanks = PDFDocument(url: makePDF("blanks.pdf", pages: 5, blank: [2, 4], photoOnPage: 5))!
let blankPages = (0..<5).filter { BlankPages.isBlank(withBlanks.page(at: $0)!) }
check(blankPages == [1, 3], "finds the two blank pages, not the text or photo pages")

// Images inside a PDF.
let photoPDF = makePDF("photo.pdf", pages: 2, photoOnPage: 2)
let imageFolder = root.appendingPathComponent("images")
try! FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
let exported = PDFImages.export(try! Data(contentsOf: photoPDF), baseName: "photo", to: imageFolder)
check(exported.saved.count == 1 && exported.skipped == 0, "exports the one embedded picture (\(exported.saved.map(\.lastPathComponent)))")
check(exported.saved.first.flatMap { NSImage(contentsOf: $0) }.map { Int($0.representations[0].pixelsWide) } == 40,
      "at its original 40-pixel width")

// Open a document in a window for the editing checks.
let win = MainWindowController(initialHome: true)
win.showWindow(nil)
let readingURL = makePDF("reading.pdf", pages: 4)
win.open(urls: [readingURL])
settle(0.6)
let d = win.current!

// Watermarks: drawn, not clickable, not listed, saved, found again, removable.
let page0 = d.document.page(at: 0)!
let mark = WatermarkAnnotation.make(text: "DRAFT", image: nil, tint: .systemRed, opacity: 0.4, diagonal: true, on: page0)
d.addAnnotations([(page0, mark)], name: "Add Watermark")
check(page0.annotations.contains { $0.isWatermark }, "watermark added")
check(AnnotationSelection.hit(page0, NSPoint(x: 306, y: 396)) == nil, "a click in the middle of the page does not select the watermark")
d.sidebar.annotations.reload()
check(d.sidebar.annotations.items.allSatisfy { !$0.annotation.isWatermark }, "watermark kept out of the annotation list")
let thumb = page0.thumbnail(of: NSSize(width: 120, height: 155), for: .cropBox)
let reddish: Int = {
    let rep = NSBitmapImageRep(data: thumb.tiffRepresentation!)!
    var n = 0
    for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh { if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > c.greenComponent + 0.15 { n += 1 } } }
    return n
}()
check(reddish > 50, "watermark text is drawn on the page (\(reddish) red pixels)")
let marked = root.appendingPathComponent("marked.pdf")
check(d.document.write(to: marked), "saved with the watermark")
let reopened = PDFDocument(url: marked)!
check(reopened.page(at: 0)!.annotations.contains { $0.isWatermark }, "watermark recognised after reopening")
d.editHistory.undo()
check(!page0.annotations.contains { $0.isWatermark }, "undo removes it")
d.addAnnotations([(page0, mark)], name: "Add Watermark")
win.removeWatermark(nil)
check(!page0.annotations.contains { $0.isWatermark }, "Remove Watermark removes it")

// ↑/↓ through the annotation list after a click in it.
for (k, p) in [(0, 0), (1, 0), (2, 2)] {
    let note = PDFAnnotation(bounds: NSRect(x: 100, y: 600 - CGFloat(k) * 40, width: 24, height: 24), forType: .text, withProperties: nil)
    note.contents = "comment \(k + 1)"
    d.addAnnotations([(d.document.page(at: p)!, note)], name: "Add Note")
}
d.sidebar.annotations.reload()
d.annotationsActive = true
check(!d.thumbnailsActive, "list stepping and thumbnail stepping are exclusive")
d.sidebar.annotations.step(1)
check(d.sidebar.annotations.selectedRow == 0, "↓ starts at the first comment")
d.sidebar.annotations.step(1); settle()
check(d.sidebar.annotations.selectedRow == 1 && d.currentPageIndex == 0, "↓ goes to the second comment on the same page")
d.sidebar.annotations.step(1); settle()
check(d.sidebar.annotations.selectedRow == 2 && d.currentPageIndex == 2, "↓ goes to the comment on page 3")
d.sidebar.annotations.step(1)
check(d.sidebar.annotations.selectedRow == 2, "↓ stays on the last comment")
d.sidebar.annotations.step(-1); settle()
check(d.sidebar.annotations.selectedRow == 1 && d.currentPageIndex == 0, "↑ goes back")
let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.window!.windowNumber,
                            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
check(win.handleKeyDown(down) && d.sidebar.annotations.selectedRow == 2, "the ↓ key itself steps the list")
d.thumbnailsActive = true
check(!d.annotationsActive, "clicking a thumbnail switches ↑/↓ back to pages")

// Per-document zoom: comes back when the file is reopened.
let pct = NSMenuItem(title: "175%", action: nil, keyEquivalent: ""); pct.tag = 175
win.zoomPercentAction(pct); settle()
check(abs(d.pdfView.displayZoom - 1.75) < 0.01, "zoom set to 175%")
d.isDirty = false
win.closeTabAction(nil); settle()
win.open(urls: [readingURL]); settle(0.8)
check(abs((win.current?.pdfView.displayZoom ?? 0) - 1.75) < 0.02, "reopening the file restores 175% (\(win.current?.pdfView.displayZoom ?? 0))")

// Remove Password: an unencrypted copy with the content intact.
let protectedURL = root.appendingPathComponent("protected.pdf")
let original = PDFDocument(url: makePDF("plain.pdf", pages: 2))!
let n = PDFAnnotation(bounds: NSRect(x: 50, y: 50, width: 20, height: 20), forType: .text, withProperties: nil); n.contents = "keep"
original.page(at: 1)!.addAnnotation(n)
check(original.write(to: protectedURL, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]), "protected fixture")
let locked = PDFDocument(url: protectedURL)!
check(locked.isLocked && MainWindowController.unencryptedCopy(of: locked) == nil, "a locked file is not copied before unlocking")
_ = locked.unlock(withPassword: "pw")
let freeURL = root.appendingPathComponent("free.pdf")
check(MainWindowController.unencryptedCopy(of: locked)?.write(to: freeURL) == true, "unprotected copy written")
let free = PDFDocument(url: freeURL)!
check(!free.isEncrypted && free.pageCount == 2 && free.page(at: 1)!.annotations.contains { $0.contents == "keep" },
      "copy opens without a password and keeps pages and notes")

// Permissions.
func protect(_ name: String, open: Bool, print: Bool, copy: Bool, edit: Bool) -> PDFDocument {
    let url = root.appendingPathComponent(name)
    let opts = MainWindowController.protectionOptions(password: "secret", requireToOpen: open, printing: print, copying: copy, editing: edit)
    precondition(original.write(to: url, withOptions: opts))
    return PDFDocument(url: url)!
}
let restricted = protect("restricted.pdf", open: false, print: true, copy: false, edit: false)
check(restricted.isEncrypted && !restricted.isLocked, "restrictions only: opens without a password")
check(restricted.allowsPrinting && !restricted.allowsCopying && !restricted.allowsCommenting, "printing allowed, copying and comments blocked")
let both = protect("both.pdf", open: true, print: false, copy: true, edit: true)
check(both.isLocked && both.unlock(withPassword: "secret"), "password to open still works with restrictions")
check(!both.allowsPrinting && both.allowsCopying, "the open password does not lift the restrictions")
let plain = protect("simple.pdf", open: true, print: true, copy: true, edit: true)
check(plain.isLocked && plain.unlock(withPassword: "secret") && plain.allowsPrinting && plain.allowsCopying, "plain open password as before")

print("All passed")
exit(0)
