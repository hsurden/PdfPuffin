#!/bin/zsh
# Builds PdfPuffin.app into build/ with swiftc from the Command Line Tools.
# (SwiftPM is not used: the CLT's PackageDescription library fails to link
# any Package.swift on this Mac, see CLAUDE.md.)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/PdfPuffin.app"
SDK="$(xcrun --show-sdk-path)"
OPT=(-O)
[[ "$CONFIG" == "debug" ]] && OPT=(-Onone -g)

mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -rf "$APP/Contents/MacOS/PdfPuffin.dSYM"   # left by debug builds
swiftc "${OPT[@]}" -swift-version 5 -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -framework AppKit -framework PDFKit -framework Vision \
  -module-name PdfPuffin \
  Sources/PdfPuffin/*.swift \
  -o "$APP/Contents/MacOS/PdfPuffin"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
