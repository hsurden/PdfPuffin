import AppKit
import PDFKit

/// The retained rectangle is expressed in fractions of the displayed, rotated page.
enum PageCrop {
    static func bounds(on page: PDFPage, keeping rect: CGRect) -> CGRect {
        let box = page.bounds(for: .cropBox)
        let r: CGRect
        switch (page.rotation % 360 + 360) % 360 {
        case 90: r = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 180: r = CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 270: r = CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default: r = rect
        }
        return CGRect(x: box.minX + r.minX * box.width, y: box.minY + r.minY * box.height,
                      width: r.width * box.width, height: r.height * box.height)
    }
}

final class CropPreview: NSView {
    private var image: NSImage?
    private var origin: CGPoint?
    private(set) var retained: CGRect?
    var changed: (() -> Void)?
    func show(_ page: PDFPage) {
        let size = page.bounds(for: .cropBox).size
        let rotated = page.rotation % 180 != 0
        let scale = 900 / max(size.width, size.height, 1)
        image = page.thumbnail(of: CGSize(width: (rotated ? size.height : size.width) * scale,
                                          height: (rotated ? size.width : size.height) * scale), for: .cropBox)
        needsDisplay = true
    }
    private var paper: CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: paper)
        guard let r = retained else { return }
        let kept = CGRect(x: paper.minX + r.minX * paper.width, y: paper.minY + r.minY * paper.height,
                          width: r.width * paper.width, height: r.height * paper.height)
        let mask = NSBezierPath(rect: paper)
        mask.appendRect(kept)
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.52).setFill()
        mask.fill()
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: kept).stroke()
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard paper.contains(p) else { return }
        origin = p
        retained = nil
        changed?()
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = origin else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = min(max(p.x, paper.minX), paper.maxX), y = min(max(p.y, paper.minY), paper.maxY)
        let w = abs(x - start.x), h = abs(y - start.y)
        retained = w < 4 || h < 4 ? nil : CGRect(x: (min(x, start.x) - paper.minX) / paper.width,
            y: (min(y, start.y) - paper.minY) / paper.height, width: w / paper.width, height: h / paper.height)
        changed?()
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); origin = nil }
}

final class CropDialog: NSObject {
    let alert = NSAlert()
    let preview = CropPreview(frame: NSRect(x: 0, y: 0, width: 410, height: 350))
    let scope = NSPopUpButton()
    let doc: DocumentViewController
    let current: Int
    let selected: IndexSet
    init(_ doc: DocumentViewController) {
        self.doc = doc
        current = doc.grid?.current ?? doc.currentPageIndex
        selected = doc.grid?.selection ?? doc.sidebar.thumbnails.selectedPages
        super.init()
        alert.messageText = "Crop Pages"
        alert.informativeText = "Drag around the part of the page to keep. The shaded margins will be hidden."
        let apply = alert.addButton(withTitle: "Crop")
        apply.isEnabled = false
        alert.addButton(withTitle: "Cancel")
        scope.addItems(withTitles: ["Current page (\(current + 1))", "Selected pages (\(selected.count))", "All pages (\(doc.pageCount))"])
        scope.autoenablesItems = false
        scope.item(at: 1)?.isEnabled = !selected.isEmpty
        scope.selectItem(at: selected.count > 1 ? 1 : 0)
        scope.target = self
        scope.action = #selector(updatePage)
        let stack = NSStackView(views: [scope, preview])
        stack.orientation = .vertical
        stack.frame.size = CGSize(width: 410, height: 386)
        preview.widthAnchor.constraint(equalToConstant: 410).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 350).isActive = true
        alert.accessoryView = stack
        preview.changed = { [weak self] in apply.isEnabled = self?.preview.retained != nil }
        updatePage()
    }
    var pages: IndexSet {
        switch scope.indexOfSelectedItem {
        case 1: return selected
        case 2: return IndexSet(integersIn: 0..<doc.pageCount)
        default: return [current]
        }
    }
    @objc private func updatePage() {
        let index = pages.contains(current) ? current : pages.first ?? current
        if let page = doc.document.page(at: index) { preview.show(page) }
    }
    func run() {
        if alert.runModal() == .alertFirstButtonReturn, let rect = preview.retained {
            doc.cropPages(pages, keeping: rect)
        }
    }
}
