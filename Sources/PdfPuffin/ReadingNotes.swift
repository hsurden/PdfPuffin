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

    static func markdown(from doc: DocumentViewController) -> String? {
        var sections: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.document.page(at: i) else { continue }
            var entries: [String] = []
            let sorted = page.annotations.sorted {
                if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
                return $0.bounds.minX < $1.bounds.minX
            }
            for a in sorted {
                guard let kind = a.type, AnnotationsPane.kinds.contains(kind) else { continue }
                let comment = (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let markup = ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(kind)
                let quote = markup ? passage(a, on: page) : ""
                guard !quote.isEmpty || !comment.isEmpty else { continue }
                let name = ["Text": "Note", "FreeText": "Text note", "StrikeOut": "Strikethrough"][kind] ?? kind
                var entry = "**\(name)**"
                if !quote.isEmpty {
                    entry += "\n\n" + literal(quote).components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
                }
                func normalized(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                if !comment.isEmpty && normalized(comment) != normalized(quote) {
                    entry += "\n\n" + literal(comment)
                }
                entries.append(entry)
            }
            guard !entries.isEmpty else { continue }
            let label = doc.printedLabel(at: i)
            let physical = label == String(i + 1) ? "" : " (PDF page \(i + 1))"
            sections.append("## Page \(literal(label))\(physical)\n\n" + entries.joined(separator: "\n\n"))
        }
        guard !sections.isEmpty else { return nil }
        return "# \(literal(doc.displayName))\n\n" + sections.joined(separator: "\n\n") + "\n"
    }

    static func copy(from doc: DocumentViewController, to board: NSPasteboard) -> Bool {
        guard let text = markdown(from: doc) else { return false }
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
