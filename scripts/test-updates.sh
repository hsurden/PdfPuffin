#!/bin/zsh
# Update checks, unpacking and installing (see Tests/Updates).
set -euo pipefail
setopt extendedglob
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 5 -framework AppKit -framework PDFKit -framework Vision \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift \
    Tests/Updates/main.swift -o "$scratch/update-tests"
"$scratch/update-tests" "$scratch"
