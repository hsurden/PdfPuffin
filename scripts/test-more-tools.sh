#!/bin/zsh
# Split, watermarks, blank pages, images, passwords and permissions, zoom memory, annotation stepping (see Tests/MoreTools).
set -euo pipefail
setopt extendedglob
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -framework AppKit -framework PDFKit -framework Vision \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift \
    Tests/MoreTools/main.swift -o "$scratch/more-tests"
"$scratch/more-tests" "$scratch"
