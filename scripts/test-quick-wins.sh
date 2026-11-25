#!/bin/zsh
# The PDF Expert menu features added together (see Tests/QuickWins).
set -euo pipefail
setopt extendedglob
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -framework AppKit -framework PDFKit -framework Vision \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift \
    Tests/QuickWins/main.swift -o "$scratch/quick-tests"
"$scratch/quick-tests" "$scratch"
