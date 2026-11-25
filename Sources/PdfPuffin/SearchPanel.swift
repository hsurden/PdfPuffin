import AppKit
import PDFKit

struct SearchHit {
    weak var doc: DocumentViewController?
    let pageIndex: Int
    let selection: PDFSelection
    let snippet: NSAttributedString
}

/// Right-hand search results panel, like PDF Expert's: "Found: N", previous / next,
/// a This Document / All Tabs switch, and results grouped by page.
final class SearchPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var main: MainWindowController?
    private(set) var hits: [SearchHit] = []
    private var rows: [Row] = []
    private(set) var currentHit = -1
    private(set) var query = ""
    enum Row { case header(String), hit(Int) }

    private let foundLabel = label("Found: 0", size: 13, weight: .semibold)
    let scope = NSSegmentedControl(labels: ["This Document", "All Tabs"], trackingMode: .selectOne, target: nil, action: nil)
    let matchCaseButton = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    let wholeWordButton = NSButton(checkboxWithTitle: "Whole Word", target: nil, action: nil)
    private let table = FocuslessTableView()
    private let empty = emptyLabel("")

    var allTabs: Bool { scope.selectedSegment == 1 }
    var matchCase: Bool {
        get { matchCaseButton.state == .on }
        set { matchCaseButton.state = newValue ? .on : .off }
    }
    var wholeWord: Bool {
        get { wholeWordButton.state == .on }
        set { wholeWordButton.state = newValue ? .on : .off }
    }
    /// The documents the current results came from.
    private(set) var searchedDocs: [ObjectIdentifier] = []

    private static let matchColor = NSColor(srgbRed: 1, green: 0.86, blue: 0.2, alpha: 1)
    private static let activeMatchColor = NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)

    private var searchID = 0
    private var pendingDocs: [DocumentViewController] = []
    private var activeDoc: DocumentViewController?
    private var searchObservers: [NSObjectProtocol] = []
    private var lastPageForActiveDoc = -1
    private var reloadWorkItem: DispatchWorkItem?
    private var autoJump = false
    private weak var preferredDoc: DocumentViewController?
    private var preferredPage = 0
    private var didAutoJump = false
    private(set) var isSearching = false
    private var docHighlights: [ObjectIdentifier: (doc: DocumentViewController, selections: [PDFSelection])] = [:]

    deinit { cancelSearch() }

    func cancelSearch() {
        searchID += 1
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        activeDoc?.document.cancelFindString()
        searchObservers.forEach(NotificationCenter.default.removeObserver)
        searchObservers.removeAll()
        pendingDocs.removeAll()
        activeDoc = nil
        isSearching = false
    }

    /// Forget the query, results, position and highlights.
    func reset() {
        cancelSearch()
        clearHighlights()
        query = ""; hits = []; rows = []; docHighlights = [:]; currentHit = -1; searchedDocs = []
        foundLabel.stringValue = "Found: 0"
        empty.stringValue = "Type in the Search box to find text."
        empty.isHidden = false
        table.reloadData()
    }

    func covers(_ d: DocumentViewController) -> Bool { searchedDocs.contains(ObjectIdentifier(d)) }

    /// A tab was closed: drop its hits (its highlights went with it).
    func documentClosed(_ d: DocumentViewController) {
        guard covers(d) else { return }
        main?.rerunSearch(keepPosition: true)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let prev = iconButton("chevron.up", tip: "Previous Result (⇧⌘G)", target: self, action: #selector(prevClicked), tint: .secondaryLabelColor, size: 13, width: 26)
        let next = iconButton("chevron.down", tip: "Next Result (⌘G)", target: self, action: #selector(nextClicked), tint: .secondaryLabelColor, size: 13, width: 26)
        let close = iconButton("xmark", tip: "Close Search (Esc)", target: self, action: #selector(closeClicked), tint: .secondaryLabelColor, size: 12, width: 26)
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(scopeChanged)
        scope.refusesFirstResponder = true
        scope.controlSize = .small
        scope.translatesAutoresizingMaskIntoConstraints = false
        scope.segmentDistribution = .fillEqually

        for b in [matchCaseButton, wholeWordButton] {
            b.target = self
            b.action = #selector(optionChanged)
            b.refusesFirstResponder = true
            b.controlSize = .small
        }
        let optionsRow = NSStackView(views: [matchCaseButton, wholeWordButton])
        optionsRow.spacing = 12
        optionsRow.translatesAutoresizingMaskIntoConstraints = false

        plainTable(table)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = true
        let scroll = makeScroll(table)
        let edge = ColorView(Theme.separator)
        edge.translatesAutoresizingMaskIntoConstraints = false
        let line = ColorView(Theme.separator)
        line.translatesAutoresizingMaskIntoConstraints = false

        for v in [edge, foundLabel, prev, next, close, scope, optionsRow, line, scroll, empty] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            foundLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            foundLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 22),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: foundLabel.centerYAnchor),
            next.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            next.centerYAnchor.constraint(equalTo: foundLabel.centerYAnchor),
            prev.trailingAnchor.constraint(equalTo: next.leadingAnchor),
            prev.centerYAnchor.constraint(equalTo: foundLabel.centerYAnchor),
            scope.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            scope.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scope.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            optionsRow.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 8),
            optionsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            line.topAnchor.constraint(equalTo: optionsRow.bottomAnchor, constant: 8),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 30),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: searching

    func search(_ q: String, in docs: [DocumentViewController],
                autoJump: Bool = false, preferredDoc: DocumentViewController? = nil, preferredPage: Int = 0) {
        cancelSearch()
        clearHighlights()
        query = q
        hits = []
        rows = []
        docHighlights = [:]
        currentHit = -1
        searchedDocs = docs.map { ObjectIdentifier($0) }
        self.autoJump = autoJump
        self.preferredDoc = preferredDoc
        self.preferredPage = preferredPage
        self.didAutoJump = false
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            foundLabel.stringValue = "Found: 0"
            empty.stringValue = "Type in the Search box to find text."
            empty.isHidden = false
            table.reloadData()
            return
        }
        isSearching = true
        pendingDocs = docs
        foundLabel.stringValue = "Searching…"
        empty.stringValue = "No matches for “\(trimmed)”."
        empty.isHidden = true
        table.reloadData()
        startNextDocumentSearch(query: trimmed, id: searchID)
    }

    private func startNextDocumentSearch(query trimmed: String, id: Int) {
        searchObservers.forEach(NotificationCenter.default.removeObserver)
        searchObservers.removeAll()
        guard searchID == id else { return }
        if pendingDocs.isEmpty {
            isSearching = false
            activeDoc = nil
            flushSearchResults()
            if autoJump && !didAutoJump && !hits.isEmpty {
                didAutoJump = true
                show(hit: 0)
            }
            return
        }
        let doc = pendingDocs.removeFirst()
        activeDoc = doc
        lastPageForActiveDoc = -1
        let nc = NotificationCenter.default
        let matchObs = nc.addObserver(forName: .PDFDocumentDidFindMatch, object: doc.document, queue: .main) { [weak self] note in
            guard let self, self.searchID == id,
                  let sel = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
                  let page = sel.pages.first else { return }
            if self.wholeWord, let text = page.string as NSString?, sel.numberOfTextRanges(on: page) > 0 {
                let r = sel.range(at: 0, on: page)
                if r.location != NSNotFound, NSMaxRange(r) <= text.length {
                    let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
                    if r.location > 0,
                       let prev = UnicodeScalar(text.character(at: r.location - 1)),
                       wordChars.contains(prev) { return }
                    if NSMaxRange(r) < text.length,
                       let next = UnicodeScalar(text.character(at: NSMaxRange(r))),
                       wordChars.contains(next) { return }
                }
            }
            let pi = doc.document.index(for: page)
            if pi != self.lastPageForActiveDoc {
                self.rows.append(.header(self.searchedDocs.count > 1 ? "\(doc.displayName) — Page \(pi + 1)" : "Page \(pi + 1)"))
                self.lastPageForActiveDoc = pi
            }
            let copy = sel.copy() as! PDFSelection
            copy.color = Self.matchColor
            self.rows.append(.hit(self.hits.count))
            self.hits.append(SearchHit(doc: doc, pageIndex: pi, selection: copy, snippet: Self.snippet(sel, page: page)))
            let docID = ObjectIdentifier(doc)
            self.docHighlights[docID, default: (doc, [])].selections.append(copy)
            if self.autoJump && !self.didAutoJump && doc === self.preferredDoc && pi >= self.preferredPage {
                self.didAutoJump = true
                self.flushSearchResults()
                self.show(hit: self.hits.count - 1)
            } else {
                self.scheduleRefresh()
            }
        }
        let endObs = nc.addObserver(forName: .PDFDocumentDidEndFind, object: doc.document, queue: .main) { [weak self] _ in
            guard let self, self.searchID == id else { return }
            self.applyHighlights(for: doc)
            self.startNextDocumentSearch(query: trimmed, id: id)
        }
        searchObservers = [matchObs, endObs]
        var opts: NSString.CompareOptions = [.diacriticInsensitive]
        if !matchCase { opts.insert(.caseInsensitive) }
        doc.document.beginFindString(trimmed, withOptions: opts)
    }

    private func scheduleRefresh() {
        guard reloadWorkItem == nil else { return }
        let id = searchID
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.searchID == id else { return }
            self.reloadWorkItem = nil
            self.flushSearchResults()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func flushSearchResults() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        if isSearching {
            foundLabel.stringValue = "Searching… (\(hits.count))"
        } else if currentHit >= 0 && !hits.isEmpty {
            foundLabel.stringValue = "\(currentHit + 1) of \(hits.count)"
        } else {
            foundLabel.stringValue = "Found: \(hits.count)"
        }
        empty.isHidden = !hits.isEmpty || isSearching
        table.reloadData()
        if currentHit >= 0, let row = rows.firstIndex(where: { if case .hit(let h) = $0 { return h == currentHit }; return false }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        highlightAll()
    }

    private func applyHighlights(for doc: DocumentViewController) {
        let selections = docHighlights[ObjectIdentifier(doc)]?.selections
        for pane in doc.readingPanes { pane.highlightedSelections = selections }
    }

    /// Text around the match, with the match bold on yellow. Ellipses mark the
    /// cut points so it is visible that this is an excerpt of the page.
    static func snippet(_ sel: PDFSelection, page: PDFPage) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        guard let text = page.string as NSString?, sel.numberOfTextRanges(on: page) > 0 else {
            return NSAttributedString(string: sel.string ?? "", attributes: base)
        }
        let r = sel.range(at: 0, on: page)
        guard r.location != NSNotFound, NSMaxRange(r) <= text.length else {
            return NSAttributedString(string: sel.string ?? "", attributes: base)
        }
        let start = max(0, r.location - 40)
        let end = min(text.length, NSMaxRange(r) + 60)
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: (start > 0 ? "…" : "") + clean(text.substring(with: NSRange(location: start, length: r.location - start))), attributes: base))
        var hl = base
        hl[.font] = NSFont.systemFont(ofSize: 12, weight: .bold)
        hl[.backgroundColor] = NSColor(srgbRed: 1, green: 0.87, blue: 0.3, alpha: 1)
        hl[.foregroundColor] = NSColor.black
        out.append(NSAttributedString(string: clean(text.substring(with: r)), attributes: hl))
        out.append(NSAttributedString(string: clean(text.substring(with: NSRange(location: NSMaxRange(r), length: end - NSMaxRange(r)))) + (end < text.length ? "…" : ""), attributes: base))
        return out
    }

    func highlightAll() {
        for (_, entry) in docHighlights {
            for pane in entry.doc.readingPanes { pane.highlightedSelections = entry.selections }
        }
    }

    func clearHighlights() {
        for d in main?.documentControllers ?? [] { for pane in d.readingPanes { pane.highlightedSelections = nil } }
    }

    func show(hit i: Int) {
        guard hits.indices.contains(i), let d = hits[i].doc else { return }
        let oldHit = currentHit
        if hits.indices.contains(oldHit) {
            hits[oldHit].selection.color = Self.matchColor
            if let oldDoc = hits[oldHit].doc, oldDoc !== d {
                applyHighlights(for: oldDoc)
            }
        }
        currentHit = i
        hits[i].selection.color = Self.activeMatchColor
        main?.select(controller: d)
        d.jump(to: hits[i].selection)
        applyHighlights(for: d)
        if let row = rows.firstIndex(where: { if case .hit(let h) = $0 { return h == i }; return false }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        foundLabel.stringValue = isSearching ? "Searching… (\(hits.count))" : "\(i + 1) of \(hits.count)"
    }

    func next() { if !hits.isEmpty { show(hit: (currentHit + 1) % hits.count) } else { NSSound.beep() } }
    func previous() { if !hits.isEmpty { show(hit: currentHit <= 0 ? hits.count - 1 : currentHit - 1) } else { NSSound.beep() } }

    @objc private func prevClicked() { previous() }
    @objc private func nextClicked() { next() }
    @objc private func closeClicked() { main?.closeSearch() }
    @objc private func scopeChanged() { main?.rerunSearch() }
    @objc private func optionChanged() { main?.rerunSearch() }
    @objc private func rowClicked() {
        guard table.clickedRow >= 0, case .hit(let h) = rows[table.clickedRow] else { return }
        show(hit: h)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .hit = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let t):
            let id = NSUserInterfaceItemIdentifier("searchHeader")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let l = label("", size: 11, weight: .semibold, color: .secondaryLabelColor)
                c.addSubview(l)
                c.textField = l
                NSLayoutConstraint.activate([
                    l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                    l.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -10),
                    l.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
                    l.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -4),
                ])
                return c
            }()
            v.textField?.stringValue = t
            return v
        case .hit(let i):
            let id = NSUserInterfaceItemIdentifier("searchHit")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = id
                let t = NSTextField(wrappingLabelWithString: "")
                t.maximumNumberOfLines = 0
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([
                    t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
                    t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10),
                    t.topAnchor.constraint(equalTo: c.topAnchor, constant: 7),
                    t.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -7),
                ])
                return c
            }()
            v.textField?.attributedStringValue = hits[i].snippet
            return v
        }
    }
}
