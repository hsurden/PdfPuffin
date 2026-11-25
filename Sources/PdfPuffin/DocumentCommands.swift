import AppKit
import PDFKit
import UniformTypeIdentifiers

/// File-menu commands that write a new file from the open document: more export
/// formats, Save as Flattened, Reduce File Size, Set Password, plus Properties and
/// Scan & OCR ▸ Recognize Text. None of them overwrites the open PDF unless you
/// choose that file in the save panel.
extension MainWindowController {

    /// Asks where to save, next to the PDF by default. Nil if cancelled.
    private func askSaveURL(_ doc: DocumentViewController, suffix: String, ext: String, message: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = doc.displayName + suffix + "." + ext
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        if let message { panel.message = message }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// A PDF save must not land on a file another tab has open (it would be
    /// overwritten under that tab).
    private func isOpenElsewhere(_ url: URL, except doc: DocumentViewController) -> Bool {
        documentControllers.contains { $0 !== doc && $0.fileURL.map { DocumentViewController.sameFile($0, url) } == true }
    }

    // MARK: export formats

    @objc func exportToText(_ sender: Any?) { exportText(type: .plain, ext: "txt") }
    @objc func exportToRTF(_ sender: Any?) { exportText(type: .rtf, ext: "rtf") }
    @objc func exportToHTML(_ sender: Any?) { exportText(type: .html, ext: "html") }

    private func exportText(type: NSAttributedString.DocumentType, ext: String) {
        guard let doc = current else { return }
        let text = WordExport.attributedText(of: doc.document)
        guard text.string.contains(where: { !$0.isWhitespace }) else {
            let a = NSAlert(error: WordExport.ExportError.noText)
            a.informativeText = "Use Scan & OCR ▸ Recognize Text first."
            a.runModal(); return
        }
        guard let url = askSaveURL(doc, suffix: "", ext: ext) else { return }
        do {
            let data: Data
            if type == .plain {
                // Page breaks become blank lines in plain text.
                data = Data(text.string.replacingOccurrences(of: "\u{0C}", with: "\n\n").utf8)
            } else {
                var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
                if type == .html { attrs[.title] = doc.displayName }
                data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
            }
            try data.write(to: url, options: .atomic)
            flash("Saved “\(url.lastPathComponent)”")
        } catch { NSAlert(error: error).runModal() }
    }

    /// Each page as a PNG at 2× (144 dpi), with annotations, into a folder you pick.
    @objc func exportToImages(_ sender: Any?) {
        guard let doc = current else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the page images (\(doc.pageCount) PNG file\(doc.pageCount == 1 ? "" : "s"))."
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let digits = max(2, String(doc.pageCount).count)
        var written = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.document.page(at: i) else { continue }
            let b = page.bounds(for: .cropBox)
            let rotated = page.rotation % 180 != 0
            let size = NSSize(width: (rotated ? b.height : b.width) * 2, height: (rotated ? b.width : b.height) * 2)
            let img = page.thumbnail(of: size, for: .cropBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = "\(doc.displayName) - p\(String(format: "%0\(digits)d", i + 1)).png"
            if (try? png.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil { written += 1 }
        }
        if written == doc.pageCount { flash("Saved \(written) page image\(written == 1 ? "" : "s")") }
        else {
            let a = NSAlert()
            a.messageText = "Saved \(written) of \(doc.pageCount) page images."
            a.informativeText = "Some pages could not be written to “\(folder.lastPathComponent)”."
            a.runModal()
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: flatten

    /// Save as Flattened: annotations, signatures and form entries become part of
    /// the page, so they can't be moved, edited or removed. Text stays selectable.
    @objc func saveFlattened(_ sender: Any?) {
        guard let doc = current else { return }
        doc.textEditor?.commit()
        guard let url = askSaveURL(doc, suffix: " (flattened)", ext: "pdf",
                                   message: "Annotations, signatures and filled-in form fields are burned into the pages.") else { return }
        if isOpenElsewhere(url, except: doc) { refuseOpenFile(url); return }
        guard let copy = doc.document.dataRepresentation().flatMap(PDFDocument.init(data:)),
              copy.write(to: url, withOptions: [.burnInAnnotationsOption: true]) else {
            failed(url); return
        }
        noteRecent(url)
        flash("Saved “\(url.lastPathComponent)”")
    }

    // MARK: reduce file size

    @objc func reduceFileSize(_ sender: Any?) {
        guard let doc = current else { return }
        doc.textEditor?.commit()
        guard let url = askSaveURL(doc, suffix: " (reduced)", ext: "pdf",
                                   message: "Images are recompressed as JPEG and scaled for the screen. Text and vector drawings are unchanged.") else { return }
        if isOpenElsewhere(url, except: doc) { refuseOpenFile(url); return }
        let before = doc.document.dataRepresentation()?.count ?? 0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard doc.document.write(to: tmp, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
            failed(url); return
        }
        let after = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fmt = ByteCountFormatter()
        if after >= before {
            let a = NSAlert()
            a.messageText = "This PDF can't be made smaller."
            a.informativeText = "Compressing gave \(fmt.string(fromByteCount: Int64(after))), against \(fmt.string(fromByteCount: Int64(before))) now, so no file was saved."
            a.runModal(); return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) }
            else { try FileManager.default.moveItem(at: tmp, to: url) }
        } catch { NSAlert(error: error).runModal(); return }
        noteRecent(url)
        flash("\(fmt.string(fromByteCount: Int64(before))) → \(fmt.string(fromByteCount: Int64(after))): saved “\(url.lastPathComponent)”")
    }

    // MARK: password

    @objc func setPassword(_ sender: Any?) {
        guard let doc = current else { return }
        doc.textEditor?.commit()
        let a = NSAlert()
        a.messageText = "Set Password"
        a.informativeText = "Saves a copy that asks for this password before it opens. The open document is not changed."
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        pw.placeholderString = "Password"
        let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        again.placeholderString = "Verify"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(pw); box.addSubview(again)
        a.accessoryView = box
        a.addButton(withTitle: "Save Copy…")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = pw
        while true {
            guard a.runModal() == .alertFirstButtonReturn else { return }
            if pw.stringValue.isEmpty { a.informativeText = "Type a password."; continue }
            if pw.stringValue != again.stringValue { a.informativeText = "The two passwords don't match."; again.stringValue = ""; continue }
            break
        }
        guard let url = askSaveURL(doc, suffix: " (protected)", ext: "pdf") else { return }
        if isOpenElsewhere(url, except: doc) { refuseOpenFile(url); return }
        let p = pw.stringValue
        guard doc.document.write(to: url, withOptions: [.userPasswordOption: p, .ownerPasswordOption: p]) else {
            failed(url); return
        }
        noteRecent(url)
        flash("Saved password-protected “\(url.lastPathComponent)”")
    }

    // MARK: properties

    @objc func showProperties(_ sender: Any?) {
        guard let doc = current else { return }
        let pdf = doc.document
        let attrs = pdf.documentAttributes ?? [:]
        let fmt = ByteCountFormatter()
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        func str(_ k: PDFDocumentAttribute) -> String? {
            if let s = attrs[k] as? String, !s.isEmpty { return s }
            if let a = attrs[k] as? [String], !a.isEmpty { return a.joined(separator: ", ") }
            if let d = attrs[k] as? Date { return df.string(from: d) }
            return nil
        }
        var rows: [(String, String)] = []
        rows.append(("File", doc.fileURL?.lastPathComponent ?? "Not saved yet"))
        if let u = doc.fileURL {
            rows.append(("Location", u.deletingLastPathComponent().path))
            if let size = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                rows.append(("Size", fmt.string(fromByteCount: Int64(size))))
            }
        }
        rows.append(("Pages", "\(pdf.pageCount)"))
        if let p = pdf.page(at: 0) {
            let b = p.bounds(for: .mediaBox)
            let inches = String(format: "%.2f × %.2f in", b.width / 72, b.height / 72)
            let mm = String(format: "%.0f × %.0f mm", b.width / 72 * 25.4, b.height / 72 * 25.4)
            rows.append(("Page Size", "\(inches) (\(mm))"))
        }
        rows.append(("PDF Version", "\(pdf.majorVersion).\(pdf.minorVersion)"))
        for (label, key) in [("Title", PDFDocumentAttribute.titleAttribute), ("Author", .authorAttribute),
                             ("Subject", .subjectAttribute), ("Keywords", .keywordsAttribute),
                             ("Created", .creationDateAttribute), ("Modified", .modificationDateAttribute),
                             ("Application", .creatorAttribute), ("PDF Producer", .producerAttribute)] {
            if let v = str(key) { rows.append((label, v)) }
        }
        rows.append(("Security", pdf.isEncrypted ? "Password protected" : "None"))
        let noText = TextRecognition.pagesNeedingText(in: pdf).count
        rows.append(("Text Layer", noText == 0 ? "All pages" : noText == pdf.pageCount ? "None (scanned; use Recognize Text)" : "\(pdf.pageCount - noText) of \(pdf.pageCount) pages"))

        let grid = NSGridView(views: rows.map { k, v in
            let key = NSTextField(labelWithString: k + ":")
            key.font = .systemFont(ofSize: 12, weight: .semibold)
            key.alignment = .right
            let val = NSTextField(wrappingLabelWithString: v)
            val.font = .systemFont(ofSize: 12)
            val.isSelectable = true
            val.preferredMaxLayoutWidth = 320
            return [key, val]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.frame.size = grid.fittingSize
        let a = NSAlert()
        a.messageText = doc.displayName
        a.informativeText = ""
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: OCR

    @objc func recognizeText(_ sender: Any?) {
        guard let doc = current else { return }
        doc.textEditor?.commit()
        let pages = TextRecognition.pagesNeedingText(in: doc.document)
        guard !pages.isEmpty else {
            let a = NSAlert()
            a.messageText = "Every page already has text."
            a.informativeText = "Recognize Text only reads pages with no text layer (scans and photos)."
            a.runModal(); return
        }
        let sheet = OCRProgressSheet(total: pages.count)
        guard let window else { return }
        window.beginSheet(sheet.window)
        TextRecognition.recognize(doc.document, pages: pages, progress: { done, total in
            sheet.update(done, total)
            return !sheet.cancelled
        }, done: { [weak self, weak doc] result in
            window.endSheet(sheet.window)
            guard let self, let doc, let result else { return }
            switch result {
            case .failure(let e): NSAlert(error: e).runModal()
            case .success(let rebuilt):
                guard !rebuilt.isEmpty else {
                    self.flash("No text found on the scanned pages"); return
                }
                doc.replacePages(rebuilt, name: "Recognize Text")
                let skipped = pages.count - rebuilt.count
                self.flash("Recognized text on \(rebuilt.count) page\(rebuilt.count == 1 ? "" : "s")"
                           + (skipped > 0 ? " (\(skipped) had no readable text)" : ""))
            }
        })
    }

    private func refuseOpenFile(_ url: URL) {
        let a = NSAlert()
        a.messageText = "“\(url.lastPathComponent)” is open in another tab."
        a.informativeText = "Choose a different name or location."
        a.runModal()
    }

    private func failed(_ url: URL) {
        let a = NSAlert()
        a.messageText = "Could not save “\(url.lastPathComponent)”."
        a.informativeText = "PDFKit refused to write the file. Try another folder."
        a.runModal()
    }
}

/// "Recognizing text… page 3 of 12" with a progress bar and Cancel.
final class OCRProgressSheet: NSObject {
    let window: NSWindow
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private(set) var cancelled = false

    init(total: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        let title = NSTextField(labelWithString: "Recognizing Text")
        title.font = .boldSystemFont(ofSize: 13)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
        label.stringValue = "Reading page 1 of \(total)…"
        label.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [title, bar, label, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.setCustomSpacing(12, after: label)
        bar.widthAnchor.constraint(equalToConstant: 340).isActive = true
        window.contentView = stack
    }

    func update(_ done: Int, _ total: Int) {
        bar.doubleValue = Double(done)
        label.stringValue = done < total ? "Reading page \(done + 1) of \(total)…" : "Finishing…"
    }

    @objc private func cancel(_ sender: Any?) {
        cancelled = true
        label.stringValue = "Cancelling…"
    }
}
