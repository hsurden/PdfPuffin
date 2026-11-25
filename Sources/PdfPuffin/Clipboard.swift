import AppKit
import PDFKit
import UniformTypeIdentifiers

/// File ▸ New ▸ From Clipboard: PDF data, copied PDF/image files, or an image
/// (including a screenshot taken with ⌃⇧⌘4) becomes a new document.
enum Clipboard {
    static let excerptName = NSPasteboard.PasteboardType("com.hs.PdfPuffin.excerpt-name")

    static func suggestedName(from pb: NSPasteboard) -> String {
        guard let item = pb.pasteboardItems?.first, item.types.contains(.pdf),
              let name = item.string(forType: excerptName), !name.isEmpty,
              !name.contains("/"), !name.contains("\n") else { return "Clipboard" }
        return name
    }

    static func document(from pb: NSPasteboard) -> PDFDocument? {
        // 1. PDF data (e.g. copied from Preview or a "copy as PDF" app).
        if let data = pb.data(forType: .pdf) ?? pb.data(forType: NSPasteboard.PasteboardType("com.adobe.pdf")),
           let d = PDFDocument(data: data), d.pageCount > 0 {
            return d
        }
        // 2. Files copied in Finder.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let out = PDFDocument()
            for u in urls {
                if let d = PDFDocument(url: u), d.pageCount > 0, u.pathExtension.lowercased() == "pdf" {
                    for i in 0..<d.pageCount { if let p = d.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
                } else if let img = NSImage(contentsOf: u), let p = page(for: img) {
                    out.insert(p, at: out.pageCount)
                }
            }
            if out.pageCount > 0 { return out }
        }
        // 3. Image data (screenshots, copied pictures).
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !imgs.isEmpty {
            let out = PDFDocument()
            for img in imgs { if let p = page(for: img) { out.insert(p, at: out.pageCount) } }
            if out.pageCount > 0 { return out }
        }
        return nil
    }

    /// Cheap check used to enable File ▸ New ▸ From Clipboard.
    static func hasImportable(_ pb: NSPasteboard) -> Bool {
        if pb.availableType(from: [.pdf, NSPasteboard.PasteboardType("com.adobe.pdf")]) != nil { return true }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls.contains { u in
                u.pathExtension.lowercased() == "pdf" || NSImage.imageTypes.contains { t in
                    UTType(t).map { (UTType(filenameExtension: u.pathExtension)?.conforms(to: $0)) ?? false } ?? false }
            }
        }
        return false
    }

    /// A page the size of the image in points (Retina screenshots come in at 2x
    /// pixels; their NSImage size is already in points).
    static func page(for image: NSImage) -> PDFPage? {
        PDFPage(image: image)
    }
}
