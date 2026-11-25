import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PacketSection {
    let document: PDFDocument
    let sourceName: String
    var title: String

    init(_ document: PDFDocument, name: String) {
        self.document = document
        sourceName = name
        title = name
    }
}

enum PacketError: LocalizedError {
    case invalidSection(String), copyFailed, destinationInUse

    var errorDescription: String? {
        switch self {
        case .invalidSection(let name): return "Could not include “\(name)”. Choose a readable PDF with pages and give its section a title."
        case .copyFailed: return "PdfPuffin could not create a complete copy of this PDF."
        case .destinationInUse: return "That file is open in PdfPuffin. Choose a different filename for the student copy."
        }
    }
}

enum ReadingPacket {
    static func merge(_ sections: [PacketSection]) throws -> PDFDocument {
        guard !sections.isEmpty else { throw PacketError.copyFailed }
        let result = PDFDocument()
        let outline = PDFOutline()
        for section in sections {
            let source = section.document
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, source.pageCount > 0, !source.isLocked else {
                throw PacketError.invalidSection(section.sourceName)
            }
            let start = result.pageCount
            for i in 0..<source.pageCount {
                guard let page = source.page(at: i)?.copy() as? PDFPage else { throw PacketError.copyFailed }
                result.insert(page, at: result.pageCount)
            }
            guard let first = result.page(at: start) else { throw PacketError.copyFailed }
            let bounds = first.bounds(for: .cropBox)
            let entry = PDFOutline()
            entry.label = title
            entry.destination = PDFDestination(page: first, at: NSPoint(x: bounds.minX, y: bounds.maxY))
            outline.insertChild(entry, at: outline.numberOfChildren)
        }
        result.outlineRoot = outline
        return result
    }

    static func writeCleanCopy(of source: PDFDocument, to url: URL, protecting openFiles: [URL]) throws {
        guard !(openFiles + [source.documentURL].compactMap { $0 }).contains(where: {
            DocumentViewController.sameFile($0, url)
        }) else { throw PacketError.destinationInUse }
        guard let bytes = source.dataRepresentation(), let copy = PDFDocument(data: bytes),
              !copy.isLocked, copy.pageCount == source.pageCount else { throw PacketError.copyFailed }
        for i in 0..<copy.pageCount {
            guard let page = copy.page(at: i) else { throw PacketError.copyFailed }
            for annotation in page.annotations { page.removeAnnotation(annotation) }
        }
        guard let clean = copy.dataRepresentation(), let verified = PDFDocument(data: clean),
              verified.pageCount == source.pageCount, (0..<verified.pageCount).allSatisfy({
                  verified.page(at: $0)?.annotations.isEmpty == true
              }) else { throw PacketError.copyFailed }
        try clean.write(to: url, options: .atomic)
    }
}

/// A modal list keeps the editable section titles attached to their source PDFs.
final class PacketDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let tabs: [DocumentViewController]
    private(set) var sections: [PacketSection] = []
    private let alert = NSAlert()
    private let table = NSTableView()
    private let titleField = NSTextField()
    private let tabMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let up = NSButton()
    private let down = NSButton()
    private let remove = NSButton()
    private var selection: Int { table.selectedRow }

    init(tabs: [DocumentViewController]) {
        self.tabs = tabs
        super.init()
        alert.messageText = "Merge Files into a Reading Packet"
        alert.informativeText = "Add PDFs or open tabs. Each section title becomes a clickable outline entry."
        alert.addButton(withTitle: "Create Packet")
        alert.addButton(withTitle: "Cancel")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 260))
        let column = NSTableColumn(identifier: .init("section"))
        column.width = 465
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 74, width: 490, height: 181))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        box.addSubview(scroll)
        let caption = NSTextField(labelWithString: "Section title")
        caption.frame = NSRect(x: 0, y: 44, width: 85, height: 20)
        box.addSubview(caption)
        titleField.frame = NSRect(x: 86, y: 42, width: 404, height: 24)
        titleField.delegate = self
        box.addSubview(titleField)
        let add = NSButton(title: "Add PDFs…", target: self, action: #selector(addFiles))
        add.frame = NSRect(x: 0, y: 2, width: 95, height: 30)
        box.addSubview(add)
        tabMenu.addItem(withTitle: "Add Tab")
        for (i, tab) in tabs.enumerated() {
            let item = NSMenuItem(title: tab.displayName, action: #selector(addTab(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            tabMenu.menu?.addItem(item)
        }
        tabMenu.isEnabled = !tabs.isEmpty
        tabMenu.frame = NSRect(x: 98, y: 2, width: 116, height: 30)
        box.addSubview(tabMenu)
        for (button, title, x, action) in [(up,"Up",230,#selector(moveUp)), (down,"Down",308,#selector(moveDown)), (remove,"Remove",386,#selector(removeSection))] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.frame = NSRect(x: x, y: 2, width: 78, height: 30)
            box.addSubview(button)
        }
        alert.accessoryView = box
        refreshSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        let s = sections[row]
        return "\(row + 1).  \(s.title)   ·   \(s.document.pageCount) pp.   ·   \(s.sourceName)"
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshSelection() }
    func controlTextDidChange(_ notification: Notification) {
        guard sections.indices.contains(selection) else { return }
        sections[selection].title = titleField.stringValue
        table.reloadData(forRowIndexes: [selection], columnIndexes: [0])
        validateTitles()
    }
    private func validateTitles() {
        alert.buttons[0].isEnabled = !sections.isEmpty && sections.allSatisfy {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private func refreshSelection() {
        let valid = sections.indices.contains(selection)
        titleField.isEnabled = valid
        titleField.stringValue = valid ? sections[selection].title : ""
        up.isEnabled = valid && selection > 0
        down.isEnabled = valid && selection < sections.count - 1
        remove.isEnabled = valid
        validateTitles()
    }
    private func reload(select index: Int) {
        table.reloadData()
        if sections.indices.contains(index) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        refreshSelection()
    }
    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var batch: [PacketSection] = []
        for url in panel.urls {
            let openTab = tabs.first { $0.fileURL.map { DocumentViewController.sameFile($0, url) } == true }
            guard let pdf = openTab?.document ?? PDFDocument(url: url), pdf.pageCount > 0, !pdf.isLocked else {
                let warning = NSAlert()
                warning.messageText = "Could not add “\(url.lastPathComponent)”."
                warning.informativeText = "For a password-protected PDF, unlock it in a tab first."
                warning.runModal()
                return
            }
            batch.append(PacketSection(pdf, name: url.deletingPathExtension().lastPathComponent))
        }
        sections.append(contentsOf: batch)
        reload(select: sections.count - 1)
    }
    @objc private func addTab(_ sender: NSMenuItem) {
        let tab = tabs[sender.tag]
        sections.append(PacketSection(tab.document, name: tab.displayName))
        reload(select: sections.count - 1)
    }
    @objc private func moveUp() { move(by: -1) }
    @objc private func moveDown() { move(by: 1) }
    private func move(by offset: Int) {
        let index = selection
        guard sections.indices.contains(index), sections.indices.contains(index + offset) else { return }
        sections.swapAt(index, index + offset)
        reload(select: index + offset)
    }
    @objc private func removeSection() {
        guard sections.indices.contains(selection) else { return }
        let index = selection
        sections.remove(at: index)
        reload(select: min(index, sections.count - 1))
    }
    func run() -> [PacketSection]? {
        alert.runModal() == .alertFirstButtonReturn ? sections : nil
    }
}
