#!/bin/zsh
# Optional argument: a text PDF with at least 66 pages and multiple lines on page 41.
set -euo pipefail
setopt extendedglob
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
if (( $# )); then
    cp "$1" "$scratch/Goldberg.pdf"
else
    # Produce a distinct text layer on each page, using only the macOS SDK.
    cat > "$scratch/fixture.swift" <<'SWIFT'
import AppKit
import CoreText
let output = URL(fileURLWithPath: CommandLine.arguments[1])
var media = CGRect(x: 0, y: 0, width: 612, height: 792)
let context = CGContext(output as CFURL, mediaBox: &media, nil)!
for page in 1...100 {
    context.beginPDFPage(nil)
    for line in 1...12 {
        let text = NSAttributedString(string: "Excerpt fixture page \(page), sample text line \(line).",
                                      attributes: [.font: NSFont.systemFont(ofSize: 14)])
        context.textPosition = CGPoint(x: 40, y: 750 - 22 * line)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    context.endPDFPage()
}
context.closePDF()
SWIFT
    swift "$scratch/fixture.swift" "$scratch/Goldberg.pdf"
fi
swiftc -swift-version 5 -framework AppKit -framework PDFKit -framework Vision \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift \
    Tests/ExcerptWorkflow/main.swift -o "$scratch/excerpt-tests"
"$scratch/excerpt-tests" "$scratch"
