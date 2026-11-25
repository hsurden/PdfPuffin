import AppKit

/// Colours and small UI helpers, measured from PDF Expert 3.13 screenshots.
enum Theme {
    static let tabBar = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 1)
    static let tabActive = NSColor(srgbRed: 0.205, green: 0.205, blue: 0.215, alpha: 1)
    static let tabText = NSColor(white: 0.93, alpha: 1)
    static let tabTextInactive = NSColor(white: 0.60, alpha: 1)
    static let toolbar = NSColor(srgbRed: 0.205, green: 0.205, blue: 0.215, alpha: 1)
    static let toolbarSelected = NSColor(white: 0.97, alpha: 1)
    static let toolbarIcon = NSColor(white: 0.88, alpha: 1)
    static let toolRow = NSColor(white: 0.965, alpha: 1)
    static let sidebar = NSColor(white: 0.955, alpha: 1)
    static let pageBG = NSColor(white: 0.905, alpha: 1)
    static let accent = NSColor(srgbRed: 0.24, green: 0.53, blue: 1.0, alpha: 1)
    static let badgeBlue = NSColor(srgbRed: 0.42, green: 0.65, blue: 0.98, alpha: 1)
    static let separator = NSColor(white: 0.84, alpha: 1)
    static let pill = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 0.96)

    static func symbol(_ name: String, _ size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: name)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
        return img.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? img
    }
}

/// A borderless icon button that never takes keyboard focus.
func iconButton(_ symbol: String, tip: String, target: AnyObject?, action: Selector?,
                tint: NSColor, size: CGFloat = 15, width: CGFloat = 30) -> NSButton {
    let b = NSButton(image: Theme.symbol(symbol, size), target: target, action: action)
    b.isBordered = false
    b.imagePosition = .imageOnly
    b.contentTintColor = tint
    b.toolTip = tip
    b.refusesFirstResponder = true
    b.translatesAutoresizingMaskIntoConstraints = false
    b.widthAnchor.constraint(equalToConstant: width).isActive = true
    b.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return b
}

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.translatesAutoresizingMaskIntoConstraints = false
    l.refusesFirstResponder = true
    return l
}

extension NSView {
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

/// Plain coloured view.
final class ColorView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }  // not dirtyRect: since macOS 14 it can extend past bounds
}
