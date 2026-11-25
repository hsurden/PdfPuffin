import AppKit
import PDFKit

enum ReadingNotes {
    // Render PDF text literally, including characters with special meaning in Markdown.
    private static func literal(_ text: String) -> String {
        var result = ""
        let special = "\\*_[]#`~|"
        for c in text {
            switch c {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default:
                if special.contains(c) { result.append("\\") }
                result.append(c)
            }
        }
        return result
    }

    private static func passage(_ a: PDFAnnotation, on page: PDFPage) -> String {
        let points = (a.quadrilateralPoints ?? []).map(\.pointValue)
        var regions: [CGRect] = []
        if !points.isEmpty && points.count.isMultiple(of: 4) {
            for offset in stride(from: 0, to: points.count, by: 4) {
                let quad = points[offset..<(offset + 4)]
                let xs = quad.map(\.x), ys = quad.map(\.y)
                let x = xs.min()!, y = ys.min()!
                regions.append(CGRect(x: a.bounds.minX + x, y: a.bounds.minY + y,
                                      width: xs.max()! - x, height: ys.max()! - y))
            }
        }
        if regions.isEmpty { regions = [a.bounds] }
        return regions.compactMap { page.selection(for: $0)?.string }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One annotation's entry: its kind, the passage it marks (markup only) and its distinct comment.
    struct Entry { let name: String; let quote: String; let comment: String }
    /// One page's entries, with the printed page label and the PDF page when they differ.
    struct Section { let label: String; let physical: Int?; let entries: [Entry] }

    static func sections(from doc: DocumentViewController) -> [Section] {
        var sections: [Section] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.document.page(at: i) else { continue }
            var entries: [Entry] = []
            let sorted = page.annotations.sorted {
                if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
                return $0.bounds.minX < $1.bounds.minX
            }
            for a in sorted {
                guard let kind = a.type, AnnotationsPane.kinds.contains(kind), !a.isWatermark else { continue }
                let comment = (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let markup = ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(kind)
                let quote = markup ? passage(a, on: page) : ""
                guard !quote.isEmpty || !comment.isEmpty else { continue }
                let name = ["Text": "Note", "FreeText": "Text note", "StrikeOut": "Strikethrough"][kind] ?? kind
                func normalized(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                let distinct = !comment.isEmpty && normalized(comment) != normalized(quote) ? comment : ""
                entries.append(Entry(name: name, quote: quote, comment: distinct))
            }
            guard !entries.isEmpty else { continue }
            let label = doc.printedLabel(at: i)
            sections.append(Section(label: label, physical: label == String(i + 1) ? nil : i + 1, entries: entries))
        }
        return sections
    }

    static func markdown(from doc: DocumentViewController) -> String? {
        let all = sections(from: doc)
        guard !all.isEmpty else { return nil }
        let body = all.map { sec in
            let physical = sec.physical.map { " (PDF page \($0))" } ?? ""
            let entries = sec.entries.map { e in
                var entry = "**\(e.name)**"
                if !e.quote.isEmpty {
                    entry += "\n\n" + literal(e.quote).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
                }
                if !e.comment.isEmpty { entry += "\n\n" + literal(e.comment) }
                return entry
            }
            return "## Page \(literal(sec.label))\(physical)\n\n" + entries.joined(separator: "\n\n")
        }
        return "# \(literal(doc.displayName))\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    static func plainText(from doc: DocumentViewController) -> String? {
        let all = sections(from: doc)
        guard !all.isEmpty else { return nil }
        let body = all.map { sec in
            let physical = sec.physical.map { " (PDF page \($0))" } ?? ""
            let entries = sec.entries.map { e in
                var lines = [e.name]
                if !e.quote.isEmpty { lines.append("\u{201C}\(e.quote)\u{201D}") }
                if !e.comment.isEmpty { lines.append(e.comment) }
                return lines.joined(separator: "\n")
            }
            return "PAGE \(sec.label)\(physical)\n\n" + entries.joined(separator: "\n\n")
        }
        return doc.displayName + "\n\n" + body.joined(separator: "\n\n\n") + "\n"
    }

    static func html(from doc: DocumentViewController) -> String? {
        let all = sections(from: doc)
        guard !all.isEmpty else { return nil }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func para(_ s: String) -> String { esc(s).replacingOccurrences(of: "\n", with: "<br>") }
        var out = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(esc(doc.displayName))</title>
        <style>
        body { font: 15px/1.5 -apple-system, Helvetica, sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #222; }
        h2 { font-size: 1.05em; margin-top: 2em; border-bottom: 1px solid #ddd; padding-bottom: .2em; }
        .kind { font-weight: 600; margin: 1em 0 .2em; }
        blockquote { margin: .2em 0; padding-left: .8em; border-left: 3px solid #f2c94c; color: #444; }
        </style></head><body>
        <h1>\(esc(doc.displayName))</h1>

        """
        for sec in all {
            let physical = sec.physical.map { " (PDF page \($0))" } ?? ""
            out += "<h2>Page \(esc(sec.label))\(physical)</h2>\n"
            for e in sec.entries {
                out += "<p class=\"kind\">\(esc(e.name))</p>\n"
                if !e.quote.isEmpty { out += "<blockquote>\(para(e.quote))</blockquote>\n" }
                if !e.comment.isEmpty { out += "<p>\(para(e.comment))</p>\n" }
            }
        }
        return out + "</body></html>\n"
    }

    static func copy(from doc: DocumentViewController, to board: NSPasteboard) -> Bool {
        guard let text = markdown(from: doc) else { return false }
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
