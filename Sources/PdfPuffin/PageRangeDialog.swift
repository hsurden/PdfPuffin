import AppKit
import PDFKit

/// Resolve against explicit numbering so physical page 11 and printed page 310
/// can coexist. Duplicate labels require switching to physical page numbers.
struct PageNumbers {
    let count: Int
    let labels: [String]
    private let indices: [String: [Int]]

    init(labels: [String]) {
        self.labels = labels
        count = labels.count
        indices = Dictionary(grouping: labels.indices, by: { labels[$0].lowercased() })
    }

    func pages(_ input: String, printed: Bool, single: Bool = false) -> IndexSet? {
        func index(_ token: Substring) -> Int? {
            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if printed {
                guard !value.isEmpty, let matches = indices[value.lowercased()], matches.count == 1 else { return nil }
                return matches[0]
            }
            guard let number = Int(value), number > 0, number <= count else { return nil }
            return number - 1
        }
        var result = IndexSet()
        for part in input.split(separator: ",", omittingEmptySubsequences: false) {
            if let page = index(part) { result.insert(page); continue }
            guard !single else { return nil }
            let ranges = part.indices.compactMap { split -> ClosedRange<Int>? in
                guard "-–—".contains(part[split]), let start = index(part[..<split]),
                      let end = index(part[part.index(after: split)...]), start <= end else { return nil }
                return start...end
            }
            guard ranges.count == 1 else { return nil }
            result.insert(integersIn: ranges[0])
        }
        return result.isEmpty || (single && result.count != 1) ? nil : result
    }
}

final class PageRangeDialog: NSObject, NSTextFieldDelegate {
    let doc: DocumentViewController
    let single: Bool
    let numbers: PageNumbers
    let alert = NSAlert()
    let field = NSTextField()
    let mode = NSSegmentedControl(labels: ["PDF pages", "Printed pages"], trackingMode: .selectOne, target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let first = NSImageView()
    let last = NSImageView()
    var usesPrintedPages: Bool { mode.selectedSegment == 1 }
    private(set) var selected: IndexSet?

    init(doc: DocumentViewController, single: Bool) {
        self.doc = doc
        self.single = single
        numbers = PageNumbers(labels: (0..<doc.pageCount).map { doc.printedLabel(at: $0) })
        super.init()
        alert.messageText = single ? "Go to Page" : "Create Excerpt from Page Range"
        alert.informativeText = single ? "Enter a page number or printed label." : "Enter pages or ranges, such as 41–50, 63–65."
        alert.addButton(withTitle: single ? "Go" : "Create Excerpt")
        alert.addButton(withTitle: "Cancel")
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        field.delegate = self
        field.stringValue = String(doc.currentPageIndex + 1)
        // An explicit accessory frame also sizes the modal before its first layout.
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: single ? 106 : 218))
        mode.frame = NSRect(x: 0, y: box.bounds.height - 26, width: 255, height: 26)
        field.frame = NSRect(x: 0, y: box.bounds.height - 58, width: 340, height: 24)
        status.frame = NSRect(x: 0, y: box.bounds.height - 102, width: 340, height: 38)
        for view in [mode, field, status] as [NSView] { box.addSubview(view) }
        if !single {
            for (i, image) in [first, last].enumerated() {
                image.frame = NSRect(x: i * 170, y: 0, width: 155, height: 112)
                image.imageScaling = .scaleProportionallyUpOrDown
                box.addSubview(image)
            }
        }
        alert.accessoryView = box
        alert.window.initialFirstResponder = field
        update()
    }

    @objc private func modeChanged() {
        if single { field.stringValue = mode.selectedSegment == 1 ? doc.printedLabel(at: doc.currentPageIndex) : String(doc.currentPageIndex + 1) }
        update()
    }
    func controlTextDidChange(_ obj: Notification) { update() }

    private func update() {
        selected = numbers.pages(field.stringValue, printed: usesPrintedPages, single: single)
        alert.buttons[0].isEnabled = selected != nil
        guard let pages = selected, let a = pages.first, let b = pages.last else {
            status.stringValue = "Enter a valid, unambiguous page or range in this document."
            first.image = nil
            last.image = nil
            return
        }
        status.stringValue = single ? "PDF page \(a + 1) of \(numbers.count)" :
            "\(pages.count) selected · First: PDF \(a + 1) · Last: PDF \(b + 1)"
        guard !single else { return }
        first.image = doc.document.page(at: a)?.thumbnail(of: NSSize(width: 155, height: 112), for: .cropBox)
        last.image = b == a ? nil : doc.document.page(at: b)?.thumbnail(of: NSSize(width: 155, height: 112), for: .cropBox)
    }

    func run() -> IndexSet? { alert.runModal() == .alertFirstButtonReturn ? selected : nil }
}
