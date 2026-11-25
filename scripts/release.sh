#!/bin/zsh
# Publish a new version that installed copies of PdfPuffin offer to update to.
#
#   scripts/release.sh 0.2 "What's new, shown in the update alert"
#   scripts/release.sh 0.2 "Notes" --skip-tests
#   DRY_RUN=1 scripts/release.sh 0.2 "Notes"   # build, test and zip only; nothing committed or published
#
# Steps: set the version in Info.plist, build, run the tests, commit "Release vX" on
# main, zip the app, publish main's files as one new commit on the public repo, and
# create the GitHub Release (tag vX) with PdfPuffin-for-Mac.zip, which the in-app
# updater reads, and PdfPuffin.dmg, the drag-to-Applications installer to send people. The public repo gets main's files only, never main's history.
#
# Optional privacy check: put one pattern per line in .release-privacy-patterns
# (ignored by git). The release stops if any published file matches one.
set -euo pipefail
cd "${0:A:h}/.."

die() { print -u2 "release: $*"; exit 1; }

version=${1:-}
notes=${2:-}
skip_tests=0
[[ "${3:-}" == "--skip-tests" ]] && skip_tests=1
[[ "$version" =~ '^[0-9]+(\.[0-9]+)*$' ]] || die "usage: scripts/release.sh <version, e.g. 0.2> \"<release notes>\" [--skip-tests]"
[[ -n "$notes" ]] || die "give release notes as the second argument (they appear in the update alert)"

[[ "$(git branch --show-current)" == "main" ]] || die "switch to main first"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "commit or stash your changes first"
git rev-parse --verify -q refs/heads/public >/dev/null || die "no local 'public' branch"
git remote get-url github >/dev/null 2>&1 || die "no 'github' remote"
command -v gh >/dev/null || die "the GitHub CLI (gh) is not installed"
repo="hsurden/PdfPuffin"
! gh release view "v$version" --repo "$repo" >/dev/null 2>&1 || die "release v$version already exists"

plist=Resources/Info.plist
pb=/usr/libexec/PlistBuddy
current=$($pb -c "Print :CFBundleShortVersionString" $plist)
newest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)
[[ "$version" != "$current" && "$newest" == "$version" ]] || die "version $version is not newer than $current"

# Refuse to publish anything matching the private patterns.
if [[ -f .release-privacy-patterns ]]; then
    if git grep -n -I -E -f .release-privacy-patterns HEAD -- . ':!.release-privacy-patterns' >/dev/null; then
        git grep -n -I -E -f .release-privacy-patterns HEAD -- . ':!.release-privacy-patterns' | head -20
        die "files match .release-privacy-patterns; fix them before releasing"
    fi
fi

build=$($pb -c "Print :CFBundleVersion" $plist)
$pb -c "Set :CFBundleShortVersionString $version" $plist
$pb -c "Set :CFBundleVersion $((build + 1))" $plist
restore() { git checkout -- $plist; }
trap 'restore' ERR INT

scripts/build.sh release
if (( ! skip_tests )); then
    for t in test-excerpts test-fill-sign-ocr test-review-fixes test-quick-wins test-updates; do
        print "== $t"
        scripts/$t.sh > ${TMPDIR:-/tmp}/pdfpuffin-$t.log 2>&1 || { tail -20 ${TMPDIR:-/tmp}/pdfpuffin-$t.log; die "$t failed"; }
    done
fi

mkdir -p dist
zip=dist/PdfPuffin-for-Mac.zip
rm -f $zip
/usr/bin/ditto -c -k --keepParent build/PdfPuffin.app $zip
# The installer people download or get by email (drag to Applications).
scripts/make-dmg.sh build/PdfPuffin.app
dmg=dist/PdfPuffin.dmg

if [[ "${DRY_RUN:-0}" == 1 ]]; then
    restore
    print "Dry run: built $zip and $dmg as version $version. Nothing committed or published."
    exit 0
fi

trap - ERR INT
git commit -q -m "Release v$version" -- $plist

# One public commit holding main's files, authored by the GitHub account's private address.
id=$(gh api user --jq '.id'); login=$(gh api user --jq '.login')
email="$id+$login@users.noreply.github.com"
commit=$(GIT_AUTHOR_NAME=$login GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$login GIT_COMMITTER_EMAIL=$email \
    git commit-tree "main^{tree}" -p public -m "PdfPuffin $version" -m "$notes")
git branch -f public $commit
git push github refs/heads/public:refs/heads/main

gh release create "v$version" $zip $dmg --repo "$repo" --target main --title "PdfPuffin $version" --notes "$notes"
print "Released PdfPuffin $version: https://github.com/$repo/releases/tag/v$version"
print "Installed copies will offer it within a day, or now via PdfPuffin ▸ Check for Updates…"
print "Installer for new people (always the newest): https://github.com/$repo/releases/latest/download/PdfPuffin.dmg"
