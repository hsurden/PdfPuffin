import AppKit
import PDFKit

/// Floating one-click markup bar shown near selected PDF text.
final class SelectionBarView: NSView {
    var onHighlight: ((NSColor) -> Void)?
    var onUnderline: (() -> Void)?
    var onStrikeout: (() -> Void)?
    var onNote: (() -> Void)?
    var onCopy: (() -> Void)?

    private(set) var highlightButtons: [NSButton] = []
    private var colorActions: [ObjectIdentifier: NSColor] = [:]

    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0, alpha: 0.14).cgColor
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -2)
            s.shadowColor = NSColor(white: 0, alpha: 0.18)
            return s
        }()

        let row = NSStackView()
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        // Yellow, Green, Blue, Red, Purple
        for idx in [2, 3, 4, 0, 5] {
            let (name, color) = AnnotColors.palette[idx]
            let b = NSButton(image: AnnotColors.swatch(color, size: 16), target: self, action: #selector(highlightClicked(_:)))
            b.isBordered = false
            b.refusesFirstResponder = true
            b.toolTip = "Highlight (\(name))"
            b.setAccessibilityLabel("Highlight \(name)")
            colorActions[ObjectIdentifier(b)] = color
            highlightButtons.append(b)
            row.addArrangedSubview(b)
        }

        let sep = ColorView(Theme.separator)
        sep.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 1),
            sep.heightAnchor.constraint(equalToConstant: 18),
        ])
        row.addArrangedSubview(sep)

        let actions: [(String, String, Selector)] = [
            ("underline", "Underline", #selector(underlineClicked)),
            ("strikethrough", "Strikeout", #selector(strikeoutClicked)),
            ("note.text", "Add Note", #selector(noteClicked)),
            ("doc.on.doc", "Copy Text", #selector(copyClicked)),
        ]
        for (sym, tip, sel) in actions {
            let b = iconButton(sym, tip: tip, target: self, action: sel, tint: .labelColor, size: 13, width: 26)
            row.addArrangedSubview(b)
        }

        addSubview(row)
        row.pinEdges(to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func highlightClicked(_ sender: NSButton) {
        if let c = colorActions[ObjectIdentifier(sender)] { onHighlight?(c) }
    }
    @objc private func underlineClicked() { onUnderline?() }
    @objc private func strikeoutClicked() { onStrikeout?() }
    @objc private func noteClicked() { onNote?() }
    @objc private func copyClicked() { onCopy?() }
}
