import AppKit
import AVFoundation
import PDFKit

/// Read Aloud, like Word's: starts at the selection, at a right-clicked spot, or at the top
/// of the current page, and keeps going through the document sentence by sentence,
/// turning pages and highlighting the word being spoken. A translucent bar at the bottom
/// of the page area has previous sentence, pause / resume, next sentence and stop.
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    private let synth = AVSpeechSynthesizer()
    private(set) weak var doc: DocumentViewController?
    private(set) var pageIndex = 0
    private var pageText: NSString = ""
    private var sentences: [NSRange] = []
    private(set) var sentenceIndex = 0
    /// Bumped whenever we interrupt, so a late "finished" from the old sentence is ignored.
    private var generation = 0
    private var savedHighlights: [PDFSelection]?

    /// A reading session is open (speaking or paused).
    private(set) var isActive = false
    private(set) var isPaused = false
    /// 0 mutes the voice (tests); reading otherwise behaves the same.
    var volume: Float = 1
    var isSpeaking: Bool { isActive }

    override init() { super.init(); synth.delegate = self }

    /// Reading speed from 1.0× to 2.0× (remembered).
    var speed: Double {
        get { let v = UserDefaults.standard.double(forKey: "readAloudSpeedFactor"); return v == 0 ? 1 : min(max(v, 1), 2) }
        set { UserDefaults.standard.set(min(max(newValue, 1), 2), forKey: "readAloudSpeedFactor") }
    }

    /// Apple's rate scale isn't linear. These pairs (speed, rate) were measured by timing
    /// a sample sentence; speeds in between are interpolated.
    static let calibration: [(speed: Double, rate: Float)] = [
        (1.0, 0.50), (1.29, 0.55), (1.43, 0.58), (1.59, 0.60), (1.72, 0.62), (1.83, 0.65), (2.11, 0.68),
    ]
    static func rate(for speed: Double) -> Float {
        let s = min(max(speed, 1), 2)
        for (a, b) in zip(calibration, calibration.dropFirst()) where s <= b.speed {
            let t = Float((s - a.speed) / (b.speed - a.speed))
            return a.rate + t * (b.rate - a.rate)
        }
        return calibration.last!.rate
    }

    /// New speed; the current sentence starts again at it.
    func setSpeed(_ value: Double) {
        speed = (value * 10).rounded() / 10
        if isActive && !isPaused { restart() } else { doc?.readAloudBar.update() }
    }

    // MARK: starting and stopping

    /// From the start of the selection if there is one, else from the top of the current page.
    func start(_ d: DocumentViewController) {
        if let sel = d.pdfView.currentSelection, let page = sel.pages.first,
           !(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sel.numberOfTextRanges(on: page) > 0 {
            let r = sel.range(at: 0, on: page)
            start(d, page: d.document.index(for: page), character: r.location)
        } else {
            start(d, page: d.currentPageIndex, character: 0)
        }
    }

    /// From the sentence holding `character` on `page` (or the next one with text).
    func start(_ d: DocumentViewController, page: Int, character: Int) {
        stop()
        doc = d
        savedHighlights = d.pdfView.highlightedSelections
        d.pdfView.clearSelection()
        isActive = true
        isPaused = false
        guard load(page: page, startingAt: character) else { finish(); return }
        d.readAloudBar.show()
        speakCurrent()
    }

    /// Where to start reading for a point on the page: the sentence on that line (the
    /// one under or left of the point when a line holds several), else the first
    /// sentence below it. (PDFKit's characterIndex(at:) returns NSNotFound beside the
    /// text, and the line break that ends a sentence sits at the start of the next line.)
    static func characterIndex(on page: PDFPage, at point: NSPoint) -> Int {
        let text = (page.string ?? "") as NSString
        var onLine: Int?, firstOnLine: Int?, below: Int?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .bySentences) { s, r, _, _ in
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let lines = page.selection(for: r)?.selectionsByLine() else { return }
            for line in lines {
                let b = line.bounds(for: page)
                guard b.width > 0 else { continue }
                if b.minY - 2 <= point.y && point.y <= b.maxY + 2 {
                    if firstOnLine == nil { firstOnLine = r.location }
                    if b.minX <= point.x + 2 { onLine = r.location }
                } else if below == nil, b.maxY < point.y {
                    below = r.location
                }
            }
        }
        return onLine ?? firstOnLine ?? below ?? 0
    }

    func stop() {
        generation += 1
        current = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        guard isActive else { return }
        finish()
    }

    private func finish() {
        isActive = false
        isPaused = false
        if let d = doc {
            d.pdfView.highlightedSelections = savedHighlights
            d.readAloudBar.hide()
        }
        savedHighlights = nil
    }

    // MARK: controls

    func pauseOrResume() {
        guard isActive else { return }
        if isPaused {
            isPaused = false
            if synth.isPaused { synth.continueSpeaking() } else { speakCurrent() }
        } else {
            isPaused = true
            synth.pauseSpeaking(at: .word)
        }
        doc?.readAloudBar.update()
    }

    /// Back one sentence (or to the start of this one if it has only just begun).
    func previous() {
        guard isActive, let d = doc else { return }
        if sentenceIndex > 0 {
            sentenceIndex -= 1
        } else {
            var p = pageIndex - 1
            while p >= 0 {
                if load(page: p, startingAt: 0) { sentenceIndex = sentences.count - 1; break }
                p -= 1
            }
            if p < 0 { _ = load(page: d.currentPageIndex, startingAt: 0) }
        }
        restart()
    }

    func next() {
        guard isActive else { return }
        if !advance() { stop(); return }
        restart()
    }

    private func restart() {
        generation += 1
        current = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        isPaused = false
        speakCurrent()
        doc?.readAloudBar.update()
    }

    // MARK: reading

    /// Loads a page's sentences and picks the one containing `character`; false if the
    /// page (and every later one) has no text.
    private func load(page: Int, startingAt character: Int) -> Bool {
        guard let d = doc else { return false }
        var p = page, char = character
        while p < d.pageCount {
            let text = (d.document.page(at: p)?.string ?? "") as NSString
            var found: [NSRange] = []
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .bySentences) { s, r, _, _ in
                if let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { found.append(r) }
            }
            if !found.isEmpty {
                pageIndex = p
                pageText = text
                sentences = found
                sentenceIndex = found.lastIndex { $0.location <= char } ?? 0
                return true
            }
            p += 1; char = 0          // scans without text: run Recognize Text to read them
        }
        return false
    }

    /// Moves to the next sentence, crossing pages; false at the end of the document.
    private func advance() -> Bool {
        if sentenceIndex + 1 < sentences.count { sentenceIndex += 1; return true }
        return load(page: pageIndex + 1, startingAt: 0)
    }

    private func speakCurrent() {
        guard let d = doc, sentences.indices.contains(sentenceIndex) else { stop(); return }
        if d.currentPageIndex != pageIndex { d.jump(toPage: pageIndex) }
        let r = sentences[sentenceIndex]
        highlight(r)
        let u = AVSpeechUtterance(string: pageText.substring(with: r))
        u.rate = Self.rate(for: speed)
        u.volume = volume
        current = u
        synth.speak(u)
        d.readAloudBar.update()
    }
    /// The sentence being spoken; finish and word callbacks for any other are ignored
    /// (skipping with ⏮ / ⏭ interrupts the old one, which can still report back).
    private var current: AVSpeechUtterance?

    private func highlight(_ r: NSRange) {
        guard let d = doc, let page = d.document.page(at: pageIndex), let sel = page.selection(for: r) else { return }
        sel.color = NSColor.systemYellow.withAlphaComponent(0.45)
        d.pdfView.highlightedSelections = [sel]
        let b = sel.bounds(for: page)
        let visible = d.pdfView.convert(d.pdfView.bounds, to: page)
        if !visible.contains(b) { d.pdfView.go(to: b, on: page) }
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.isActive, utterance === self.current, let d = self.doc, self.sentences.indices.contains(self.sentenceIndex),
                  let page = d.document.page(at: self.pageIndex) else { return }
            let s = self.sentences[self.sentenceIndex]
            let word = NSRange(location: s.location + characterRange.location, length: characterRange.length)
            guard let sentence = page.selection(for: s), let w = page.selection(for: word) else { return }
            sentence.color = NSColor.systemYellow.withAlphaComponent(0.3)
            w.color = NSColor.systemOrange.withAlphaComponent(0.55)
            d.pdfView.highlightedSelections = [sentence, w]
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.isActive, utterance === self.current, !self.isPaused else { return }
            if self.advance() { self.speakCurrent() } else { self.stop() }
        }
    }
}

/// The translucent bar at the bottom of the page area while reading aloud.
final class ReadAloudBar: NSVisualEffectView {
    private let playPause: NSButton
    /// Type a speed from 1 to 2, then click Speed (or press Return).
    private let speedField = NSTextField(string: "1.0")
    private let speedButton = NSButton(title: "Speed", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "Reading aloud")

    init() {
        playPause = iconButton("pause.fill", tip: "Pause", target: nil, action: nil, tint: .labelColor, size: 15, width: 34)
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        let back = iconButton("backward.fill", tip: "Previous sentence", target: self, action: #selector(backClicked), tint: .labelColor, size: 14, width: 34)
        playPause.target = self; playPause.action = #selector(playPauseClicked)
        let fwd = iconButton("forward.fill", tip: "Next sentence", target: self, action: #selector(forwardClicked), tint: .labelColor, size: 14, width: 34)
        let close = iconButton("xmark", tip: "Stop reading", target: self, action: #selector(closeClicked), tint: .secondaryLabelColor, size: 11, width: 28)
        speedField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        speedField.alignment = .center
        speedField.controlSize = .small
        speedField.toolTip = "Reading speed from 1 to 2 (for example 1.3)"
        speedField.target = self; speedField.action = #selector(applySpeed)     // Return applies it
        speedField.translatesAutoresizingMaskIntoConstraints = false
        speedField.widthAnchor.constraint(equalToConstant: 42).isActive = true
        speedButton.bezelStyle = .rounded
        speedButton.controlSize = .small
        speedButton.refusesFirstResponder = true
        speedButton.target = self; speedButton.action = #selector(applySpeed)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, back, playPause, fwd, speedField, speedButton, close])
        row.spacing = 6
        row.setCustomSpacing(12, after: label)
        row.setCustomSpacing(12, after: fwd)
        row.setCustomSpacing(4, after: speedField)
        row.setCustomSpacing(6, after: speedButton)
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pinEdges(to: self)
        setAccessibilityLabel("Read Aloud controls")
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() { isHidden = false; update() }
    func hide() { isHidden = true }

    func update() {
        let paused = ReadAloud.shared.isPaused
        playPause.image = Theme.symbol(paused ? "play.fill" : "pause.fill", 15)
        playPause.toolTip = paused ? "Resume" : "Pause"
        label.stringValue = paused ? "Paused" : "Reading aloud"
        if speedField.currentEditor() == nil { speedField.stringValue = String(format: "%.1f", ReadAloud.shared.speed) }
    }

    /// The speed shown on the bar, for tests.
    var speedTitle: String { speedField.stringValue }
    /// Types a speed and presses Speed, for tests.
    func enterSpeed(_ text: String) { speedField.stringValue = text; applySpeed() }

    @objc private func backClicked() { ReadAloud.shared.previous() }
    @objc private func playPauseClicked() { ReadAloud.shared.pauseOrResume() }
    @objc private func forwardClicked() { ReadAloud.shared.next() }
    @objc private func closeClicked() { ReadAloud.shared.stop() }
    /// Reads the typed number (a comma works as the decimal point too), keeps it within
    /// 1–2, shows the value used, and hands the keyboard back to the page.
    @objc private func applySpeed() {
        let typed = speedField.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: CharacterSet(charactersIn: " ×x"))
        guard let value = Double(typed) else { NSSound.beep(); speedField.stringValue = String(format: "%.1f", ReadAloud.shared.speed); return }
        ReadAloud.shared.setSpeed(value)
        speedField.stringValue = String(format: "%.1f", ReadAloud.shared.speed)
        if let d = ReadAloud.shared.doc { d.view.window?.makeFirstResponder(d.pdfView) }
    }
}

// MARK: - right-click ▸ Read Aloud from Here

extension PuffinPDFView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let d = owner else { return menu }
        let p = convert(event.locationInWindow, from: nil)
        var items: [NSMenuItem] = []
        if ReadAloud.shared.isActive, ReadAloud.shared.doc === d {
            let pause = NSMenuItem(title: ReadAloud.shared.isPaused ? "Resume Reading" : "Pause Reading",
                                   action: #selector(readAloudPauseClicked), keyEquivalent: "")
            pause.target = self
            let stop = NSMenuItem(title: "Stop Reading", action: #selector(readAloudStopClicked), keyEquivalent: "")
            stop.target = self
            items = [pause, stop]
        }
        if let page = page(for: p, nearest: true) {
            let here = NSMenuItem(title: "Read Aloud from Here", action: #selector(readAloudHereClicked(_:)), keyEquivalent: "")
            here.target = self
            here.representedObject = (page, convert(p, to: page))
            items.insert(here, at: 0)
        }
        for (k, item) in items.enumerated() { menu.insertItem(item, at: k) }
        if !items.isEmpty { menu.insertItem(.separator(), at: items.count) }
        return menu
    }

    @objc private func readAloudHereClicked(_ sender: NSMenuItem) {
        guard let d = owner, let (page, point) = sender.representedObject as? (PDFPage, NSPoint) else { return }
        ReadAloud.shared.start(d, page: d.document.index(for: page), character: ReadAloud.characterIndex(on: page, at: point))
    }
    @objc private func readAloudPauseClicked() { ReadAloud.shared.pauseOrResume() }
    @objc private func readAloudStopClicked() { ReadAloud.shared.stop() }
}
