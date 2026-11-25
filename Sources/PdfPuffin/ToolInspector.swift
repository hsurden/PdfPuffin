import AppKit
import PDFKit

/// Per-tool opacity and fill, alongside AnnotColors' colour and width.
extension AnnotColors {
    static func opacity(for key: String) -> CGFloat {
        CGFloat((UserDefaults.standard.object(forKey: "opacity:" + key) as? Double) ?? 1)
    }
    static func setOpacity(_ o: CGFloat, for key: String) { UserDefaults.standard.set(Double(o), forKey: "opacity:" + key) }
    /// Fill colour index for rectangles/ovals; -1 = no fill.
    static func fillIndex(for key: String) -> Int { (UserDefaults.standard.object(forKey: "fill:" + key) as? Int) ?? -1 }
    static func setFill(_ i: Int, for key: String) { UserDefaults.standard.set(i, forKey: "fill:" + key) }
}

/// The right-hand panel PDF Expert shows for the armed tool ("Pen Tool",
/// "Rectangle Tool", "Text Tool", "Signatures"): its colour, width, opacity…
final class ToolInspector: NSView {
    weak var main: MainWindowController?
    private let stack = NSStackView()
    private let titleLabel = label("", size: 13, weight: .semibold)
    private(set) var shownKey: String?
    private(set) weak var editingAnnotation: PDFAnnotation?
    private weak var editingSelection: AnnotationSelection?
    private var sliderBeforeSnapshot: AnnotSnapshot?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.975, alpha: 1).cgColor
        let edge = ColorView(Theme.separator)
        edge.translatesAutoresizingMaskIntoConstraints = false
        let close = iconButton("xmark", tip: "Put the tool down (Esc)", target: nil,
                               action: #selector(MainWindowController.selectToolAction(_:)), tint: .secondaryLabelColor, size: 12, width: 26)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 14, right: 14)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = makeScroll(doc)
        for v in [edge, titleLabel, close, scroll] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 1),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var contentWidth: CGFloat { 222 }

    /// Rebuilds for the tool `key` ("highlight", "pen", "rectangle", "text", "signature"…).
    func show(key: String) {
        shownKey = key
        editingSelection = nil
        editingAnnotation = nil
        sliderBeforeSnapshot = nil
        sliderActions.removeAll(); sliderLabels.removeAll(); swatchActions.removeAll(); controlActions.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shape = ShapeTool(rawValue: key)
        titleLabel.stringValue = key == "signature" ? "Signatures" : "\(Self.title(for: key)) Tool"

        switch key {
        case "signature": buildSignatures(); return
        case "eraser":
            add(note("Click or drag over an annotation to remove it. Works on highlights, shapes, pen strokes, text, notes and signatures."))
            return
        case "text": buildText(); return
        default: break
        }
        if key == "date" { buildDate() }
        if key == "stamp" { buildStamp() }
        if let s = shape, s.isShape {
            add(section("SHAPE"))
            let row = NSStackView()
            row.spacing = 6
            for t in ShapeTool.shapes {
                let b = iconButton(t.symbol, tip: t.title, target: self, action: #selector(pickShape(_:)), tint: .labelColor, size: 15, width: 36)
                b.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
                b.wantsLayer = true
                b.layer?.cornerRadius = 5
                b.layer?.borderWidth = t == s ? 1.5 : 0
                b.layer?.borderColor = Theme.accent.cgColor
                row.addArrangedSubview(b)
            }
            add(row)
        }
        if shape?.hasWidth == true {
            add(section(shape == .pen ? "LINE WIDTH" : "STROKE WIDTH"))
            add(slider(value: Double(AnnotColors.width(for: key)), min: 0.5, max: 12, unit: "pt", fmt: "%.1f") { AnnotColors.setWidth(CGFloat($0), for: key) })
        }
        if key != "area" {
            add(section("OPACITY"))
            add(slider(value: Double(AnnotColors.opacity(for: key)) * 100, min: 10, max: 100, unit: "%", fmt: "%.0f") {
                AnnotColors.setOpacity(CGFloat($0 / 100), for: key)
            })
        }
        add(section(shape?.isShape == true && key != "area" ? "STROKE COLOR" : "COLOR"))
        let custom = AnnotColors.customColor(for: key).map { [("Custom", $0)] } ?? []
        add(swatches(selected: AnnotColors.index(for: key), allowNone: false, palette: AnnotColors.palette + custom) { [weak self] i in
            AnnotColors.set(i, for: key); self?.changed()
        })
        let pick = NSButton(title: "Custom Color…", target: self, action: #selector(controlTriggered(_:)))
        pick.controlSize = .small
        pick.refusesFirstResponder = true
        controlActions[ObjectIdentifier(pick)] = { [weak self] in self?.main?.customColorAction(nil) }
        add(pick)
        if key == "rectangle" || key == "oval" {
            add(section("FILL COLOR"))
            add(swatches(selected: AnnotColors.fillIndex(for: key), allowNone: true) { [weak self] i in
                AnnotColors.setFill(i, for: key); self?.changed()
            })
        }
        if key == "note" { add(note("Click anywhere on the page to place a sticky note.")) }
        if shape?.isShape == true { add(note("Drag on the page to draw. Hold ⇧ for a square, circle or straight line.")) }
        if shape == .pen { add(note("Drag on the page to draw.")) }
        if key == "date" { add(note("Click where the date goes. Double-click it later to edit; font and size follow the Text tool.")) }
        if key == "check" || key == "cross" { add(note("Click a box or line to place it. Select it afterwards to move or resize it.")) }
        if key == "stamp" { add(note("Click on the page to stamp it. Select it afterwards to move or resize it.")) }
        if ["highlight", "underline", "strikeOut"].contains(key) {
            add(note("Select text, or arm the tool and then select text."))
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikeOut": return "Strikeout"
        case "note": return "Note"
        default: return ShapeTool(rawValue: key)?.title ?? key.capitalized
        }
    }

    static func inspectorKey(for a: PDFAnnotation) -> String? {
        switch a.type ?? "" {
        case "Highlight": return "highlight"
        case "Underline": return "underline"
        case "StrikeOut": return "strikeOut"
        case "FreeText": return "text"
        case "Ink": return "pen"
        case "Line":
            if a.startLineStyle == .openArrow && a.endLineStyle == .openArrow { return "doubleArrow" }
            return a.endLineStyle == .openArrow ? "arrow" : "line"
        case "Square":
            let noBorder = (a.border?.lineWidth ?? 0) == 0
            let hasFill = a.interiorColor != nil && a.interiorColor != .clear
            return (noBorder && hasFill) ? "area" : "rectangle"
        case "Circle": return "oval"
        case "Text": return "note"
        default: return nil
        }
    }

    /// Rebuilds the inspector to edit an already-placed annotation.
    func show(selection sel: AnnotationSelection) {
        let a = sel.annotation
        guard let key = Self.inspectorKey(for: a) else { return }
        shownKey = nil
        editingSelection = sel
        editingAnnotation = a
        sliderBeforeSnapshot = nil
        sliderActions.removeAll(); sliderLabels.removeAll(); swatchActions.removeAll()
        controlActions.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = "Edit \(Self.title(for: key))"

        if key == "text" {
            buildEditText(a)
        } else {
            let shape = ShapeTool(rawValue: key)
            if shape?.hasWidth == true {
                add(section(shape == .pen ? "LINE WIDTH" : "STROKE WIDTH"))
                let lw = Double(a.border?.lineWidth ?? AnnotColors.width(for: key))
                add(slider(value: max(0.5, lw), min: 0.5, max: 12, unit: "pt", fmt: "%.1f") { [weak self] val in
                    let w = CGFloat(val)
                    self?.applyAnnotationEdit(name: "Change Width", live: true) { ann in
                        let b = ann.border ?? PDFBorder()
                        b.lineWidth = w
                        ann.border = b
                        if ann.type == "Ink" {
                            for p in ann.paths ?? [] { p.lineWidth = w }
                        }
                    }
                })
            }
            if key != "area" {
                add(section("OPACITY"))
                let curOp = currentOpacity(for: a, key: key)
                add(slider(value: Double(curOp) * 100, min: 10, max: 100, unit: "%", fmt: "%.0f") { [weak self] val in
                    let op = CGFloat(val / 100)
                    self?.applyAnnotationEdit(name: "Change Opacity", live: true) { ann in
                        let effective = key == "highlight" ? 0.55 * op : op
                        ann.color = ann.color.withAlphaComponent(effective)
                        if (key == "rectangle" || key == "oval"),
                           let fill = ann.interiorColor, fill != .clear {
                            ann.interiorColor = fill.withAlphaComponent(0.3 * op)
                        }
                    }
                })
            }
            add(section(shape?.isShape == true && key != "area" ? "STROKE COLOR" : "COLOR"))
            let currentColor = key == "area" ? a.interiorColor : a.color
            add(swatches(selected: colorIndex(for: currentColor), allowNone: false) { [weak self] idx in
                let base = AnnotColors.palette[idx].1
                self?.applyAnnotationEdit(name: "Change Color") { ann in
                    if key == "area" {
                        ann.color = .clear
                        ann.interiorColor = base.withAlphaComponent(0.35)
                    } else {
                        let op = self?.currentOpacity(for: ann, key: key) ?? 1
                        ann.color = base.withAlphaComponent(key == "highlight" ? 0.55 * op : op)
                    }
                }
            })
            if key == "rectangle" || key == "oval" {
                add(section("FILL COLOR"))
                let fillIdx = (a.interiorColor == nil || a.interiorColor == .clear) ? -1 : colorIndex(for: a.interiorColor)
                add(swatches(selected: fillIdx, allowNone: true) { [weak self] idx in
                    self?.applyAnnotationEdit(name: "Change Fill Color") { ann in
                        if idx < 0 {
                            ann.interiorColor = .clear
                        } else {
                            let op = self?.currentOpacity(for: ann, key: key) ?? 1
                            ann.interiorColor = AnnotColors.palette[idx].1.withAlphaComponent(0.3 * op)
                        }
                    }
                })
            }
            if ["highlight", "underline", "strikeOut", "note"].contains(key) {
                add(section("COMMENT"))
                let initial = key == "note" ? (a.contents ?? "") : NoteCardEditor.distinctComment(for: a, on: sel.page)
                let tv = NoteTextView()
                tv.isRichText = false
                tv.allowsUndo = true
                tv.font = .systemFont(ofSize: 12)
                tv.textColor = .labelColor
                tv.drawsBackground = false
                tv.textContainerInset = NSSize(width: 6, height: 6)
                tv.isVerticallyResizable = true
                tv.isHorizontallyResizable = false
                tv.textContainer?.widthTracksTextView = true
                tv.string = initial
                let box = NSScrollView()
                box.documentView = tv
                box.hasVerticalScroller = true
                box.autohidesScrollers = true
                box.wantsLayer = true
                box.layer?.backgroundColor = NSColor.white.cgColor
                box.layer?.cornerRadius = 6
                box.layer?.borderWidth = 1
                box.layer?.borderColor = Theme.separator.cgColor
                box.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    box.widthAnchor.constraint(equalToConstant: contentWidth),
                    box.heightAnchor.constraint(equalToConstant: 72),
                ])
                add(box)

                let saveBtn = NSButton(title: "Save Comment", target: self, action: #selector(controlTriggered(_:)))
                saveBtn.refusesFirstResponder = true
                saveBtn.controlSize = .small
                controlActions[ObjectIdentifier(saveBtn)] = { [weak self, weak tv] in
                    guard let self, let tv else { return }
                    let raw = tv.string
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.applyAnnotationEdit(name: "Edit Comment") { ann in
                        ann.contents = trimmed.isEmpty ? nil : raw
                        ann.modificationDate = Date()
                    }
                }
                let cardBtn = NSButton(title: "Open Note Card", target: self, action: #selector(controlTriggered(_:)))
                cardBtn.refusesFirstResponder = true
                cardBtn.controlSize = .small
                controlActions[ObjectIdentifier(cardBtn)] = { [weak sel] in
                    guard let sel, let doc = sel.doc else { return }
                    doc.openNoteCard(for: sel.annotation, on: sel.page, isNew: false)
                }
                let btnRow = NSStackView(views: [saveBtn, cardBtn])
                btnRow.spacing = 6
                add(btnRow)
            }
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        add(spacer)
        let del = NSButton(title: "Delete Annotation", target: self, action: #selector(deleteSelectedAnnotation))
        del.refusesFirstResponder = true
        del.controlSize = .small
        add(del)
    }

    private func buildEditText(_ a: PDFAnnotation) {
        let f = a.font ?? TextStyle.font(family: TextStyle.family, size: TextStyle.size, bold: TextStyle.bold, italic: TextStyle.italic)
        let family = f.familyName ?? TextStyle.family
        let size = f.pointSize
        let traits = NSFontManager.shared.traits(of: f)
        let isBold = traits.contains(.boldFontMask)
        let isItalic = traits.contains(.italicFontMask)

        func applyFont(newFamily: String = family, newSize: CGFloat = size, bold: Bool = isBold, italic: Bool = isItalic) {
            let nf = TextStyle.font(family: newFamily, size: newSize, bold: bold, italic: italic)
            applyAnnotationEdit(name: "Change Font") { ann in
                ann.font = nf
                let text = ann.contents ?? ""
                let needed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: nf])
                    .boundingRect(with: NSSize(width: max(ann.bounds.width - 8, 20), height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
                let minH = max(ceil(needed.height) + 6, nf.pointSize + 6)
                if ann.bounds.height < minH {
                    let top = ann.bounds.maxY
                    ann.bounds = NSRect(x: ann.bounds.minX, y: top - minH, width: ann.bounds.width, height: minH)
                }
            }
        }

        add(section("FONT"))
        let fontPop = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPop.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        fontPop.selectItem(withTitle: family)
        fontPop.target = self; fontPop.action = #selector(controlTriggered(_:))
        fontPop.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        controlActions[ObjectIdentifier(fontPop)] = { [weak fontPop] in
            if let fam = fontPop?.titleOfSelectedItem { applyFont(newFamily: fam) }
        }
        add(fontPop)

        let sizes = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]
        let sizePop = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePop.addItems(withTitles: sizes.map { "\($0) pt" })
        let nearest = sizes.min(by: { abs(CGFloat($0) - size) < abs(CGFloat($1) - size) }) ?? 14
        sizePop.selectItem(withTitle: "\(nearest) pt")
        sizePop.target = self; sizePop.action = #selector(controlTriggered(_:))
        controlActions[ObjectIdentifier(sizePop)] = { [weak sizePop] in
            let s = CGFloat(Double((sizePop?.titleOfSelectedItem ?? "14").replacingOccurrences(of: " pt", with: "")) ?? 14)
            applyFont(newSize: s)
        }

        let b = NSButton(title: "B", target: self, action: #selector(controlTriggered(_:)))
        b.font = .boldSystemFont(ofSize: 13); b.setButtonType(.pushOnPushOff); b.state = isBold ? .on : .off
        controlActions[ObjectIdentifier(b)] = { [weak b] in applyFont(bold: b?.state == .on) }

        let i = NSButton(title: "I", target: self, action: #selector(controlTriggered(_:)))
        i.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        i.setButtonType(.pushOnPushOff); i.state = isItalic ? .on : .off
        controlActions[ObjectIdentifier(i)] = { [weak i] in applyFont(italic: i?.state == .on) }

        for c in [fontPop, sizePop, b, i] as [NSControl] { c.refusesFirstResponder = true }
        let row = NSStackView(views: [sizePop, b, i]); row.spacing = 6
        add(row)

        add(section("TEXT COLOR"))
        add(swatches(selected: colorIndex(for: a.fontColor), allowNone: false) { [weak self] idx in
            self?.applyAnnotationEdit(name: "Change Text Color") { $0.fontColor = AnnotColors.palette[idx].1 }
        })
        add(section("BACKGROUND COLOR"))
        let hasWhite = (a.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0) > 0.5
        add(swatches(selected: hasWhite ? 0 : -1, allowNone: true, palette: [("White", .white)]) { [weak self] idx in
            self?.applyAnnotationEdit(name: "Change Background") { $0.color = idx == 0 ? .white : .clear }
        })
    }

    private func colorIndex(for c: NSColor?) -> Int {
        guard let c else { return -1 }
        return AnnotColors.palette.firstIndex(where: { $0.1.isClose(to: c) }) ?? -1
    }

    private func currentOpacity(for a: PDFAnnotation, key: String) -> CGFloat {
        let raw = a.color.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        let normalized = key == "highlight" ? raw / 0.55 : raw
        return min(1.0, max(0.1, normalized))
    }

    private func applyAnnotationEdit(name: String, live: Bool = false, mutate: (PDFAnnotation) -> Void) {
        guard let sel = editingSelection, let doc = sel.doc else { return }
        let a = sel.annotation
        if live {
            if sliderBeforeSnapshot == nil { sliderBeforeSnapshot = AnnotSnapshot(a) }
            mutate(a)
            doc.pdfView.refresh(a, on: sel.page)
            let eventType = NSApp.currentEvent?.type
            if eventType == .leftMouseUp || NSEvent.pressedMouseButtons == 0, let before = sliderBeforeSnapshot {
                sliderBeforeSnapshot = nil
                doc.recordChanged(a, on: sel.page, name: name, from: before, to: AnnotSnapshot(a))
            }
        } else {
            let before = AnnotSnapshot(a)
            mutate(a)
            doc.recordChanged(a, on: sel.page, name: name, from: before, to: AnnotSnapshot(a))
            show(selection: sel)
        }
    }

    @objc private func deleteSelectedAnnotation() {
        guard let sel = editingSelection else { return }
        let doc = sel.doc
        sel.delete()
        doc?.selection = nil
    }

    // MARK: text

    private func buildText() {
        add(section("FONT"))
        let fontPop = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPop.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        fontPop.selectItem(withTitle: TextStyle.family)
        fontPop.target = self; fontPop.action = #selector(fontChanged(_:))
        fontPop.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        add(fontPop)
        let sizes = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]
        let sizePop = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePop.addItems(withTitles: sizes.map { "\($0) pt" })
        let nearest = sizes.min(by: { abs(CGFloat($0) - TextStyle.size) < abs(CGFloat($1) - TextStyle.size) }) ?? 14
        sizePop.selectItem(withTitle: "\(nearest) pt")
        sizePop.target = self; sizePop.action = #selector(sizeChanged(_:))
        let b = NSButton(title: "B", target: self, action: #selector(boldChanged(_:)))
        b.font = .boldSystemFont(ofSize: 13); b.setButtonType(.pushOnPushOff); b.state = TextStyle.bold ? .on : .off
        let i = NSButton(title: "I", target: self, action: #selector(italicChanged(_:)))
        i.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        i.setButtonType(.pushOnPushOff); i.state = TextStyle.italic ? .on : .off
        for c in [fontPop, sizePop, b, i] as [NSControl] { c.refusesFirstResponder = true }
        let row = NSStackView(views: [sizePop, b, i]); row.spacing = 6
        add(row)
        add(section("TEXT COLOR"))
        add(swatches(selected: AnnotColors.index(for: "text"), allowNone: false) { [weak self] idx in
            AnnotColors.set(idx, for: "text"); self?.changed()
        })
        add(section("BACKGROUND COLOR"))
        add(swatches(selected: TextStyle.whiteBackground ? 0 : -1, allowNone: true, palette: [("White", .white)]) { [weak self] idx in
            TextStyle.whiteBackground = idx == 0; self?.changed()
        })
        add(note("Click on the page and type. Click elsewhere or press Esc to finish; double-click a text box to edit it."))
    }

    @objc private func fontChanged(_ p: NSPopUpButton) { TextStyle.family = p.titleOfSelectedItem ?? TextStyle.family; changed() }
    @objc private func sizeChanged(_ p: NSPopUpButton) {
        TextStyle.size = CGFloat(Double((p.titleOfSelectedItem ?? "14").replacingOccurrences(of: " pt", with: "")) ?? 14); changed()
    }
    @objc private func boldChanged(_ b: NSButton) { TextStyle.bold = b.state == .on; changed() }
    @objc private func italicChanged(_ b: NSButton) { TextStyle.italic = b.state == .on; changed() }

    // MARK: fill & sign

    private func buildDate() {
        add(section("FORMAT"))
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        for f in FillSign.dateFormats {
            pop.addItem(withTitle: FillSign.dateString(f))
            pop.lastItem?.representedObject = f
        }
        pop.selectItem(at: FillSign.dateFormats.firstIndex(of: FillSign.dateFormat) ?? 0)
        pop.target = self; pop.action = #selector(dateFormatChanged(_:))
        pop.refusesFirstResponder = true
        pop.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        add(pop)
    }
    @objc private func dateFormatChanged(_ p: NSPopUpButton) {
        if let f = p.selectedItem?.representedObject as? String { FillSign.dateFormat = f }
    }

    private func buildStamp() {
        add(section("STAMP"))
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.addItems(withTitles: FillSign.stamps)
        pop.selectItem(withTitle: FillSign.stamp)
        pop.target = self; pop.action = #selector(stampChanged(_:))
        pop.refusesFirstResponder = true
        pop.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        add(pop)
        let dated = NSButton(checkboxWithTitle: "Add today's date", target: self, action: #selector(stampDatedChanged(_:)))
        dated.state = FillSign.stampDated ? .on : .off
        dated.refusesFirstResponder = true
        add(dated)
    }
    @objc private func stampChanged(_ p: NSPopUpButton) { if let t = p.titleOfSelectedItem { FillSign.stamp = t } }
    @objc private func stampDatedChanged(_ b: NSButton) { FillSign.stampDated = b.state == .on }

    // MARK: signatures

    private func buildSignatures() {
        let sigs = SignatureStore.all()
        if sigs.isEmpty {
            add(note("No signatures yet. Import the ones saved in PDF Expert, or add an image of your signature."))
        }
        for s in sigs {
            let b = SignatureButton(image: s.thumbnail(width: contentWidth), target: self, action: #selector(pickSignature(_:)))
            b.signature = s
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor.white.cgColor
            b.layer?.cornerRadius = 6
            b.layer?.borderWidth = SignatureStore.selected?.id == s.id && main?.current?.shapeTool == .signature ? 2 : 0.5
            b.layer?.borderColor = (SignatureStore.selected?.id == s.id ? Theme.accent : NSColor(white: 0.8, alpha: 1)).cgColor
            b.refusesFirstResponder = true
            b.toolTip = "Drag onto a page, or click to choose this signature"
            let m = NSMenu()
            let del = m.addItem(withTitle: "Delete Signature", action: #selector(deleteSignature(_:)), keyEquivalent: "")
            del.target = self; del.representedObject = s.id
            b.menu = m
            b.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            add(b)
        }
        let addImg = NSButton(title: "Add Image of Signature…", target: self, action: #selector(addSignatureImage))
        let imp = NSButton(title: "Import from PDF Expert", target: self, action: #selector(importPDFExpert))
        for b in [addImg, imp] { b.refusesFirstResponder = true; b.controlSize = .small }
        add(addImg); add(imp)
        add(note("Drag a signature onto the page, or pick one and click the page. You can also draw a box to set its size."))
    }

    @objc private func pickSignature(_ b: SignatureButton) {
        SignatureStore.selected = b.signature
        main?.armTool(.signature)
    }
    @objc private func deleteSignature(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let s = SignatureStore.all().first(where: { $0.id == id }) else { return }
        SignatureStore.delete(s)
        show(key: "signature")
    }
    @objc private func addSignatureImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image, .pdf]
        if p.runModal() == .OK, let u = p.url, let s = SignatureStore.addImage(from: u) { SignatureStore.selected = s }
        show(key: "signature")
    }
    @objc private func importPDFExpert() {
        let n = SignatureStore.importFromPDFExpert()
        main?.flash(n == 0 ? "No new signatures found in PDF Expert" : "Imported \(n) signature\(n == 1 ? "" : "s") from PDF Expert")
        show(key: "signature")
    }

    // MARK: pieces

    @objc private func pickShape(_ b: NSButton) {
        guard let t = ShapeTool(rawValue: b.identifier?.rawValue ?? "") else { return }
        main?.armTool(t)
    }

    private func changed() {
        main?.current?.textEditor?.applyStyle()
        main?.current?.textEditor?.refocus()
        main?.updateToolbar()
        if let k = shownKey { show(key: k) }
    }

    private func add(_ v: NSView) { stack.addArrangedSubview(v) }

    private func section(_ t: String) -> NSView {
        let l = label(t, size: 10, weight: .semibold, color: .secondaryLabelColor)
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: v.leadingAnchor), l.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
                                     l.bottomAnchor.constraint(equalTo: v.bottomAnchor)])
        return v
    }

    private func note(_ t: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = contentWidth
        l.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return l
    }

    private var sliderActions: [ObjectIdentifier: (Double) -> Void] = [:]
    private var sliderLabels: [ObjectIdentifier: (NSTextField, String, String)] = [:]

    private func slider(value: Double, min: Double, max: Double, unit: String, fmt: String, set: @escaping (Double) -> Void) -> NSView {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderMoved(_:)))
        s.refusesFirstResponder = true
        s.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let l = label(String(format: fmt, value) + " " + unit, size: 11)
        sliderActions[ObjectIdentifier(s)] = set
        sliderLabels[ObjectIdentifier(s)] = (l, fmt, unit)
        let row = NSStackView(views: [s, l]); row.spacing = 8
        return row
    }

    @objc private func sliderMoved(_ s: NSSlider) {
        sliderActions[ObjectIdentifier(s)]?(s.doubleValue)
        if let (l, fmt, unit) = sliderLabels[ObjectIdentifier(s)] { l.stringValue = String(format: fmt, s.doubleValue) + " " + unit }
        main?.updateToolbar()
    }

    private var swatchActions: [ObjectIdentifier: (Int) -> Void] = [:]
    private var controlActions: [ObjectIdentifier: () -> Void] = [:]
    @objc private func controlTriggered(_ sender: AnyObject) { controlActions[ObjectIdentifier(sender)]?() }

    private func swatches(selected: Int, allowNone: Bool, palette: [(String, NSColor)] = AnnotColors.palette,
                          pick: @escaping (Int) -> Void) -> NSView {
        let row = NSStackView(); row.spacing = 5
        var items: [(Int, String, NSColor?)] = []
        if allowNone { items.append((-1, "None", nil)) }
        items += palette.enumerated().map { ($0.offset, $0.element.0, $0.element.1) }
        for (i, name, c) in items {
            let img = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { r in
                let inner = r.insetBy(dx: 3, dy: 3)
                if let c { c.setFill(); NSBezierPath(ovalIn: inner).fill() }
                else {
                    NSColor.white.setFill(); NSBezierPath(ovalIn: inner).fill()
                    NSColor.systemRed.setStroke()
                    let p = NSBezierPath(); p.move(to: NSPoint(x: inner.minX + 3, y: inner.minY + 3))
                    p.line(to: NSPoint(x: inner.maxX - 3, y: inner.maxY - 3)); p.lineWidth = 1.5; p.stroke()
                }
                NSColor(white: 0, alpha: 0.2).setStroke(); NSBezierPath(ovalIn: inner).stroke()
                if i == selected {
                    Theme.accent.setStroke()
                    let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75)); ring.lineWidth = 1.5; ring.stroke()
                }
                return true
            }
            let b = NSButton(image: img, target: self, action: #selector(swatchPicked(_:)))
            b.isBordered = false
            b.tag = i
            b.toolTip = name
            b.refusesFirstResponder = true
            swatchActions[ObjectIdentifier(b)] = pick
            row.addArrangedSubview(b)
        }
        return row
    }

    @objc private func swatchPicked(_ b: NSButton) { swatchActions[ObjectIdentifier(b)]?(b.tag) }
}

final class SignatureButton: NSButton, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("org.pdfpuffin.saved-signature")
    var signature: Signature?

    override func mouseDown(with event: NSEvent) {
        guard let window, let signature, let image else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = next.locationInWindow
            if next.type == .leftMouseUp {
                if bounds.contains(convert(point, from: nil)) { performClick(nil) }
                return
            }
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { continue }
            let item = NSPasteboardItem()
            item.setString(signature.id, forType: Self.dragType)
            let drag = NSDraggingItem(pasteboardWriter: item)
            let center = convert(point, from: nil)
            drag.setDraggingFrame(NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
            beginDraggingSession(with: [drag], event: next, source: self)
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? .copy : []
    }
}
