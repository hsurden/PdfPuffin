import AppKit
import PDFKit

/// The Home tab: an "Open Files" drop zone and a grid of recent files,
/// after PDF Expert's Home screen.
final class HomeView: NSView {
    weak var main: MainWindowController?
    private let stack = NSStackView()
    private let recentsGrid = NSStackView()
    private let recentsTitle = label("Recents", size: 22, weight: .bold)
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.pinEdges(to: self)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -40),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: 860),
        ])

        let title = label("Home", size: 34, weight: .bold)
        let drop = DropZone()
        drop.onDrop = { [weak self] urls in self?.main?.open(urls: urls) }
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.heightAnchor.constraint(equalToConstant: 230).isActive = true

        let icon = NSImageView(image: Theme.symbol("doc.richtext", 54, weight: .light))
        icon.contentTintColor = Theme.accent.withAlphaComponent(0.55)
        let open = NSButton(title: "Open Files", target: nil, action: #selector(MainWindowController.openDocumentAction(_:)))
        open.bezelStyle = .push
        open.bezelColor = Theme.accent
        open.controlSize = .large
        open.refusesFirstResponder = true
        let clip = NSButton(title: "New from Clipboard", target: nil, action: #selector(MainWindowController.newFromClipboard(_:)))
        clip.bezelStyle = .push
        clip.controlSize = .large
        clip.refusesFirstResponder = true
        let buttons = NSStackView(views: [open, clip])
        buttons.spacing = 10
        let hint = label("or drop PDF or image files here", size: 14, color: Theme.accent)
        let inner = NSStackView(views: [icon, buttons, hint])
        inner.orientation = .vertical
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        drop.addSubview(inner)
        NSLayoutConstraint.activate([inner.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
                                     inner.centerYAnchor.constraint(equalTo: drop.centerYAnchor)])

        clearButton.isBordered = false
        clearButton.contentTintColor = Theme.accent
        clearButton.target = self
        clearButton.action = #selector(clearRecents)
        clearButton.refusesFirstResponder = true
        let recentsHeader = NSStackView(views: [recentsTitle, NSView(), clearButton])
        recentsHeader.translatesAutoresizingMaskIntoConstraints = false
        recentsHeader.widthAnchor.constraint(equalToConstant: 860).isActive = true

        recentsGrid.orientation = .vertical
        recentsGrid.alignment = .leading
        recentsGrid.spacing = 18

        for v in [title, drop, recentsHeader, recentsGrid] as [NSView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(36, after: drop)
        drop.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        recentsGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = (main?.recentURLs ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
        clearButton.isHidden = urls.isEmpty
        if urls.isEmpty {
            recentsGrid.addArrangedSubview(label("Files you open appear here.", size: 13, color: .secondaryLabelColor))
            return
        }
        var row: NSStackView?
        for (i, u) in urls.enumerated() {
            if i % 6 == 0 {
                row = NSStackView()
                row!.spacing = 22
                row!.alignment = .top
                recentsGrid.addArrangedSubview(row!)
            }
            let item = RecentItem(url: u)
            item.onOpen = { [weak self] in self?.main?.open(urls: [u]) }
            row!.addArrangedSubview(item)
        }
    }

    @objc private func clearRecents() { main?.clearRecents(nil) }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class RecentItem: NSView {
    var onOpen: (() -> Void)?
    private let imageView = NSImageView()
    init(url: URL) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 125).isActive = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.borderColor = NSColor(white: 0.85, alpha: 1).cgColor
        imageView.layer?.borderWidth = 1
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(wrappingLabelWithString: url.deletingPathExtension().lastPathComponent)
        name.alignment = .center
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = url.path
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView); addSubview(name)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 112),
            imageView.heightAnchor.constraint(equalToConstant: 145),
            name.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = url.path
        DispatchQueue.main.async { [weak self] in
            if let page = PDFDocument(url: url)?.page(at: 0) {
                self?.imageView.image = page.thumbnail(of: NSSize(width: 224, height: 290), for: .cropBox)
            } else {
                self?.imageView.image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onOpen?() }
}

final class DropZone: NSView {
    var onDrop: (([URL]) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let bg = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        NSColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: hovering ? 1 : 0.8).setFill()
        bg.fill()
        let dash = NSBezierPath(roundedRect: r.insetBy(dx: 8, dy: 8), xRadius: 10, yRadius: 10)
        dash.setLineDash([10, 7], count: 2, phase: 0)
        dash.lineWidth = 2
        Theme.accent.withAlphaComponent(hovering ? 0.8 : 0.35).setStroke()
        dash.stroke()
    }
    private func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovering = !urls(sender).isEmpty
        return hovering ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovering = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovering = false
        let u = urls(sender)
        onDrop?(u)
        return !u.isEmpty
    }
}
