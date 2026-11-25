import AppKit
import PDFKit

/// Typing directly on the page, like PDF Expert's Text tool: a text box with a
/// cursor sits over the page at the click. Font, size, bold, italic, colour and
/// background come from the Text Tool inspector (TextStyle) and change live.
/// Click elsewhere or press Esc to finish; the box becomes a FreeText annotation.
final class InlineTextEditor: NSObject, NSTextViewDelegate {
    weak var doc: DocumentViewController?
    let page: PDFPage
    let anchor: NSPoint                  // top-left of the box, in page space
    private var existing: PDFAnnotation?
    private var before: AnnotSnapshot?          // the box as it was, for Undo
    let textView = EditorTextView()
    private var observers: [NSObjectProtocol] = []
    private var finished = false

    static let maxWidth: CGFloat = 420   // page points before the text wraps
    private let inset = NSSize(width: 4, height: 3)

    init(doc: DocumentViewController, page: PDFPage, anchor: NSPoint, existing: PDFAnnotation?) {
        self.doc = doc; self.page = page; self.anchor = anchor; self.existing = existing
        super.init()
        if let a = existing {   // editing a box: its style becomes the current text style
            if let f = a.font {
                TextStyle.family = f.familyName ?? TextStyle.family
                TextStyle.size = f.pointSize
                let t = NSFontManager.shared.traits(of: f)
                TextStyle.bold = t.contains(.boldFontMask); TextStyle.italic = t.contains(.italicFontMask)
            }
            if let fc = a.fontColor, let i = AnnotColors.palette.firstIndex(where: { $0.1.isClose(to: fc) }) {
                AnnotColors.set(i, for: "text")
            }
            TextStyle.whiteBackground = (a.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0) > 0.5
        }
    }

    private var pdf: PuffinPDFView? { doc?.pdfView }
    private var scale: CGFloat { pdf?.scaleFactor ?? 1 }
    private var color: NSColor { AnnotColors.color(for: "text") }
    private func font(_ size: CGFloat) -> NSFont {
        TextStyle.font(family: TextStyle.family, size: size, bold: TextStyle.bold, italic: TextStyle.italic)
    }

    func start() {
        guard let pdf else { return }
        if let a = existing { before = AnnotSnapshot(a); page.removeAnnotation(a) }   // hidden while editing
        textView.editor = self
        textView.string = existing?.contents ?? ""
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.wantsLayer = true
        textView.layer?.borderColor = Theme.accent.cgColor
        textView.layer?.borderWidth = 1
        textView.insertionPointColor = Theme.accent
        pdf.addSubview(textView)
        applyStyle()
        pdf.window?.makeFirstResponder(textView)
        doc?.main?.updateToolbar()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        let nc = NotificationCenter.default
        if let clip = pdf.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.layout() })
        }
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdf, queue: .main) { [weak self] _ in self?.applyStyle() })
    }

    /// Restyle from TextStyle and resize.
    func applyStyle() {
        textView.font = font(TextStyle.size * scale)
        textView.textColor = color
        textView.drawsBackground = true
        textView.backgroundColor = TextStyle.whiteBackground ? .white : NSColor.white.withAlphaComponent(0.01)
        layout()
    }

    func textDidChange(_ notification: Notification) { layout() }

    func layout() {
        guard let pdf, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let f = textView.font ?? .systemFont(ofSize: 14)
        let lineH = lm.defaultLineHeight(for: f)
        let text = textView.string
        let r = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: f])
            .boundingRect(with: NSSize(width: Self.maxWidth * scale, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        var textH = max(ceil(r.height), lineH)
        if text.hasSuffix("\n") { textH += lineH }
        let w = max(ceil(r.width) + inset.width * 2 + 3, 24 * scale)
        let h = textH + inset.height * 2
        tc.containerSize = NSSize(width: w - inset.width * 2, height: .greatestFiniteMagnitude)
        let top = pdf.convert(anchor, from: page)
        textView.frame = NSRect(x: top.x, y: pdf.isFlipped ? top.y : top.y - h, width: w, height: h)
    }

    /// Finish: turn the box into an annotation (or drop it if empty).
    func commit() {
        guard !finished else { return }
        finished = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let text = textView.string
        let frame = textView.frame
        textView.removeFromSuperview()
        doc?.textEditor = nil
        doc?.main?.updateToolbar()
        guard let doc else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let a = existing, let before {                     // emptied = deleted
                doc.recordRemoved(a, from: page, name: "Delete Text", restoring: before)
            }
            doc.main?.focusPDF()
            return
        }
        let w = frame.width / scale, h = frame.height / scale
        let bounds = NSRect(x: anchor.x, y: anchor.y - h, width: w, height: h)
        let a = existing ?? PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        a.bounds = bounds
        a.contents = text
        a.font = font(TextStyle.size)
        a.fontColor = color
        a.color = TextStyle.whiteBackground ? .white : .clear
        a.alignment = .left
        let border = PDFBorder(); border.lineWidth = 0
        a.border = border
        a.userName = NSFullUserName()
        a.modificationDate = Date()
        page.addAnnotation(a)
        doc.pdfView.repaint(page)
        if let before { doc.recordChanged(a, on: page, name: "Edit Text", from: before, to: AnnotSnapshot(a)) }
        else { doc.recordAdded(a, on: page, name: "Add Text") }
        doc.main?.focusPDF()
    }

    func contains(windowPoint p: NSPoint) -> Bool {
        textView.superview != nil && textView.bounds.contains(textView.convert(p, from: nil))
    }

    func undoManager(for view: NSTextView) -> UndoManager? { textView.localUndoManager }

    func refocus() { textView.window?.makeFirstResponder(textView) }
}

final class EditorTextView: NSTextView {
    weak var editor: InlineTextEditor?
    let localUndoManager = UndoManager()

    override var undoManager: UndoManager? { localUndoManager }

    override func cancelOperation(_ sender: Any?) { editor?.commit() }   // Esc finishes
}
