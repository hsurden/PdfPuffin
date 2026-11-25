import AppKit
import PDFKit

/// PDF Expert's Fill & Sign bar: Text, Signature, Date, Checkmark, Cross, Stamp,
/// and Export as Flattened. Date is an ordinary text box (double-click to edit);
/// checkmarks, crosses and stamps draw themselves, and PDFKit saves that drawing
/// as their appearance (as with signatures), so they show in every PDF reader.
enum FillSign {
    static let dateFormats = ["MM/dd/yyyy", "MMMM d, yyyy", "d MMMM yyyy", "yyyy-MM-dd"]
    static var dateFormat: String {
        get { UserDefaults.standard.string(forKey: "fillDateFormat") ?? dateFormats[0] }
        set { UserDefaults.standard.set(newValue, forKey: "fillDateFormat") }
    }
    static func dateString(_ format: String = dateFormat, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }

    static let stamps = ["APPROVED", "REVIEWED", "RECEIVED", "DRAFT", "FINAL", "CONFIDENTIAL", "NOT APPROVED", "VOID", "COPY"]
    static var stamp: String {
        get { UserDefaults.standard.string(forKey: "fillStamp") ?? stamps[0] }
        set { UserDefaults.standard.set(newValue, forKey: "fillStamp") }
    }
    /// Stamps that also print the date underneath.
    static var stampDated: Bool {
        get { UserDefaults.standard.object(forKey: "fillStampDated") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fillStampDated") }
    }
}

/// A checkmark, cross or text stamp placed on the page.
final class MarkAnnotation: PDFAnnotation {
    enum Kind: Equatable { case check, cross, stamp(String, String?) }
    var kind: Kind = .check

    static func make(_ kind: Kind, centeredAt p: NSPoint, color: NSColor, on page: PDFPage, box: PDFDisplayBox) -> MarkAnnotation {
        let size: NSSize
        switch kind {
        case .check, .cross: size = NSSize(width: 14, height: 14)
        case .stamp(let title, let sub): size = stampSize(title, sub)
        }
        let pb = page.bounds(for: box)
        let r = NSRect(x: min(max(p.x - size.width / 2, pb.minX), pb.maxX - size.width),
                       y: min(max(p.y - size.height / 2, pb.minY), pb.maxY - size.height),
                       width: size.width, height: size.height)
        let a = MarkAnnotation(bounds: r, forType: .stamp, withProperties: nil)
        a.kind = kind
        a.color = color
        a.userName = NSFullUserName()
        a.modificationDate = Date()
        switch kind {
        case .check: a.contents = "✓"
        case .cross: a.contents = "✗"
        case .stamp(let t, let s): a.contents = [t, s].compactMap { $0 }.joined(separator: " ")
        }
        return a
    }

    private static func stampFont(_ h: CGFloat) -> NSFont { .systemFont(ofSize: h, weight: .heavy) }

    static func stampSize(_ title: String, _ sub: String?) -> NSSize {
        let w = (title as NSString).size(withAttributes: [.font: stampFont(18)]).width
        let sw = sub.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold)]).width } ?? 0
        return NSSize(width: max(w, sw) + 20, height: sub == nil ? 30 : 40)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let r = bounds
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        color.setStroke(); color.setFill()
        switch kind {
        case .check:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.52))
            p.line(to: NSPoint(x: r.minX + r.width * 0.40, y: r.minY + r.height * 0.18))
            p.line(to: NSPoint(x: r.minX + r.width * 0.90, y: r.minY + r.height * 0.86))
            p.lineWidth = max(r.height * 0.13, 1)
            p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.stroke()
        case .cross:
            let p = NSBezierPath()
            let i = r.insetBy(dx: r.width * 0.16, dy: r.height * 0.16)
            p.move(to: NSPoint(x: i.minX, y: i.minY)); p.line(to: NSPoint(x: i.maxX, y: i.maxY))
            p.move(to: NSPoint(x: i.minX, y: i.maxY)); p.line(to: NSPoint(x: i.maxX, y: i.minY))
            p.lineWidth = max(r.height * 0.13, 1)
            p.lineCapStyle = .round
            p.stroke()
        case .stamp(let title, let sub):
            // Everything scales with the box, so resizing keeps the proportions.
            let natural = Self.stampSize(title, sub)
            let k = min(r.width / natural.width, r.height / natural.height)
            let frame = r.insetBy(dx: 1.5 * k, dy: 1.5 * k)
            let border = NSBezierPath(roundedRect: frame, xRadius: 5 * k, yRadius: 5 * k)
            border.lineWidth = 2.2 * k
            border.stroke()
            let tAttrs: [NSAttributedString.Key: Any] = [.font: Self.stampFont(18 * k), .foregroundColor: color]
            let ts = (title as NSString).size(withAttributes: tAttrs)
            if let sub {
                let sAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8 * k, weight: .semibold), .foregroundColor: color]
                let ss = (sub as NSString).size(withAttributes: sAttrs)
                (title as NSString).draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.minY + 13 * k), withAttributes: tAttrs)
                (sub as NSString).draw(at: NSPoint(x: r.midX - ss.width / 2, y: r.minY + 5 * k), withAttributes: sAttrs)
            } else {
                (title as NSString).draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2), withAttributes: tAttrs)
            }
        }
    }
}

extension PuffinPDFView {
    /// Click-to-place Fill & Sign tools (date, checkmark, cross, stamp).
    func placeFillMark(_ tool: ShapeTool, on page: PDFPage, at p: NSPoint) {
        guard let doc = owner else { return }
        doc.activatePane(self)
        let color = AnnotColors.color(for: tool.rawValue)
        let a: PDFAnnotation
        switch tool {
        case .date:
            let text = FillSign.dateString()
            let font = TextStyle.font(family: TextStyle.family, size: TextStyle.size, bold: TextStyle.bold, italic: TextStyle.italic)
            let size = (text as NSString).size(withAttributes: [.font: font])
            let w = ceil(size.width) + 8, h = ceil(size.height) + 4
            let pb = page.bounds(for: displayBox)
            // Like the Text tool, the click marks the start of the line.
            let r = NSRect(x: min(max(p.x, pb.minX), pb.maxX - w), y: min(max(p.y - h / 2, pb.minY), pb.maxY - h),
                           width: w, height: h)
            let t = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
            t.contents = text
            t.font = font
            t.fontColor = color
            t.color = .clear
            t.alignment = .left
            let border = PDFBorder(); border.lineWidth = 0
            t.border = border
            t.userName = NSFullUserName()
            t.modificationDate = Date()
            a = t
        case .check: a = MarkAnnotation.make(.check, centeredAt: p, color: color, on: page, box: displayBox)
        case .cross: a = MarkAnnotation.make(.cross, centeredAt: p, color: color, on: page, box: displayBox)
        case .stamp:
            let sub = FillSign.stampDated ? FillSign.dateString("MMM d, yyyy").uppercased() : nil
            a = MarkAnnotation.make(.stamp(FillSign.stamp, sub), centeredAt: p, color: color, on: page, box: displayBox)
        default: return
        }
        page.addAnnotation(a)
        repaint(page)
        doc.recordAdded(a, on: page, name: "Add \(tool.title)")
        doc.thumbnailsActive = false
    }
}

/// The light second row in Fill & Sign mode.
final class FillSignRowView: NSView {
    private var toolButtons: [(ShapeTool, NSButton)] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.toolRow.cgColor
        typealias M = MainWindowController
        func tool(_ title: String, _ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, image: Theme.symbol(symbol, 15), target: nil, action: sel)
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.font = .systemFont(ofSize: 13)
            b.contentTintColor = NSColor(white: 0.22, alpha: 1)
            b.toolTip = tip
            b.refusesFirstResponder = true
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        let text = tool("Text", "character.textbox", "Text (⌃⌘T): click on the page and type", #selector(M.textToolAction(_:)))
        let sig = tool("Signature", "signature", "Signature", #selector(M.signatureAction(_:)))
        let date = tool("Date", "calendar", "Date: click to place today's date (format in the panel on the right)", #selector(M.dateToolAction(_:)))
        let check = tool("Checkmark", "checkmark", "Checkmark: click a box to tick it", #selector(M.checkToolAction(_:)))
        let cross = tool("Cross", "xmark", "Cross: click to place an ✗", #selector(M.crossToolAction(_:)))
        let stamp = tool("Stamp", "seal", "Stamp: Approved, Reviewed, Draft… (choose in the panel on the right)", #selector(M.stampToolAction(_:)))
        toolButtons = [(.text, text), (.signature, sig), (.date, date), (.check, check), (.cross, cross), (.stamp, stamp)]
        let flatten = NSButton(title: "Export as Flattened", target: nil, action: #selector(M.saveFlattened(_:)))
        flatten.bezelStyle = .push
        flatten.bezelColor = Theme.accent
        flatten.contentTintColor = .white
        flatten.refusesFirstResponder = true
        flatten.toolTip = "Save a copy with annotations, signatures and form entries burned into the pages"
        let select = NSButton(image: Theme.symbol("hand.raised", 15), target: nil, action: #selector(M.selectToolAction(_:)))
        select.isBordered = false
        select.contentTintColor = NSColor(white: 0.22, alpha: 1)
        select.toolTip = "Hand: scroll and select (Esc)"
        select.refusesFirstResponder = true

        let tools = NSStackView(views: toolButtons.map(\.1))
        tools.spacing = 18
        let line = ColorView(Theme.separator)
        for v in [select, tools, flatten, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            select.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            select.centerYAnchor.constraint(equalTo: centerYAnchor),
            select.widthAnchor.constraint(equalToConstant: 36),
            tools.centerXAnchor.constraint(equalTo: centerXAnchor),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            flatten.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            flatten.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(shape: ShapeTool?) {
        for (t, b) in toolButtons {
            let on = t == shape
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.layer?.backgroundColor = on ? NSColor(white: 0.84, alpha: 1).cgColor : NSColor.clear.cgColor
            b.layer?.borderWidth = on ? 1 : 0
            b.layer?.borderColor = Theme.accent.cgColor
        }
    }
}
