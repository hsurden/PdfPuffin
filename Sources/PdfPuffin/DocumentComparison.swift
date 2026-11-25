import AppKit
import PDFKit

/// A comparison sheet takes snapshots so working with a form in either preview
/// cannot modify the source tab. Each pane starts at that tab's reading position.
final class ComparisonPane: NSStackView {
    let pdf = PDFView()
    let picker = NSPopUpButton()
    let tabs: [DocumentViewController]
    var changed: (() -> Void)?
    var clip: NSClipView? { pdf.documentView?.enclosingScrollView?.contentView }

    init(tabs: [DocumentViewController], index: Int) {
        self.tabs = tabs
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        for tab in tabs {
            let item = NSMenuItem(title: tab.displayName, action: nil, keyEquivalent: "")
            item.toolTip = tab.fileURL?.path
            picker.menu?.addItem(item)
        }
        picker.selectItem(at: index)
        picker.target = self
        picker.action = #selector(loadDocument)
        let minus = NSButton(title: "−", target: self, action: #selector(zoomOut))
        let plus = NSButton(title: "+", target: self, action: #selector(zoomIn))
        minus.setAccessibilityLabel("Zoom out")
        plus.setAccessibilityLabel("Zoom in")
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [picker, minus, plus])
        addArrangedSubview(bar)
        addArrangedSubview(pdf)
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        loadDocument()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func loadDocument() {
        let tab = tabs[picker.indexOfSelectedItem]
        pdf.document = tab.document.dataRepresentation().flatMap { PDFDocument(data: $0) }
        pdf.autoScales = false
        pdf.scaleFactor = tab.pdfView.scaleFactor
        restorePosition()
        changed?()
    }
    func restorePosition() {
        let tab = tabs[picker.indexOfSelectedItem]
        guard let page = pdf.document?.page(at: tab.currentPageIndex) else { return }
        if let dest = tab.pdfView.currentDestination, dest.page === tab.pdfView.currentPage {
            pdf.go(to: PDFDestination(page: page, at: dest.point))
        } else { pdf.go(to: page) }
    }
    @objc private func zoomOut() { pdf.zoomOut(nil) }
    @objc private func zoomIn() { pdf.zoomIn(nil) }
}

final class DocumentComparison: NSObject {
    let window: NSWindow
    let split = NSSplitView()
    let panes: [ComparisonPane]
    let sync = NSButton(checkboxWithTitle: "Sync Scroll and Zoom", target: nil, action: nil)
    private var observers: [NSObjectProtocol] = []
    private var origins = [NSPoint.zero, NSPoint.zero]
    private var updating = false

    convenience init(tabs: [DocumentViewController], current: DocumentViewController) {
        let i = tabs.firstIndex { $0 === current } ?? 0
        self.init(tabs: tabs, left: i, right: (i + 1) % tabs.count)
    }

    /// `left` / `right` index `tabs` (top / bottom when the panes are stacked).
    init(tabs: [DocumentViewController], left: Int, right: Int) {
        panes = [ComparisonPane(tabs: tabs, index: left), ComparisonPane(tabs: tabs, index: right)]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Compare Documents"
        window.minSize = NSSize(width: 560, height: 340)
        split.isVertical = true
        split.dividerStyle = .thin
        for pane in panes {
            split.addArrangedSubview(pane)
            pane.changed = { [weak self] in
                self?.sync.state = .off
                self?.observePanes()
            }
        }
        let orientation = NSSegmentedControl(labels: ["Vertical", "Horizontal"], trackingMode: .selectOne,
                                             target: self, action: #selector(changeDirection(_:)))
        orientation.selectedSegment = 0
        sync.target = self
        sync.action = #selector(toggleSync)
        let swap = NSButton(title: "Swap Sides", target: self, action: #selector(swapSides))
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.keyEquivalent = "\u{1b}"
        let bar = NSStackView(views: [orientation, sync, swap, NSView(), done])
        let root = window.contentView!
        for v in [bar, split] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        root.layoutSubtreeIfNeeded()
        balance()
        panes.forEach { $0.restorePosition() }
        observePanes()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    @objc private func close() { window.sheetParent?.endSheet(window) }

    private func balance() {
        split.adjustSubviews()
        split.setPosition(((split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness) / 2, ofDividerAt: 0)
    }
    @objc func changeDirection(_ sender: NSSegmentedControl) {
        updating = true
        split.isVertical = sender.selectedSegment == 0
        balance()
        resetOrigins()
        updating = false
    }
    @objc func swapSides() {
        guard let first = split.arrangedSubviews.first else { return }
        updating = true
        first.removeFromSuperview()
        split.addArrangedSubview(first)
        balance()
        resetOrigins()
        updating = false
    }
    private func resetOrigins() {
        origins = panes.map { $0.clip?.bounds.origin ?? .zero }
    }
    @objc func toggleSync() {
        if sync.state == .on {
            updating = true
            panes[1].pdf.scaleFactor = panes[0].pdf.scaleFactor
            updating = false
        }
        resetOrigins()
    }
    private func observePanes() {
        let nc = NotificationCenter.default
        observers.forEach(nc.removeObserver)
        observers.removeAll()
        resetOrigins()
        for (i, pane) in panes.enumerated() {
            guard let clip = pane.clip else { continue }
            clip.postsBoundsChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.synchronize(from: i, zoom: false)
            })
            observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pane.pdf, queue: .main) { [weak self] _ in
                self?.synchronize(from: i, zoom: true)
            })
        }
    }
    private func synchronize(from i: Int, zoom: Bool) {
        guard !updating, sync.state == .on, let source = panes[i].clip, let other = panes[1-i].clip else { return }
        updating = true
        defer { resetOrigins(); updating = false }
        if zoom {
            panes[1-i].pdf.scaleFactor = panes[i].pdf.scaleFactor
        } else {
            let dx = source.bounds.minX - origins[i].x, dy = source.bounds.minY - origins[i].y
            let proposed = other.bounds.offsetBy(dx: dx, dy: dy)
            other.scroll(to: other.constrainBoundsRect(proposed).origin)
            other.enclosingScrollView?.reflectScrolledClipView(other)
        }
    }
}
