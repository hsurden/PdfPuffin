import AppKit
import PDFKit

/// PDF → Word (.docx), like PDF Expert's Convert ▸ to Word.
/// Takes the text layer page by page, keeps fonts, sizes, bold and italics, and
/// rejoins the PDF's hard-wrapped lines into paragraphs so the Word file reflows.
/// Each PDF page starts a new Word page. Images and drawings are not carried over,
/// and a scanned PDF with no text layer has nothing to export.
enum WordExport {
    struct Line {
        let text: NSAttributedString
        let rect: CGRect
        var size: CGFloat
    }

    enum ExportError: LocalizedError {
        case noText
        var errorDescription: String? { "This PDF has no text layer to convert (it may be a scan)." }
    }

    /// The whole document as reflowed attributed text, pages separated by page breaks.
    static func attributedText(of doc: PDFDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            // Every page after the first starts a new Word page, even when an
            // earlier page (a blank or image-only cover) had no text, so the page
            // count matches. A form feed is written to .docx as a page break.
            if i > 0 { out.append(NSAttributedString(string: "\u{0C}")) }
            out.append(paragraphs(on: page))
        }
        return out
    }

    static func docxData(of doc: PDFDocument) throws -> Data {
        let text = attributedText(of: doc)
        guard text.string.contains(where: { !$0.isWhitespace }) else { throw ExportError.noText }
        return try text.data(from: NSRange(location: 0, length: text.length),
                             documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    static func write(_ doc: PDFDocument, to url: URL) throws {
        try docxData(of: doc).write(to: url, options: .atomic)
    }

    // MARK: reflow

    static func lines(on page: PDFPage) -> [Line] {
        // Only what the page shows: text the crop box hides stays out.
        let visible = page.bounds(for: .cropBox)
        guard let all = page.selection(for: visible) else { return [] }
        var result: [Line] = []
        for sel in all.selectionsByLine() {
            guard let a = sel.attributedString else { continue }
            let rect = sel.bounds(for: page)
            guard visible.contains(NSPoint(x: rect.midX, y: rect.midY)) else { continue }
            let trimmed = trimmingNewlines(a)
            guard trimmed.string.contains(where: { !$0.isWhitespace }) else { continue }
            result.append(Line(text: trimmed, rect: rect, size: dominantSize(trimmed)))
        }
        // Top of page first (PDF y grows upward); same row: left to right.
        result.sort { a, b in
            abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) / 2
                ? a.rect.midY > b.rect.midY : a.rect.minX < b.rect.minX
        }
        return result
    }

    static func paragraphs(on page: PDFPage) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for block in readingOrder(lines(on: page), in: page.bounds(for: .cropBox)) { out.append(reflow(block)) }
        return out
    }

    /// Splits a two-column page into blocks in reading order: within each band
    /// between full-width lines (title, headings, footnote rules), the whole left
    /// column, then the whole right one. A one-column page is a single block.
    static func readingOrder(_ ls: [Line], in box: CGRect) -> [[Line]] {
        guard ls.count >= 6 else { return [ls] }
        // The gutter: the x in the middle of the page that the fewest lines cross.
        var best: (x: CGFloat, crossing: Int)?
        var x = box.minX + box.width * 0.3
        while x <= box.maxX - box.width * 0.3 {
            let n = ls.filter { $0.rect.minX < x - 1 && $0.rect.maxX > x + 1 }.count
            if best == nil || n < best!.crossing { best = (x, n) }
            x += 2
        }
        guard let gutter = best?.x else { return [ls] }
        let leftSide = ls.filter { $0.rect.maxX <= gutter + 1 }
        let rightSide = ls.filter { $0.rect.minX >= gutter - 1 }
        func medianWidth(_ side: [Line]) -> CGFloat {
            let w = side.map(\.rect.width).sorted()
            return w.isEmpty ? 0 : w[w.count / 2]
        }
        // Two columns of prose: both sides hold several wide lines and most lines
        // stay on one side. Tables (narrow cells) and figure labels don't qualify,
        // and keep their row-by-row order.
        guard leftSide.count >= 3, rightSide.count >= 3, best!.crossing * 10 <= ls.count * 4,
              medianWidth(leftSide) >= box.width * 0.3, medianWidth(rightSide) >= box.width * 0.3 else { return [ls] }
        var blocks: [[Line]] = []
        var left: [Line] = [], right: [Line] = []
        func flushColumns() {
            if !left.isEmpty { blocks.append(left) }
            if !right.isEmpty { blocks.append(right) }
            left = []; right = []
        }
        for l in ls {                                     // already top to bottom
            if l.rect.maxX <= gutter + 1 { left.append(l) }
            else if l.rect.minX >= gutter - 1 { right.append(l) }
            else { flushColumns(); blocks.append([l]) }
        }
        flushColumns()
        // Merge neighbouring full-width lines back into one block so they still reflow.
        var merged: [[Line]] = []
        for b in blocks {
            if let last = merged.last, b.count == 1, last.allSatisfy({ $0.rect.minX < gutter - 1 && $0.rect.maxX > gutter + 1 }),
               b[0].rect.minX < gutter - 1, b[0].rect.maxX > gutter + 1 {
                merged[merged.count - 1].append(b[0])
            } else { merged.append(b) }
        }
        return merged
    }

    static func reflow(_ ls: [Line]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard !ls.isEmpty else { return out }
        // The body text block's edges: the most common line start and end, so a
        // running header or page number sticking out doesn't count.
        func mode(_ xs: [CGFloat]) -> CGFloat {
            var counts: [CGFloat: Int] = [:]
            for x in xs { counts[(x / 3).rounded() * 3, default: 0] += 1 }
            return counts.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }!.key
        }
        let left = mode(ls.map(\.rect.minX))
        let right = mode(ls.map(\.rect.maxX))
        let width = max(right - left, 1)
        // Typical baseline-to-baseline step for body text.
        let steps = zip(ls, ls.dropFirst()).map { $0.rect.midY - $1.rect.midY }.filter { $0 > 0 }.sorted()
        let step = steps.isEmpty ? 14 : steps[steps.count / 2]

        func centered(_ l: Line) -> Bool {
            let l0 = l.rect.minX - left, r0 = right - l.rect.maxX
            return l0 > width * 0.08 && r0 > width * 0.08 && abs(l0 - r0) < width * 0.05
        }

        var para = NSMutableAttributedString()
        var paraCentered = false
        func flush() {
            guard para.length > 0 else { return }
            let style = NSMutableParagraphStyle()
            style.alignment = paraCentered ? .center : .natural
            style.paragraphSpacing = 6
            para.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: para.length))
            para.append(NSAttributedString(string: "\n", attributes: para.attributes(at: para.length - 1, effectiveRange: nil)))
            out.append(para)
            para = NSMutableAttributedString()
        }

        for (i, line) in ls.enumerated() {
            if i == 0 {
                para.append(line.text); paraCentered = centered(line); continue
            }
            let prev = ls[i - 1]
            let gap = prev.rect.midY - line.rect.midY
            // Another piece of the same printed row (a split header, a raised
            // footnote mark): keep it on the line.
            if abs(gap) < max(prev.rect.height, line.rect.height) * 0.5, line.rect.minX >= prev.rect.maxX - 2 {
                let piece = NSMutableAttributedString(attributedString: line.text)
                let raised = line.size < prev.size * 0.85 && line.rect.minY > prev.rect.minY + 1
                if raised {
                    piece.addAttribute(.superscript, value: 1, range: NSRange(location: 0, length: piece.length))
                } else if line.rect.minX > prev.rect.maxX + 1, !(para.string.last?.isWhitespace ?? true) {
                    para.append(NSAttributedString(string: " ", attributes: para.attributes(at: para.length - 1, effectiveRange: nil)))
                }
                para.append(piece)
                continue
            }
            // A table-of-contents entry ends in a page number after dot leaders.
            let tocEntry = prev.text.string.range(of: #"(\.\s?){3,}\s*[0-9ivxlcIVXLC]+\s*$"#, options: .regularExpression) != nil
            let sizeChange = abs(prev.size - line.size) > 0.75
            let prevShort = prev.rect.maxX < right - width * 0.12
            let indented = line.rect.minX > left + 8 && line.rect.minX > prev.rect.minX + 8
            let wideGap = gap > step * 1.45 || gap < 0
            let lineCentered = centered(line)
            let breaks = wideGap || sizeChange || tocEntry || (prevShort && !(paraCentered && lineCentered)) || indented
                || paraCentered != lineCentered
            if breaks {
                flush()
                para.append(line.text); paraCentered = lineCentered
                continue
            }
            // Same paragraph: undo end-of-line hyphenation ("gradu-" + "ating").
            let s = para.string
            if s.hasSuffix("-"), s.count >= 2,
               s.dropLast().last?.isLowercase == true, line.text.string.first?.isLowercase == true {
                para.deleteCharacters(in: NSRange(location: para.length - 1, length: 1))
            } else if !(s.last?.isWhitespace ?? true) {
                para.append(NSAttributedString(string: " ", attributes: para.attributes(at: para.length - 1, effectiveRange: nil)))
            }
            para.append(line.text)
        }
        flush()
        return out
    }

    private static func trimmingNewlines(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        while let last = m.string.unicodeScalars.last, CharacterSet.newlines.contains(last) {
            m.deleteCharacters(in: NSRange(location: m.length - 1, length: 1))
        }
        while let first = m.string.unicodeScalars.first, CharacterSet.newlines.contains(first) {
            m.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        return m
    }

    /// The font size covering most of a line (a superscript footnote mark shouldn't count).
    private static func dominantSize(_ a: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if let f = v as? NSFont { counts[(f.pointSize * 2).rounded() / 2, default: 0] += r.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }
}
