#!/bin/zsh
# Recognize Text, Fill & Sign marks, flatten, reduce size, password, exports,
# and the sidebar button leaving the page grid. Writes only to a temp folder.
set -euo pipefail
setopt extendedglob
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -framework AppKit -framework PDFKit -framework Vision \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift \
    Tests/FillSignOCR/main.swift -o "$scratch/fill-sign-ocr-tests"
"$scratch/fill-sign-ocr-tests" "$scratch"
