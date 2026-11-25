import AppKit
import PDFKit
let app = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)
// Run with scripts/test-review-fixes.sh: one check per bug from Codex's review.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }

/// A PDF with text drawn where `lines` say (one page per inner array; empty = blank page).
func makePDF(_ name: String, _ pages: [[(String, CGFloat, CGFloat)]]) -> URL {
    let url = root.appendingPathComponent(name)
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &media, nil)!
    for lines in pages {
        ctx.beginPDFPage(nil)
        for (text, x, y) in lines {
            let s = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Times New Roman", size: 11)!])
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

// [P1] Text hidden by the crop box stays out of the Word export.
do {
    // Cropped in the app (Crop Pages), not in the file: PDFKit still returns the hidden text.
    let url = makePDF("crop.pdf", [[("Body text that is visible on the page.", 100, 600), ("SIDENOTE", 560, 400),
                                    ("HEADERNOTE", 100, 770), ("FOOTERNOTE", 100, 20)]])
    let d = PDFDocument(url: url)!
    d.page(at: 0)!.setBounds(CGRect(x: 50, y: 50, width: 480, height: 690), for: .cropBox)
    let text = WordExport.attributedText(of: d).string
    check(text.contains("Body text") && !text.contains("SIDE") && !text.contains("HEADER") && !text.contains("FOOTER"),
          "crop box hides margin text from Word export")
}

// [P2] Two columns come out column by column.
do {
    var lines: [(String, CGFloat, CGFloat)] = [("A Two Column Article Title Spanning The Page Width For Testing", 72, 720)]
    for i in 1...8 {
        lines.append(("Left column sentence number \(i) carries on here", 72, 690 - CGFloat(i) * 14))
        lines.append(("Right column sentence number \(i) carries on", 320, 690 - CGFloat(i) * 14))
    }
    let d = PDFDocument(url: makePDF("columns.pdf", [lines]))!
    let text = WordExport.attributedText(of: d).string
    let lastLeft = text.range(of: "Left column sentence number 8", options: .backwards)!.lowerBound
    let firstRight = text.range(of: "Right column sentence number 1")!.lowerBound
    check(text.hasPrefix("A Two Column") && lastLeft < firstRight, "left column, then right column")
}

// [P2] A blank cover page keeps its page in the Word export.
do {
    let d = PDFDocument(url: makePDF("cover.pdf", [[], [("Page two text.", 72, 700)], [("Page three text.", 72, 700)]]))!
    let text = WordExport.attributedText(of: d).string
    check(text.filter { $0 == "\u{0C}" }.count == 2 && text.hasPrefix("\u{0C}"), "blank cover kept: 2 page breaks for 3 pages")
}

let six = makePDF("six.pdf", (1...6).map { [("Page \($0) content", 72, 700)] })
let c = MainWindowController()
c.open(urls: [six])
let doc = c.current!

// [P2] Inserting pages keeps bookmarks on their content.
do {
    doc.bookmarks = [3]
    let marked = doc.document.page(at: 3)!
    doc.insertPages([PDFPage()], at: 1, name: "Insert Blank Page")
    check(doc.bookmarks == [4] && doc.document.page(at: 4) === marked, "bookmark follows its page after insert")
    doc.editHistory.undo()
    check(doc.bookmarks == [3] && doc.document.page(at: 3) === marked, "bookmark back after undo")
    doc.editHistory.redo()
    check(doc.bookmarks == [4], "bookmark follows on redo")
    doc.editHistory.undo()
}

// [P2] Switching tabs puts down tools from the hidden row.
do {
    c.altRow = nil
    c.armTool(.eraser)
    check(doc.shapeTool == .eraser, "eraser armed")
    c.toggleConvertTools(nil)
    check(c.altRow == .convert && doc.shapeTool == nil, "Convert puts the eraser down")
    c.armTool(.pen)
    check(c.altRow == nil && doc.shapeTool == .pen, "arming the pen from Convert shows the Annotate row")
    c.toggleFillSignTools(nil)
    check(doc.shapeTool == nil, "Fill & Sign puts the pen down")
    c.armTool(.text)
    c.toggleConvertTools(nil); c.toggleFillSignTools(nil)
    c.armTool(.check)
    check(c.altRow == .fillSign && doc.shapeTool == .check, "checkmark armed in Fill & Sign")
    c.toggleAnnotateTools(nil)
    check(c.altRow == nil && doc.shapeTool == nil, "Annotate puts the checkmark down")
    c.altRow = nil
    c.armTool(.stamp)
    check(c.altRow == .fillSign, "arming the stamp shows the Fill & Sign row")
    doc.shapeTool = nil
}

// [P2] Deleting the last page in the grid leaves no stale shift-click anchor.
do {
    doc.setGrid(true)
    let g = doc.grid!
    g.clicked(5, modifiers: [], count: 1)
    c.gridDelete(nil)
    check(doc.pageCount == 5, "last page deleted")
    g.clicked(0, modifiers: .shift, count: 1)
    check(g.selection.allSatisfy { $0 < doc.pageCount }, "shift-click selects only existing pages (\(Array(g.selection)))")
    doc.setGrid(false)
}
print("All passed")
exit(0)
