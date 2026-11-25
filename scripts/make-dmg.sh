#!/bin/zsh
# Builds dist/PdfPuffin.dmg: the familiar install window with PdfPuffin on the left,
# an arrow, and the Applications folder on the right. Uses only macOS's own tools
# (hdiutil and Finder); Finder may ask once to allow automation.
#
#   scripts/make-dmg.sh            # uses build/PdfPuffin.app (run scripts/build.sh first)
#   scripts/make-dmg.sh path/to/PdfPuffin.app
set -euo pipefail
cd "${0:A:h}/.."

app=${1:-build/PdfPuffin.app}
[[ -d "$app" ]] || { print -u2 "No app at $app. Run scripts/build.sh first."; exit 1; }
volname="PdfPuffin"
out=dist/PdfPuffin.dmg
work=$(mktemp -d)
mnt=""
cleanup() {
    [[ -n "$mnt" ]] && hdiutil detach "$mnt" -quiet -force 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# Contents: the app, a link to /Applications, and the hidden background picture.
stage=$work/stage
mkdir -p "$stage/.background"
ditto "$app" "$stage/PdfPuffin.app"
ln -s /Applications "$stage/Applications"
cp Resources/dmg-background.png "$stage/.background/background.png"

# A writable image to arrange, then a compressed read-only copy to hand out.
[[ -d /Volumes/$volname ]] && { print -u2 "Eject the mounted '$volname' volume first."; exit 1; }
hdiutil create -quiet -volname "$volname" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
mnt=$(hdiutil attach "$work/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')
[[ -n "$mnt" ]] || { print -u2 "Could not mount the image."; exit 1; }

osascript <<EOF
tell application "Finder"
    tell disk "$volname"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 620}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "PdfPuffin.app" of container window to {160, 160}
        set position of item "Applications" of container window to {440, 160}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Let Finder write its layout (.DS_Store) before converting.
sync; sleep 1
hdiutil detach "$mnt" -quiet
mnt=""
mkdir -p dist
rm -f "$out"
hdiutil convert "$work/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$out"
print "Built $out ($(du -h "$out" | cut -f1))"
