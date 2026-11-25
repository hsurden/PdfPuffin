#!/bin/bash
# Build PdfPuffin and launch it. Usage:
#   ./run.sh                 build (release) and open
#   ./run.sh some.pdf ...    build and open these files
#   ./run.sh --debug         debug build
#   ./run.sh --stop          quit the running copy from this folder
#   ./run.sh --install       build (release), replace /Applications/PdfPuffin.app, open it
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/PdfPuffin.app"
BIN="$APP/Contents/MacOS/PdfPuffin"
CONFIG=release
FILES=()
STOP=0
INSTALL=0
for a in "$@"; do
  case "$a" in
    --debug) CONFIG=debug ;;
    --stop) STOP=1 ;;
    --install) INSTALL=1 ;;
    *) FILES+=("$a") ;;
  esac
done

# Quit only the copy built from this folder (not any other app).
stop_running() {
  local pids
  pids=$(pgrep -f "PdfPuffin.app/Contents/MacOS/PdfPuffin" || true)
  if [[ -n "$pids" ]]; then
    echo "Quitting running PdfPuffin (pid $(echo $pids | tr '\n' ' '))"
    # Short timeout: if a "Save changes?" prompt appears, leave it to you.
    osascript -e 'with timeout of 3 seconds' -e 'tell application id "com.hs.PdfPuffin" to quit' -e 'end timeout' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "PdfPuffin.app/Contents/MacOS/PdfPuffin" >/dev/null || return 0; sleep 0.3; done
    echo "PdfPuffin is still open, probably asking whether to save a tab. Answer it, then run again."
    exit 1
  fi
}

stop_running
[[ $STOP == 1 ]] && exit 0

if [[ $INSTALL == 1 ]]; then
  CONFIG=release
  ./scripts/build.sh release
  DEST=/Applications/PdfPuffin.app
  # Only ever replaces PdfPuffin's own bundle (checked by bundle id).
  if [[ -d "$DEST" ]] && [[ "$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "com.hs.PdfPuffin" ]]; then
    echo "$DEST is not PdfPuffin; not touching it."; exit 1
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  codesign --verify "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  APP="$DEST"
  echo "Installed $DEST"
else
  ./scripts/build.sh "$CONFIG"
fi

if [[ ${#FILES[@]} -gt 0 ]]; then
  open -a "$APP" "${FILES[@]}"
else
  open "$APP"
fi
echo "PdfPuffin launched."
