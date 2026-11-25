import AppKit
import PDFKit
let app = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)
// Run with scripts/test-fill-sign-ocr.sh. Everything is written to a temporary folder.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { exit(1) } }

// 1. A "scan": text drawn into a bitmap, wrapped as an image-only PDF.
var media = CGRect(x: 0, y: 0, width: 612, height: 792)
let scanURL = root.appendingPathComponent("scan.pdf")
do {
    let img = NSImage(size: NSSize(width: 1275, height: 1650), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        let lines = ["Torts Reading Week 3", "Negligence requires duty breach causation and damages",
                     "Palsgraf v. Long Island Railroad Co."]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 150, y: 1400 - CGFloat(i) * 90),
                                    withAttributes: [.font: NSFont(name: "Times New Roman", size: 46)!])
        }
        return true
    }
    let ctx = CGContext(scanURL as CFURL, mediaBox: &media, nil)!
    ctx.beginPDFPage(nil)
    ctx.draw(img.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: media)
    ctx.endPDFPage(); ctx.closePDF()
}

let c = MainWindowController()
c.open(urls: [scanURL])
let doc = c.current!
check(TextRecognition.pagesNeedingText(in: doc.document) == [0], "fixture has no text layer")
let note = PDFAnnotation(bounds: NSRect(x: 50, y: 50, width: 20, height: 20), forType: .text, withProperties: nil)
doc.document.page(at: 0)!.addAnnotation(note)

var finished = false
let t0 = Date()
TextRecognition.recognize(doc.document, pages: [0], progress: { _, _ in true }) { result in
    if case .success(let pages)? = result { doc.replacePages(pages, name: "Recognize Text") }
    finished = true
}
while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
print("OCR took", String(format: "%.1f s", Date().timeIntervalSince(t0)))
let ocrText = doc.document.page(at: 0)!.string ?? ""
print("  text:", ocrText.replacingOccurrences(of: "\n", with: " | "))
check(ocrText.contains("Negligence") && ocrText.contains("Palsgraf"), "OCR text layer is extractable")
check(doc.document.findString("breach causation", withOptions: .caseInsensitive).count == 1, "OCR text is searchable as a phrase")
check(doc.document.page(at: 0)!.annotations.contains(note), "annotations carried to the OCR page")
check(doc.isDirty, "OCR marks the document edited")
doc.editHistory.undo()
check(TextRecognition.pagesNeedingText(in: doc.document) == [0] && doc.document.page(at: 0)!.annotations.contains(note),
      "undo restores the scan and its note")
doc.editHistory.redo()
check(TextRecognition.pagesNeedingText(in: doc.document).isEmpty, "redo restores OCR")
let docx = root.appendingPathComponent("ocr.docx")
try! WordExport.write(doc.document, to: docx)
check(((try? Data(contentsOf: docx))?.count ?? 0) > 1000, "OCR page converts to Word")

// 2. Fill & Sign marks survive Save and Flatten.
let page = doc.document.page(at: 0)!
doc.pdfView.go(to: page)
c.altRow = .fillSign
check(!c.fillRow.isHidden && c.toolRow.isHidden && c.convertRow.isHidden, "Fill & Sign row replaces the annotate row")
for (tool, pt) in [(ShapeTool.date, NSPoint(x: 100, y: 200)), (.check, NSPoint(x: 300, y: 200)),
                   (.cross, NSPoint(x: 340, y: 200)), (.stamp, NSPoint(x: 450, y: 150))] {
    doc.pdfView.placeFillMark(tool, on: page, at: pt)
}
let placed = page.annotations.filter { $0.type == "FreeText" || $0 is MarkAnnotation }
check(placed.count == 4, "date, checkmark, cross and stamp placed")
check(placed.contains { $0.contents == FillSign.dateString() }, "date text is today's date")
doc.editHistory.undo()
check(page.annotations.filter { $0 is MarkAnnotation }.count == 2, "undo removes the stamp")
doc.editHistory.redo()
let saved = root.appendingPathComponent("filled.pdf")
check(doc.document.write(to: saved), "save with marks")
let reopened = PDFDocument(url: saved)!
let stamps = reopened.page(at: 0)!.annotations.filter { $0.type == "Stamp" }
check(stamps.count == 3, "checkmark, cross, stamp reopen as stamps")
func inkPixels(_ d: PDFDocument, _ r: NSRect) -> Int {
    let p = d.page(at: 0)!
    let img = p.thumbnail(of: NSSize(width: 612, height: 792), for: .mediaBox)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let sx = CGFloat(rep.pixelsWide) / 612, sy = CGFloat(rep.pixelsHigh) / 792
    var n = 0
    for x in Int(r.minX * sx)..<Int(r.maxX * sx) {
        for y in Int((792 - r.maxY) * sy)..<Int((792 - r.minY) * sy) {
            if let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), col.redComponent < 0.6, col.greenComponent < 0.6 { n += 1 }
        }
    }
    return n
}
check(inkPixels(reopened, NSRect(x: 292, y: 192, width: 16, height: 16)) > 5, "checkmark appearance drawn after reopen")
let flat = root.appendingPathComponent("flat.pdf")
let copy = PDFDocument(data: doc.document.dataRepresentation()!)!
check(copy.write(to: flat, withOptions: [.burnInAnnotationsOption: true]), "write flattened")
let flatDoc = PDFDocument(url: flat)!
let left = flatDoc.page(at: 0)!.annotations.filter { $0.type != "Link" && $0.type != "Popup" }
print("  annotations after flatten:", left.map { $0.type ?? "?" })
check(left.isEmpty, "flattened copy has no annotations left")
check(inkPixels(flatDoc, NSRect(x: 292, y: 192, width: 16, height: 16)) > 5, "checkmark burned into the page")
check((flatDoc.page(at: 0)!.string ?? "").contains("Negligence"), "flattened page keeps the OCR text")

// 3. Reduce file size, password.
let reduced = root.appendingPathComponent("reduced.pdf")
check(doc.document.write(to: reduced, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]), "write reduced")
let sizeA = (try! saved.resourceValues(forKeys: [.fileSizeKey])).fileSize!
let sizeB = (try! reduced.resourceValues(forKeys: [.fileSizeKey])).fileSize!
print("  size \(sizeA) -> \(sizeB)")
check(sizeB < sizeA, "reduced copy is smaller")
let locked = root.appendingPathComponent("locked.pdf")
check(doc.document.write(to: locked, withOptions: [.userPasswordOption: "s3cret", .ownerPasswordOption: "s3cret"]), "write protected")
let ld = PDFDocument(url: locked)!
check(ld.isLocked && !ld.unlock(withPassword: "nope") && ld.unlock(withPassword: "s3cret"), "protected copy needs the password")

// 4. Text exports.
let rich = WordExport.attributedText(of: doc.document)
for (type, ext) in [(NSAttributedString.DocumentType.rtf, "rtf"), (.html, "html")] {
    let d = try! rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: type])
    check(String(decoding: d, as: UTF8.self).contains("Negligence"), "\(ext) export has the text")
}

// 5. Sidebar button leaves the page grid.
c.altRow = nil
doc.setGrid(true)
check(doc.gridMode, "grid on")
c.toggleLeftPanel(nil)
check(!doc.gridMode && doc.sidebarVisible, "sidebar button leaves the grid and shows the sidebar")
// 6. Saving a file opened through a symlink updates the real file and keeps the link.
do {
    let real = root.appendingPathComponent("real.pdf"), link = root.appendingPathComponent("link.pdf")
    check(doc.document.write(to: real), "write real file")
    try! FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real.pdf")
    let viaLink = DocumentViewController(document: PDFDocument(url: link)!, url: link, name: "link")
    viaLink.document.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: NSRect(x: 10, y: 10, width: 30, height: 30), forType: .square, withProperties: nil))
    check(viaLink.save(forceAsk: false), "save through symlink")
    check((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "real.pdf", "symlink kept")
    check(PDFDocument(url: real)!.page(at: 0)!.annotations.contains { $0.type == "Square" }, "real file has the new annotation")
}
print("All passed")
exit(0)
