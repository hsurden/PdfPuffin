#!/bin/zsh
# Run from a logged-in Mac. Optional argument: parent directory for the run report.
set -euo pipefail
setopt extendedglob
parent=${1:-"${0:A:h}/../build/menu-walkthrough"}
mkdir -p "$parent"
out=$(mktemp -d "${parent:A}/run-XXXXXXXX")
echo "Walkthrough output: $out"
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/PdfPuffin.app/Contents"
mkdir -p "$scratch/home" "$out/screenshots" "$out/fixtures" "$bundle/MacOS" "$bundle/Resources"
cp Resources/Info.plist "$bundle/Info.plist"
cp Resources/AppIcon.icns "$bundle/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.hs.PdfPuffin.MenuWalkthrough" "$bundle/Info.plist"
shasum -a 256 Sources/PdfPuffin/*.swift Tests/MenuWalkthrough/main.swift > "$out/sources.sha256"
swiftc -swift-version 5 -framework AppKit -framework PDFKit \
    Sources/PdfPuffin/*.swift~Sources/PdfPuffin/main.swift Tests/MenuWalkthrough/main.swift -o "$bundle/MacOS/PdfPuffin"
export CFFIXED_USER_HOME="$scratch/home" WALKTHROUGH_OUTPUT="$out"
python3 - "$bundle/MacOS/PdfPuffin" "$out" <<'PY'
import pathlib, subprocess, sys, time
binary, directory = sys.argv[1:]
root = pathlib.Path(directory)
log = root / "steps.md"
with (root / "console.log").open("w") as console:
    child = subprocess.Popen([binary], stdout=console, stderr=console)
    started = time.time()
    try:
        while child.poll() is None:
            last = log.stat().st_mtime if log.exists() else started
            if time.time() - last > 35:
                raise SystemExit("Walkthrough stalled. Inspect the last entry in " + str(log))
            time.sleep(0.25)
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
if child.returncode or not log.exists() or "Walkthrough complete" not in log.read_text():
    sys.exit("Incomplete run. See " + str(root))
if "FAIL |" in log.read_text():
    sys.exit("Walkthrough found failures. See " + str(log))
print(log)
PY
