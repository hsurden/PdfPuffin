import AppKit
import PDFKit
import Vision

/// Scan & OCR ▸ Recognize Text. Pages with no text layer are read with Apple's
/// Vision text recognizer, and each one is rebuilt as the original page (drawn
/// unchanged, so nothing is re-compressed) with the recognized words laid over it
/// as invisible text, the way scanners' OCR does. The page then searches,
/// highlights, copies and converts to Word like any text PDF. Pages that already
/// have text are left alone.
enum TextRecognition {
    /// Pages that would be saved with no text layer. Neither `PDFPage.string` nor
    /// the in-memory page can tell: once PDFKit has shown a scan it runs its own
    /// Live Text and reports that text, but never writes it into the file. So this
    /// checks the document as it would be saved, reading each page's content
    /// stream (and the form XObjects it draws) for text-showing operators.
    static func pagesNeedingText(in doc: PDFDocument) -> [Int] {
        if let data = doc.dataRepresentation(), let provider = CGDataProvider(data: data as CFData),
           let saved = CGPDFDocument(provider), saved.numberOfPages == doc.pageCount {
            return (0..<doc.pageCount).filter { i in saved.page(at: i + 1).map { !hasTextLayer($0) } ?? false }
        }
        return (0..<doc.pageCount).filter { i in doc.page(at: i)?.pageRef.map { !hasTextLayer($0) } ?? false }
    }

    static func hasTextLayer(_ page: CGPDFPage) -> Bool {
        final class State { var found = false; var depth = 0; var table: CGPDFOperatorTableRef? }
        guard let table = CGPDFOperatorTableCreate() else { return true }
        let text: CGPDFOperatorCallback = { scanner, info in
            Unmanaged<State>.fromOpaque(info!).takeUnretainedValue().found = true
            CGPDFScannerStop(scanner)
        }
        for op in ["Tj", "TJ", "'", "\""] { CGPDFOperatorTableSetCallback(table, op, text) }
        // Text drawn inside a form XObject counts too.
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let cs = CGPDFScannerGetContentStream(scanner)
            var stream: CGPDFStreamRef?
            guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name),
                  CGPDFObjectGetValue(obj, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form",
                  state.depth < 8, let table = state.table else { return }
            var formRes: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dict, "Resources", &formRes)
            let content = CGPDFContentStreamCreateWithStream(stream, formRes ?? dict, cs)
            let inner = CGPDFScannerCreate(content, table, info)
            state.depth += 1
            CGPDFScannerScan(inner)
            state.depth -= 1
            if state.found { CGPDFScannerStop(scanner) }
        }
        let state = State()
        state.table = table
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(CGPDFContentStreamCreateWithPage(page), table, info)
        CGPDFScannerScan(scanner)
        return state.found
    }

    struct Word { let text: String; let box: CGRect }   // box in page (media box) points

    /// Recognizes the words on one page. Thread-safe: works on the CGPDFPage only.
    static func words(on pageRef: CGPDFPage, languages: [String]? = nil) throws -> [Word] {
        let media = pageRef.getBoxRect(.mediaBox)
        guard media.width > 0, media.height > 0 else { return [] }
        // About 300 dpi, capped so a poster-sized page stays manageable.
        let scale = min(300.0 / 72.0, 6000 / max(media.width, media.height))
        let w = Int(media.width * scale), h = Int(media.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -media.minX, y: -media.minY)
        ctx.drawPDFPage(pageRef)
        guard let image = ctx.makeImage() else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages { request.recognitionLanguages = languages }
        else { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        var words: [Word] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            // One entry per word so selection and highlights hug the printed words.
            var tokens: [Range<String.Index>] = []
            var i = s.startIndex
            while i < s.endIndex {
                while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
                var j = i
                while j < s.endIndex, !s[j].isWhitespace { j = s.index(after: j) }
                if i < j { tokens.append(i..<j) }
                i = j
            }
            for r in tokens {
                let norm = (try? cand.boundingBox(for: r))?.boundingBox ?? obs.boundingBox
                let box = CGRect(x: media.minX + norm.minX * media.width, y: media.minY + norm.minY * media.height,
                                 width: norm.width * media.width, height: norm.height * media.height)
                guard box.width > 0.5, box.height > 0.5 else { continue }
                words.append(Word(text: String(s[r]), box: box))
            }
        }
        return words
    }

    /// One PDF page: the original page drawn as is, plus invisible words.
    static func pageData(_ pageRef: CGPDFPage, words: [Word]) -> Data? {
        var media = pageRef.getBoxRect(.mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: media)] as CFDictionary)
        ctx.drawPDFPage(pageRef)
        ctx.setTextDrawingMode(.invisible)
        for w in words {
            // Fit the word to its box with natural letter spacing: the font size
            // makes the word as wide as the box, and a vertical scale makes it as
            // tall. (Stretching horizontally instead spreads the letters, and
            // PDFKit then reads "shown" as "s h o w n".) A trailing space keeps
            // words apart when the text is extracted.
            let probe = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
            let at10 = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                NSAttributedString(string: w.text, attributes: [.font: probe])), nil, nil, nil)
            let size = at10 > 0 ? max(10 * w.box.width / CGFloat(at10), 1) : max(w.box.height * 0.82, 1)
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let tall = min(max(w.box.height * 0.82 / size, 0.2), 5)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: w.text + " ", attributes: [.font: font]))
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: tall)
            ctx.textPosition = CGPoint(x: w.box.minX, y: w.box.minY + w.box.height * 0.18)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Recognizes the given pages in the background. `progress` is called on the
    /// main queue with (pages done, total); return false from it to stop.
    /// `done` gets the rebuilt pages by index (nil if cancelled).
    static func recognize(_ doc: PDFDocument, pages: [Int],
                          progress: @escaping (Int, Int) -> Bool,
                          done: @escaping (Result<[Int: PDFPage], Error>?) -> Void) {
        // Read the pages as they would be saved (see pagesNeedingText).
        let saved = doc.dataRepresentation().flatMap { CGDataProvider(data: $0 as CFData) }.flatMap(CGPDFDocument.init)
        let refs: [(Int, CGPDFPage)] = pages.compactMap { i in
            if let saved, saved.numberOfPages == doc.pageCount, let p = saved.page(at: i + 1) { return (i, p) }
            return doc.page(at: i)?.pageRef.map { (i, $0) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [Int: Data] = [:]
            var cancelled = false
            for (n, (i, ref)) in refs.enumerated() {
                do {
                    let words = try Self.words(on: ref)
                    if !words.isEmpty, let d = pageData(ref, words: words) { out[i] = d }
                } catch {
                    DispatchQueue.main.async { done(.failure(error)) }
                    return
                }
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    if !progress(n + 1, refs.count) { cancelled = true }
                    sem.signal()
                }
                sem.wait()
                if cancelled { break }
            }
            DispatchQueue.main.async {
                if cancelled { done(nil); return }
                // Keep each one-page document alive until its page joins the open document.
                var pages: [Int: PDFPage] = [:]
                var holders: [PDFDocument] = []
                for (i, d) in out {
                    if let pdf = PDFDocument(data: d), let p = pdf.page(at: 0) { pages[i] = p; holders.append(pdf) }
                }
                done(.success(pages))
                withExtendedLifetime(holders) {}
            }
        }
    }
}
