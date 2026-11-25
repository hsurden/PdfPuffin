import AppKit

/// Dark tab strip in the title bar, drawn by hand so nothing in it can take
/// keyboard focus. Home tabs are narrow and show a house icon.
final class TabBarView: NSView {
    struct Item { let title: String; let dirty: Bool; let isHome: Bool }
    weak var main: MainWindowController?
    var items: [Item] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { needsDisplay = true } }
    private var hoverIndex: Int? { didSet { if oldValue != hoverIndex { needsDisplay = true } } }

    static let leftInset: CGFloat = 78          // room for the traffic lights
    static let homeWidth: CGFloat = 46
    static let plusWidth: CGFloat = 36

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) { hoverIndex = tabIndex(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }

    private func frames() -> [NSRect] {
        let docCount = items.filter { !$0.isHome }.count
        let homeCount = items.count - docCount
        let avail = bounds.width - Self.leftInset - Self.plusWidth - 8 - CGFloat(homeCount) * Self.homeWidth
        let w = docCount > 0 ? min(300, max(90, avail / CGFloat(docCount))) : 0
        var x = Self.leftInset
        return items.map { it in
            let width = it.isHome ? Self.homeWidth : w
            defer { x += width }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    private func closeRect(_ f: NSRect) -> NSRect {
        NSRect(x: f.maxX - 26, y: f.midY - 8, width: 16, height: 16)
    }

    private func plusRect() -> NSRect {
        let x = frames().last?.maxX ?? Self.leftInset
        return NSRect(x: x + 4, y: 0, width: Self.plusWidth, height: bounds.height)
    }

    private func tabIndex(at p: NSPoint) -> Int? { frames().firstIndex { $0.contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        Theme.tabBar.setFill()
        bounds.fill()
        let fs = frames()
        for (i, f) in fs.enumerated() {
            let it = items[i]
            let isSel = i == selected
            if isSel {
                Theme.tabActive.setFill()
                f.fill()
            } else if i + 1 < fs.count, i + 1 != selected {
                NSColor(white: 1, alpha: 0.12).setFill()
                NSRect(x: f.maxX - 0.5, y: 9, width: 1, height: f.height - 18).fill()
            }
            if it.isHome {
                let img = Theme.symbol("house.fill", 13).tinted(isSel ? Theme.tabText : Theme.tabTextInactive)
                img.draw(in: NSRect(x: f.midX - img.size.width / 2, y: f.midY - img.size.height / 2,
                                    width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                continue
            }
            let showClose = isSel || hoverIndex == i
            let title = (it.dirty ? "• " : "") + it.title
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: isSel ? Theme.tabText : Theme.tabTextInactive,
                .paragraphStyle: para,
            ]
            let textRect = NSRect(x: f.minX + 14, y: f.midY - 8.5, width: f.width - 14 - 34, height: 18)
            (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            if showClose {
                let img = Theme.symbol("xmark", 10, weight: .medium).tinted(Theme.tabTextInactive)
                let c = closeRect(f)
                img.draw(in: NSRect(x: c.midX - img.size.width / 2, y: c.midY - img.size.height / 2,
                                    width: img.size.width, height: img.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let p = plusRect()
        let plus = Theme.symbol("plus", 13).tinted(Theme.tabTextInactive)
        plus.draw(in: NSRect(x: p.midX - plus.size.width / 2, y: p.midY - plus.size.height / 2,
                             width: plus.size.width, height: plus.size.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabIndex(at: p) {
            if !items[i].isHome, closeRect(frames()[i]).contains(p), (i == selected || hoverIndex == i) {
                main?.closeTab(at: i)
            } else if event.clickCount == 1 {
                main?.selectTab(i)
                if !items[i].isHome, items.count > 1, let window {
                    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                        if next.type == .leftMouseUp { break }
                        let pt = convert(next.locationInWindow, from: nil)
                        if !bounds.insetBy(dx: -20, dy: -28).contains(pt) {
                            main?.detachTab(at: i, screenPoint: NSEvent.mouseLocation)
                            return
                        }
                    }
                }
            }
            return
        }
        if plusRect().contains(p) { main?.newHomeTab(nil); return }
        if event.clickCount == 2 { window?.performZoom(nil); return }
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = tabIndex(at: p) else { return nil }
        let m = NSMenu()
        if !items[i].isHome && items.count > 1 {
            let move = m.addItem(withTitle: "Move Tab to New Window", action: #selector(moveTabClicked(_:)), keyEquivalent: "")
            move.target = self; move.representedObject = i
        }
        let close = m.addItem(withTitle: "Close Tab", action: #selector(closeTabClicked(_:)), keyEquivalent: "")
        close.target = self; close.representedObject = i
        if items.count > 1 {
            let others = m.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabsClicked(_:)), keyEquivalent: "")
            others.target = self; others.representedObject = i
        }
        return m
    }

    @objc private func moveTabClicked(_ item: NSMenuItem) {
        if let i = item.representedObject as? Int { main?.detachTab(at: i) }
    }
    @objc private func closeTabClicked(_ item: NSMenuItem) {
        if let i = item.representedObject as? Int { main?.closeTab(at: i) }
    }
    @objc private func closeOtherTabsClicked(_ item: NSMenuItem) {
        if let i = item.representedObject as? Int { main?.selectTab(i); main?.closeOtherTabs(nil) }
    }

    override func otherMouseDown(with event: NSEvent) {   // middle-click closes
        if let i = tabIndex(at: convert(event.locationInWindow, from: nil)) { main?.closeTab(at: i) }
    }
}
