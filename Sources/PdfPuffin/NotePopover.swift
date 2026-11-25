import AppKit
import PDFKit

/// Non-modal floating note/comment card anchored beside a PDF sticky note or markup annotation.
final class NoteCardEditor: NSObject, NSTextViewDelegate {
    weak var doc: DocumentViewController?
    let page: PDFPage
    let annotation: PDFAnnotation
    let isNew: Bool
    private let before: AnnotSnapshot?
    let card = NoteCardView()
    private var observers: [NSObjectProtocol] = []
    private var finished = false

    private static let markupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]

    init(doc: DocumentViewController, page: PDFPage, annotation: PDFAnnotation, isNew: Bool) {
        self.doc = doc
        self.page = page
        self.annotation = annotation
        self.isNew = isNew
        self.before = isNew ? nil : AnnotSnapshot(annotation)
        super.init()
    }

    /// Extracts the quoted text under a markup annotation.
    static func passage(for a: PDFAnnotation, on page: PDFPage) -> String {
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

    /// Returns a markup's user comment (empty if `contents` only duplicates the highlighted text),
    /// or `contents` directly for non-markup annotations.
    static func distinctComment(for a: PDFAnnotation, on page: PDFPage) -> String {
        let raw = a.contents ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if markupTypes.contains(a.type ?? "") {
            func norm(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            let quote = passage(for: a, on: page)
            if !quote.isEmpty && norm(trimmed) == norm(quote) { return "" }
        }
        return raw
    }

    func start() {
        guard let doc else { return }
        let pdf = doc.pdfView
        let pageNum = doc.printedLabel(at: doc.document.index(for: page))
        let isStickyNote = annotation.type == "Text"
        card.editor = self
        card.configure(
            title: (isStickyNote ? "Note" : "Comment") + " · p. \(pageNum)",
            color: annotation.color,
            showColors: isStickyNote,
            text: isStickyNote ? (annotation.contents ?? "") : Self.distinctComment(for: annotation, on: page)
        )
        card.textView.delegate = self
        card.onPickColor = { [weak self] color in
            guard let self else { return }
            self.annotation.color = color
            self.card.applyHeaderColor(color)
            self.doc?.pdfView.refresh(self.annotation, on: self.page)
        }
        card.onDelete = { [weak self] in self?.deleteAnnotation() }
        card.onDone = { [weak self] in self?.commit() }

        pdf.addSubview(card)
        layout()
        pdf.window?.makeFirstResponder(card.textView)
        let len = (card.textView.string as NSString).length
        card.textView.setSelectedRange(NSRange(location: len, length: 0))

        let nc = NotificationCenter.default
        if let clip = pdf.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.layout()
            })
        }
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdf, queue: .main) { [weak self] _ in
            self?.layout()
        })
    }

    func layout() {
        guard let pdf = doc?.pdfView else { return }
        let size = NSSize(width: 270, height: 190)
        let anchorRect = pdf.convert(annotation.bounds, from: page)
        let bounds = pdf.bounds.insetBy(dx: 10, dy: 10)
        var x = anchorRect.maxX + 8
        if x + size.width > bounds.maxX {
            x = anchorRect.minX - size.width - 8
        }
        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        var y: CGFloat
        if pdf.isFlipped {
            y = anchorRect.minY
            if y + size.height > bounds.maxY { y = anchorRect.maxY - size.height }
        } else {
            y = anchorRect.maxY - size.height
            if y < bounds.minY { y = anchorRect.minY }
        }
        y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        card.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    func contains(windowPoint p: NSPoint) -> Bool {
        card.superview != nil && card.bounds.contains(card.convert(p, from: nil))
    }

    func commit() {
        guard !finished else { return }
        finished = true
        cleanup()
        guard let doc else { return }
        let rawText = card.textView.string
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            if trimmed.isEmpty {
                page.removeAnnotation(annotation)
                doc.pdfView.repaint(page)
            } else {
                annotation.contents = rawText
                annotation.modificationDate = Date()
                doc.pdfView.refresh(annotation, on: page)
                doc.recordAdded(annotation, on: page, name: "Add Note")
            }
        } else {
            annotation.contents = trimmed.isEmpty ? nil : rawText
            annotation.modificationDate = Date()
            if let before, before.contents != annotation.contents || !before.color.isClose(to: annotation.color) {
                doc.recordChanged(annotation, on: page, name: "Edit Comment", from: before, to: AnnotSnapshot(annotation))
            } else {
                doc.pdfView.refresh(annotation, on: page)
            }
        }
        doc.main?.focusPDF()
    }

    func deleteAnnotation() {
        guard !finished else { return }
        finished = true
        cleanup()
        guard let doc else { return }
        if isNew {
            page.removeAnnotation(annotation)
            doc.pdfView.repaint(page)
        } else {
            doc.removeAnnotation(annotation)
            doc.pdfView.repaint(page)
        }
        doc.main?.focusPDF()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { card.textView.localUndoManager }

    private func cleanup() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        card.removeFromSuperview()
        doc?.noteEditor = nil
    }
}

final class NoteCardView: NSView {
    weak var editor: NoteCardEditor?
    var onPickColor: ((NSColor) -> Void)?
    var onDelete: (() -> Void)?
    var onDone: (() -> Void)?

    private let header = NSView()
    private let titleLabel = label("Note", size: 12, weight: .semibold, color: NSColor(white: 0.15, alpha: 1))
    private let colorStack = NSStackView()
    let textView = NoteTextView()
    private var colorActions: [ObjectIdentifier: NSColor] = [:]

    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 0.985, blue: 0.88, alpha: 1).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0, alpha: 0.16).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowColor = NSColor(white: 0, alpha: 0.22)
            return s
        }()

        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false

        colorStack.spacing = 4
        colorStack.translatesAutoresizingMaskIntoConstraints = false
        for idx in [2, 3, 4, 0, 5] {
            let (name, color) = AnnotColors.palette[idx]
            let b = NSButton(image: AnnotColors.swatch(color, size: 12), target: self, action: #selector(colorClicked(_:)))
            b.isBordered = false
            b.refusesFirstResponder = true
            b.toolTip = name
            colorActions[ObjectIdentifier(b)] = color
            colorStack.addArrangedSubview(b)
        }

        let trash = iconButton("trash", tip: "Delete Note", target: self, action: #selector(deleteClicked), tint: NSColor(white: 0.3, alpha: 1), size: 12, width: 22)
        let done = iconButton("xmark", tip: "Done (Esc or ⌘Return)", target: self, action: #selector(doneClicked), tint: NSColor(white: 0.3, alpha: 1), size: 11, width: 22)

        for v in [titleLabel, colorStack, trash, done] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }

        let sep = ColorView(NSColor(white: 0, alpha: 0.1))
        sep.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSColor(white: 0.12, alpha: 1)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [header, sep, scroll] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            done.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            done.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            trash.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -2),
            trash.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            colorStack.trailingAnchor.constraint(equalTo: trash.leadingAnchor, constant: -6),
            colorStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            sep.topAnchor.constraint(equalTo: header.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, color: NSColor, showColors: Bool, text: String) {
        titleLabel.stringValue = title
        colorStack.isHidden = !showColors
        textView.editor = editor
        textView.string = text
        applyHeaderColor(color)
    }

    func applyHeaderColor(_ c: NSColor) {
        let base = c.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: 1)
        header.layer?.backgroundColor = base.withAlphaComponent(0.32).cgColor
    }

    @objc private func colorClicked(_ b: NSButton) {
        if let c = colorActions[ObjectIdentifier(b)] { onPickColor?(c) }
    }
    @objc private func deleteClicked() { onDelete?() }
    @objc private func doneClicked() { onDone?() }
}

final class NoteTextView: NSTextView {
    weak var editor: NoteCardEditor?
    let localUndoManager = UndoManager()

    override var undoManager: UndoManager? { localUndoManager }

    override func cancelOperation(_ sender: Any?) { editor?.commit() }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
            editor?.commit()
            return
        }
        super.keyDown(with: event)
    }
}
