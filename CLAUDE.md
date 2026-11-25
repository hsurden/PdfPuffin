# PdfPuffin: notes for agents

Native macOS PDF reader (Swift + AppKit + PDFKit), modelled on PDF Expert 3.13. See README.md for features, keyboard map and gaps.

## Build

- **No Xcode, and SwiftPM may not work**: on the original development Mac the Command Line Tools'
  `PackageDescription` library fails to link any `Package.swift` (undefined
  `Package.__allocating_init`). So `scripts/build.sh` calls `swiftc` directly on
  `Sources/PdfPuffin/*.swift` (`-swift-version 5`, macOS 14 target), copies
  `Resources/Info.plist`, and ad-hoc signs `build/PdfPuffin.app`.
- `./run.sh` quits the running copy (asks it nicely; never force-kills, so a save
  prompt wins), builds, and opens the app with any file arguments.

## Hard rules

- **Arrow keys must always reach the PDF.** A common failure in other
  readers: clicking a thumbnail gives focus to the sidebar divider and → widens the sidebar. Here:
  every sidebar table/outline is a `Focusless*View`, buttons use
  `refusesFirstResponder`, a mouse-up monitor in `MainWindowController` puts focus
  back on the PDF view after any click outside a text field, and a key-down monitor
  routes paging keys (`PuffinPDFView.handleKey`) to the PDF whenever no text field is
  being edited. Keep all three layers when adding UI.
- After a thumbnail click (`DocumentViewController.thumbnailsActive`), ↑/↓ step pages
  (like moving through a list); a click in the page turns it off.
- Never silently truncate text. List cells use `maximumNumberOfLines = 0` with
  automatic row heights; search snippets are excerpts marked with visible "…".

## Lessons (cost real time)

- **Draw `bounds`, not `dirtyRect`.** Since macOS 14 views do not clip to bounds and
  `dirtyRect` can extend past them; a 1-pt divider filling `dirtyRect` painted grey
  over the whole toolbar and sidebar header.
- `NSApplicationCrashOnExceptions` is on (main.swift) so a bad constraint crashes
  instead of leaving a half-built window.
- Unsaved-changes alerts: only the explicit "Don't Save" button discards. Any other
  response (including those an Apple Event quit produces) counts as Cancel.
- PDFView's first `go(to:)` is undone by the first auto-zoom pass; the initial page
  is applied again on the next run loop (`restoreInitialPageIfNeeded`).
- PDFView validates menu items privately; `PuffinPDFView.validateMenuItem` shadows it
  and forwards via the superclass IMP (needed for "Copy N Pages").
- PDFKit's inner view swallows mouse drags, so all page tools (shapes, pen, eraser,
  text, signature) and selection run from the window-level mouse monitor in
  `MainWindowController.installMonitors`, not from PDFView overrides.
- PDFKit does not repaint an annotation whose bounds change; remove and re-add it
  (`PuffinPDFView.refresh`). In Split View the two panes share one render cache per
  page and only the pane that asks last refreshes, so `repaint` re-lays out each pane
  on its own run-loop turn. A press in the inactive pane activates it first, so tools
  act where you click.
- A PDFAnnotation subclass that overrides `draw(with:in:)` (SignatureAnnotation) is
  saved with an appearance stream from that drawing, so it survives Save and shows in
  other apps (verified with Quick Look).
- PDF Expert keeps signatures in `~/Library/Preferences/com.readdle.PDFExpert-Mac.plist`
  under `myInkSignatures` (NSKeyedArchiver of RDPDFInkSignature / RDPDFTextSignature /
  RDPDFImageSignature). `SignatureStore.importFromPDFExpert` maps those classes to
  stand-ins and copies them to `~/Library/Application Support/PdfPuffin/Signatures`.
  This is the user's personal signature data: keep it local, never send it anywhere.
- Opening or closing the tool inspector holds the zoom (`keepingZoom`); auto-zoom
  re-fitting the page moved a just-placed signature off its line.
- Some ⌥⌘ shortcuts are often grabbed system-wide (Google Drive takes ⌥⌘G;
  ⌥⌘V may never arrive). Prefer ⌘ or ⌃⌘ combos for new shortcuts.

## Testing

- Background computer-use (`app_*`) selects table rows through accessibility without
  firing the click action, so the thumbnail/focus rule needs real clicks (full-screen
  control). Search via Edit ▸ Find ▸ Find… then type into the focused field.
- The computer-use tool refuses clipboard menu items; `PdfPuffin --from-clipboard`
  runs the same command at launch.
- Use disposable copies for save tests; never save over the user's own PDFs.

## Layout of the code

| File | What |
|---|---|
| `AppDelegate.swift` | menu bar (PDF Expert's names and shortcuts), launch, open/quit |
| `MainWindowController.swift` | window, tabs, focus monitors, all menu actions, search glue, recents |
| `DocumentViewController.swift` | one tab: split view, PDF view, page badge, back pill, zoom, bookmarks, annotations, save |
| `PuffinPDFView.swift` | PDFView subclass: paging keys, page Copy |
| `SidebarView.swift` | four-tab sidebar; Bookmarks, Outline, Annotations panes |
| `PageGridView.swift` | ⌘4 page grid and its page-tools bar (insert, append, rotate, copy, paste, extract, delete) |
| `ThumbnailsPane.swift` | thumbnails, multi-select, New Document / Add to… |
| `SearchPanel.swift` | right-hand results panel |
| `TabBarView.swift`, `ToolbarView.swift`, `HomeView.swift` | chrome |
| `Clipboard.swift` | New from Clipboard |
| `AnnotationTools.swift` | page tools (shapes, pen, eraser, text, signature), colours/widths, TextStyle |
| `InlineTextEditor.swift` | typing directly on the page |
| `ToolInspector.swift` | right-hand tool inspector (PDF Expert style) |
| `AnnotationSelection.swift` | select / move / resize / delete placed annotations |
| `Signatures.swift` | signature store, PDF Expert import, SignatureAnnotation |
| `docs/reference/read-menus.applescript` | dumps PDF Expert's menus with shortcuts |
