#!/bin/zsh
# One check per bug from Codex's review: crop-box text, two columns, blank
# cover pages, bookmarks on insert, tools on tab switch, grid anchor.
set -euo pipefail
setopt extendedglob
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -framework AppKit -framework PDFKit -framework Vision \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift \
    Tests/ReviewFixes/main.swift -o "$scratch/review-tests"
"$scratch/review-tests" "$scratch"
