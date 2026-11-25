import AppKit
import PDFKit
let app = NSApplication.shared
// Run with scripts/test-excerpts.sh. All writes go to the temporary fixture.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let url = root.appendingPathComponent("Goldberg.pdf")
let link = root.appendingPathComponent("Goldberg link.pdf")
try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
let controller = MainWindowController()
controller.open(urls: [url, link])
precondition(controller.documentControllers.count == 1)
let doc = controller.current!
let originalCount = doc.pageCount
precondition(originalCount >= 66, "The supplied PDF needs at least 66 pages")
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
print("Pages:", originalCount)
let page = doc.document.page(at: 40)!
doc.pdfView.go(to: page)
let content = page.string! as NSString
let selection = page.selection(for: NSRange(location: 0, length: min(content.length,400)))!
doc.pdfView.setCurrentSelection(selection, animate: false)
let base = page.annotations.count
doc.applyMarkup(.highlight)
let marked = page.annotations.count
precondition(marked > base + 1 && doc.isDirty)
let history = controller.window!.undoManager!
precondition(history === doc.editHistory)
history.undo()
precondition(page.annotations.count == base && !doc.isDirty)
history.redo()
precondition(page.annotations.count == marked && doc.isDirty)
for pages in [IndexSet(integersIn: 40..<50), IndexSet([2,40,65])] {
    precondition(doc.writeExcerpt(pages, to: board))
    let output = Clipboard.document(from: board)!
    let name = Clipboard.suggestedName(from: board)
    precondition(name == (pages.count == 10 ? "Goldberg (pages 41–50)" : "Goldberg (pages 3, 41, 66)"))
    let dest = root.appendingPathComponent(name + ".pdf")
    precondition(output.write(to: dest))
    let reopened = PDFDocument(url: dest)!
    precondition(reopened.pageCount == pages.count)
    for (i, source) in pages.enumerated() {
        let copy = reopened.page(at: i)!
        // PDFKit can normalize whitespace, small caps and discretionary hyphens on write.
        let words = (doc.document.page(at: source)!.string ?? "").lowercased()
            .split { !$0.isLetter }.filter { $0.count > 3 }
        let text = (copy.string ?? "").lowercased()
        if text.contains("excerpt fixture") { precondition(text.contains("page \(source + 1),")) }
        let sample = words.indices.filter { $0 % 7 == 0 }.map { words[$0] }
        precondition(!sample.isEmpty && sample.filter { text.contains($0) }.count * 100 >= sample.count * 90)
        if source == 40 { precondition(copy.annotations.count == marked) }
    }
    print("Reopened and verified:", name)
}
let note = PDFAnnotation(bounds: NSRect(x: 10,y: 10,width: 24,height: 24), forType: .text, withProperties: nil)
doc.addAnnotations([(page,note)],name:"Add Note")
history.undo(); precondition(!page.annotations.contains { $0 === note })
history.redo(); precondition(page.annotations.contains { $0 === note })
let rotatedPage = doc.pdfView.currentPage!
let rotation = rotatedPage.rotation
doc.rotateCurrentPage(by: 90)
history.undo(); precondition(rotatedPage.rotation == rotation)
history.redo(); precondition(rotatedPage.rotation == (rotation + 90) % 360)
doc.append(pages: doc.copies(of: [2,5]))
precondition(doc.pageCount == originalCount + 2)
history.undo(); precondition(doc.pageCount == originalCount)
history.redo(); precondition(doc.pageCount == originalCount + 2)
precondition(doc.save(forceAsk:false) && !doc.isDirty)
history.undo(); precondition(doc.isDirty && doc.pageCount == originalCount)
history.redo(); precondition(!doc.isDirty && doc.pageCount == originalCount + 2)
print("PASS: open identity, undo/redo for markup, notes, rotation and append, save checkpoint")

let numbers = PageNumbers(labels: ["i", "ii", "310", "311", "312", "A-1", "A-2"])
precondition(numbers.pages("310–312, A-2", printed: true) == IndexSet([2,3,4,6]))
precondition(numbers.pages("ii", printed: true, single: true) == [1])
precondition(numbers.pages("A-1-A-2", printed: true) == [5,6])
precondition(numbers.pages("1-3, 2,7", printed: false) == [0,1,2,6])
for invalid in ["", "0", "1,", "2-1", "9", "1--2"] {
    precondition(numbers.pages(invalid, printed: false) == nil)
}
precondition(PageNumbers(labels: ["1", "1"]).pages("1", printed: true) == nil)
doc.setPrintedOffset(299)
precondition(doc.printedLabel(at: 10) == "310")
let fresh = DocumentViewController(document: PDFDocument(url: url)!, url: url)
precondition(fresh.printedLabel(at: 10) == "310")
let dialog = PageRangeDialog(doc: doc, single: false)
dialog.mode.selectedSegment = 1
dialog.field.stringValue = "310–319"
dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
precondition(dialog.selected == IndexSet(integersIn: 10..<20))
precondition(dialog.first.image != nil && dialog.last.image != nil)
precondition(doc.excerptName(for: dialog.selected!, printed: dialog.usesPrintedPages) == "Goldberg (pages 310–319)")
dialog.field.stringValue = "9999999"
dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
precondition(!dialog.alert.buttons[0].isEnabled && dialog.selected == nil)
doc.setPrintedOffset(nil)
let pagesBefore = (0..<doc.pageCount).map { doc.document.page(at: $0)! }
doc.bookmarks = [2, 7]
precondition(doc.changePages([2,5], before: 9))
precondition(doc.document.page(at: 7) === pagesBefore[2] && doc.document.page(at: 8) === pagesBefore[5])
precondition(doc.bookmarks.contains(7))
history.undo()
precondition(doc.document.page(at: 2) === pagesBefore[2] && doc.bookmarks == [2,7])
history.redo()
precondition(doc.changePages([7,8], before: nil))
precondition(doc.pageCount == pagesBefore.count - 2)
history.undo()
precondition(doc.pageCount == pagesBefore.count && doc.document.page(at: 7) === pagesBefore[2])
precondition(doc.bookmarks.contains(7))
history.redo()
precondition(!doc.changePages(IndexSet(integersIn: 0..<doc.pageCount), before: nil))
precondition(doc.save(forceAsk: false))
let finalPDF = PDFDocument(url: url)!
precondition(finalPDF.pageCount == pagesBefore.count - 2)
print("PASS: physical and printed ranges, persisted offset, page move/remove, bookmarks, undo/redo, saved edits")

func makeSection(_ indices: IndexSet, name: String) -> PacketSection {
    let section = PDFDocument()
    for page in doc.copies(of: indices) { section.insert(page, at: section.pageCount) }
    return PacketSection(section, name: name)
}

let problem = makeSection([7], name: "Problem")
var reading = makeSection([1,4,6], name: "Goldberg excerpt")
reading.title = "Assigned reading"
let opinion = makeSection([8,12], name: "Opinion")
let teacher = reading.document.page(at: 0)!
let originalAnnotations = teacher.annotations.count
let annotations: [PDFAnnotationSubtype] = [.text, .highlight, .freeText, .ink]
for type in annotations {
    let annotation = PDFAnnotation(bounds: NSRect(x: 20, y: 20, width: 60, height: 20), forType: type, withProperties: nil)
    annotation.contents = "Instructor note for test"
    teacher.addAnnotation(annotation)
}
let teacherCount = teacher.annotations.count
precondition(teacherCount >= originalAnnotations + annotations.count)
let sources = [problem, reading, opinion]
let packet = try ReadingPacket.merge(sources)
let packetURL = root.appendingPathComponent("Class packet.pdf")
let studentURL = root.appendingPathComponent("Student packet.pdf")
precondition(packet.write(to: packetURL))
let beforeExport = try Data(contentsOf: packetURL)
func verifyPacket(_ pdf: PDFDocument) {
    precondition(pdf.pageCount == 6 && pdf.outlineRoot?.numberOfChildren == 3)
    var start = 0
    for (i, source) in sources.enumerated() {
        let outline = pdf.outlineRoot!.child(at: i)!
        precondition(outline.label == source.title && pdf.index(for: outline.destination!.page!) == start)
        for offset in 0..<source.document.pageCount {
            let expected = source.document.page(at: offset)!.string ?? ""
            let actual = pdf.page(at: start + offset)!.string ?? ""
            let words = expected.lowercased().split { !$0.isLetter }.filter { $0.count > 4 }
            precondition(!words.isEmpty && words.filter { actual.lowercased().contains($0) }.count * 100 >= words.count * 90)
            if actual.contains("Excerpt fixture") {
                precondition(expected.split(separator: ",").first == actual.split(separator: ",").first)
            }
        }
        start += source.document.pageCount
    }
}
let savedPacket = PDFDocument(url: packetURL)!
verifyPacket(savedPacket)
precondition(savedPacket.page(at: 1)!.annotations.contains { $0.contents == "Instructor note for test" })
let unsaved = PDFAnnotation(bounds: NSRect(x: 30,y: 30,width: 24,height: 24), forType: .text, withProperties: nil)
savedPacket.page(at: 5)!.addAnnotation(unsaved)
try ReadingPacket.writeCleanCopy(of: savedPacket, to: studentURL, protecting: [packetURL])
let cleanPacket = PDFDocument(url: studentURL)!
verifyPacket(cleanPacket)
precondition((0..<cleanPacket.pageCount).allSatisfy { cleanPacket.page(at: $0)!.annotations.isEmpty })
precondition(savedPacket.page(at: 5)!.annotations.contains { $0 === unsaved })
precondition(teacher.annotations.count == teacherCount && reading.document.pageCount == 3)
let alias = root.appendingPathComponent("packet alias.pdf")
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: packetURL)
do {
    try ReadingPacket.writeCleanCopy(of: savedPacket, to: alias, protecting: [])
    preconditionFailure("Source alias accepted")
} catch PacketError.destinationInUse {}
do {
    try ReadingPacket.writeCleanCopy(of: savedPacket, to: url, protecting: [url])
    preconditionFailure("Another open source accepted")
} catch PacketError.destinationInUse {}
let afterExport = try Data(contentsOf: packetURL)
precondition(afterExport == beforeExport)
print("PASS: ordered packet, custom titles, saved outline destinations, clean copy, source and alias protection")

controller.window!.contentView!.layoutSubtreeIfNeeded()
let mainPane = doc.pdfView
doc.setReadingSplit(2)
precondition(doc.splitDirection == 2 && doc.readingPanes.count == 2)
let second = doc.readingPanes.first { $0 !== mainPane }!
precondition(second.document === doc.document)
mainPane.autoScales = false
mainPane.scaleFactor = 1
mainPane.go(to: doc.document.page(at: 3)!)
doc.activatePane(second)
second.autoScales = false
second.scaleFactor = 1.5
doc.jump(toPage: 60)
precondition(second.currentPage === doc.document.page(at: 60) && mainPane.currentPage === doc.document.page(at: 3))
precondition(mainPane.scaleFactor == 1 && second.scaleFactor == 1.5)
doc.setReadingSplit(1)
precondition(doc.splitDirection == 1 && doc.readingPanes.contains(mainPane))
doc.setReadingSplit(0)
precondition(doc.readingPanes.count == 1 && doc.pdfView === second && doc.currentPageIndex == 60)
doc.setReadingSplit(2)
precondition(doc.readingPanes.count == 2)
doc.setReadingSplit(0)

let notesDoc = DocumentViewController(document: PDFDocument(), url: nil, name: "Course notes")
for i in [1,2] {
    let copied = doc.document.page(at: i)!.copy() as! PDFPage
    for a in copied.annotations { copied.removeAnnotation(a) }
    notesDoc.document.insert(copied, at: notesDoc.pageCount)
}
_ = notesDoc.view
notesDoc.setPrintedOffset(299)
let notesBoard = NSPasteboard.withUniqueName()
defer { notesBoard.releaseGlobally() }
notesBoard.setString("existing", forType: .string)
precondition(!ReadingNotes.copy(from: notesDoc, to: notesBoard) && notesBoard.string(forType: .string) == "existing")
let notesPage = notesDoc.document.page(at: 0)!
let markedText = notesPage.selection(for: NSRange(location: 0, length: min(180, (notesPage.string! as NSString).length)))!.selectionsByLine().first!
let marker = PDFAnnotation(bounds: markedText.bounds(for: notesPage), forType: .highlight, withProperties: nil)
marker.contents = "Discuss reliance in class."
notesPage.addAnnotation(marker)
let memo = PDFAnnotation(bounds: NSRect(x: 20,y: 40,width: 24,height: 24), forType: .text, withProperties: nil)
memo.contents = "Compare *both* rules."
notesDoc.document.page(at: 1)!.addAnnotation(memo)
let markdown = ReadingNotes.markdown(from: notesDoc)!
precondition(markdown.contains("## Page 300 (PDF page 1)") && markdown.contains("## Page 301 (PDF page 2)"))
precondition(markdown.contains("> ") && markdown.contains("Discuss reliance in class.") && markdown.contains("Compare \\*both\\* rules."))
precondition(ReadingNotes.copy(from: notesDoc, to: notesBoard) && notesBoard.string(forType: .string) == markdown)
let notesFile = root.appendingPathComponent("notes.md")
try markdown.write(to: notesFile, atomically: true, encoding: .utf8)
let savedNotes = try String(contentsOf: notesFile, encoding: .utf8)
precondition(savedNotes == markdown)
print("PASS: split orientation, independent pages/zoom, active-pane retention, printed-page Markdown, quotes, comments, copy and save")

// A thumbnail queued before a live edit must retain its own annotation state.
let snapshot = thumbnailSnapshot(of: notesPage)!
let snapshotPage = snapshot
let priorCount = snapshotPage.annotations.count
notesPage.removeAnnotation(marker)
precondition(snapshotPage.annotations.count == priorCount)
precondition(snapshotPage.annotations.contains { $0.contents == "Discuss reliance in class." })
precondition(snapshotPage.thumbnail(of: NSSize(width: 150, height: 200), for: .cropBox).isValid)

// Saving via a relative symlink must update the original PDF and preserve the link.
let realURL = root.appendingPathComponent("save-target.pdf")
let linkURL = root.appendingPathComponent("save-link.pdf")
precondition(notesDoc.document.write(to: realURL))
try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: realURL.lastPathComponent)
let linked = DocumentViewController(document: PDFDocument(url: linkURL)!, url: linkURL)
let extra = PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
extra.contents = "Saved through the link"
linked.document.page(at: 0)!.addAnnotation(extra)
precondition(linked.save(forceAsk: false))
let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
precondition(linkTarget == realURL.lastPathComponent)
precondition(PDFDocument(url: realURL)!.page(at: 0)!.annotations.contains { $0.contents == extra.contents })
print("PASS: thumbnail snapshot isolation and saving through a symlink")

func verifyReadingTool(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() {
        FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8))
        exit(1)
    }
}

let cropDoc = DocumentViewController(document: PDFDocument(url: url)!, url: nil, name: "Crop fixture")
controller.addDocumentTab(cropDoc)
let cropPage = cropDoc.document.page(at: 0)!
let rotated = cropDoc.document.page(at: 2)!
rotated.rotation = 90
let before = CGRect(x: 10, y: 20, width: 400, height: 600)
cropPage.setBounds(before, for: .cropBox)
rotated.setBounds(before, for: .cropBox)
let untouched = cropDoc.document.page(at: 1)!.bounds(for: .cropBox)
let retained = CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
cropDoc.cropPages([0, 2], keeping: retained)
let expected = CGRect(x: 60, y: 170, width: 200, height: 300)
verifyReadingTool(cropPage.bounds(for: .cropBox) == expected, "selected crop")
verifyReadingTool(rotated.bounds(for: .cropBox) == CGRect(x: 110, y: 95, width: 200, height: 300), "rotated crop")
verifyReadingTool(cropDoc.document.page(at: 1)!.bounds(for: .cropBox) == untouched, "unselected page")
cropDoc.editHistory.undo()
verifyReadingTool([cropPage, rotated].allSatisfy { $0.bounds(for: .cropBox) == before }, "batch undo")
cropDoc.editHistory.redo()
let reopenedCrop = cropDoc.document.dataRepresentation().flatMap { PDFDocument(data: $0) }
verifyReadingTool(reopenedCrop?.page(at: 0)?.bounds(for: .cropBox) == expected, "persisted crop")
let cropUI = CropDialog(cropDoc)
cropUI.scope.selectItem(at: 0)
verifyReadingTool(cropUI.pages == [cropDoc.currentPageIndex], "current page scope")
cropUI.scope.selectItem(at: 2)
verifyReadingTool(cropUI.pages.count == cropDoc.pageCount, "all pages scope")

let compare = DocumentComparison(tabs: [doc, cropDoc], current: doc)
let left = compare.panes[0], right = compare.panes[1]
verifyReadingTool(left.picker.indexOfSelectedItem == 0 && right.picker.indexOfSelectedItem == 1, "comparison sources")
verifyReadingTool(right.pdf.document?.page(at: 0)?.bounds(for: .cropBox) == expected, "unsaved tab crop in comparison")
compare.window.contentView?.layoutSubtreeIfNeeded()
left.pdf.layoutDocumentView()
right.pdf.layoutDocumentView()
left.pdf.scaleFactor = 1.1
right.pdf.scaleFactor = 0.9
compare.sync.state = .on
compare.toggleSync()
left.pdf.scaleFactor = 1.25
verifyReadingTool(abs(right.pdf.scaleFactor - 1.25) < 0.001, "linked zoom")
guard let firstClip = left.clip, let secondClip = right.clip else { exit(1) }
let oldY = secondClip.bounds.minY
let step: CGFloat = firstClip.bounds.minY > 80 ? -40 : 40
firstClip.scroll(to: firstClip.bounds.origin.applying(CGAffineTransform(translationX: 0, y: step)))
verifyReadingTool(abs(secondClip.bounds.minY - oldY - step) < 1, "linked scroll delta")
compare.swapSides()
verifyReadingTool(compare.split.arrangedSubviews.first === right, "swap sides")
compare.sync.state = .off
compare.toggleSync()
right.pdf.scaleFactor = 1.55
verifyReadingTool(abs(left.pdf.scaleFactor - 1.25) < 0.001, "independent zoom")
print("PASS: batch crop, rotated pages, saved crop, undo/redo, comparison sources, linked scroll and zoom, swap and unlink")

controller.window?.orderFront(nil)
controller.window?.contentView?.layoutSubtreeIfNeeded()
controller.toolbar.layoutButton.performClick(nil)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let controls = NSApp.windows.compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSSegmentedControl }
guard let splitControl = controls.first(where: { $0.segmentCount == 3 && $0.label(forSegment: 0) == "No Split" }),
      let layoutControl = controls.first(where: { $0.segmentCount == 3 && $0.label(forSegment: 0) == "Single Page" })
else { verifyReadingTool(false, "View Settings popover"); exit(1) }
layoutControl.selectedSegment = 1
layoutControl.sendAction(layoutControl.action, to: layoutControl.target)
splitControl.selectedSegment = 2
splitControl.sendAction(splitControl.action, to: splitControl.target)
verifyReadingTool(cropDoc.layout == .two && cropDoc.splitDirection == 2, "View Settings actions")
controller.toolbar.showSettings()

let previewWindow = cropUI.alert.window
previewWindow.contentView?.layoutSubtreeIfNeeded()
let preview = cropUI.preview
func cropEvent(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: preview.convert(CGPoint(x: x, y: y), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: previewWindow.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1)!
}
preview.mouseDown(with: cropEvent(.leftMouseDown, 175, 130))
preview.mouseDragged(with: cropEvent(.leftMouseDragged, 235, 210))
preview.mouseUp(with: cropEvent(.leftMouseUp, 235, 210))
verifyReadingTool(preview.retained != nil && cropUI.alert.buttons[0].isEnabled, "draw crop in preview")
print("PASS: toolbar popover, layout and split actions, drawing the crop preview")

let toolbar = controller.toolbar
let testWindow = controller.window!
for width in [1360, 900, 800, 760, 1360] {
    testWindow.setContentSize(NSSize(width: width, height: 700))
    testWindow.contentView?.layoutSubtreeIfNeeded()
    func frame(_ control: NSView) -> CGRect { control.convert(control.bounds, to: toolbar) }
    let buttons = [toolbar.sidebarButton, toolbar.gridButton, toolbar.layoutButton, toolbar.zoomButton,
                   toolbar.zoomOut, toolbar.zoomIn, toolbar.annotateTab, toolbar.convertTab, toolbar.searchField] as [NSView]
    for (a, b) in zip(buttons, buttons.dropFirst()) {
        verifyReadingTool(a.window === testWindow && b.window === testWindow && frame(a).maxX <= frame(b).minX + 0.5,
                          "toolbar controls overlap or detached at width " + String(width))
    }
    verifyReadingTool(frame(toolbar.zoomIn).maxX + 9 <= frame(toolbar.annotateTab).minX, "zoom and mode tab gap")
    verifyReadingTool(frame(toolbar.searchField).width >= 120, "search field remains usable")
}
print("PASS: toolbar controls stay visible and separate from 760 through 1360 points")
