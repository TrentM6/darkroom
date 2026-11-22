#!/bin/bash
# Builds the downloadable Baseline Darkroom for GitHub Releases:
#   dist/Baseline-Darkroom-macOS-arm64.zip and dist/Baseline-Darkroom-macOS-arm64.zip.sha256
#
# Usage: photolab/scripts/release.sh [<git ref> | --worktree]     (default: HEAD)
#   <git ref>   builds exactly that commit (git archive), so only committed files can end up in the app.
#   --worktree  builds the files git tracks (or would track) as they are on disk now; for testing before a commit.
# Either way, files git ignores (Satoshi, photolab/bin, photolab/luts) are never included.
#
# The app is ad-hoc signed: there is no Apple Developer ID. People get it through install.sh, which downloads it
# with curl (so macOS doesn't quarantine it) and checks it against the .sha256 file. A browser download of the zip
# would be quarantined, and macOS would refuse to open it.
#
# Licensing: nothing from RawTherapee (GPL-3.0) or the film LUTs is in the zip; install.sh fetches them from
# rawtherapee.com. LICENSE and THIRD_PARTY_NOTICES.md go inside the app (build-app.sh).
#
# Publish (after checking the zip):
#   gh release create v<version> --notes-file photolab/scripts/release-notes.md \
#     dist/Baseline-Darkroom-macOS-arm64.zip dist/Baseline-Darkroom-macOS-arm64.zip.sha256
# The notes say to install with the curl command: the zip, downloaded in a browser, is blocked by Gatekeeper.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REF="${1:-HEAD}"
NAME="Baseline-Darkroom-macOS-arm64.zip"
OUT="$REPO/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || die "release builds are made on Apple Silicon (the zip is arm64 only)."
mkdir -p "$WORK/src"
if [ "$REF" = "--worktree" ]; then
  LABEL="$(git -C "$REPO" rev-parse --short HEAD)+worktree"
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    [ -e "$f" ] || continue                 # deleted in the working tree
    mkdir -p "$WORK/src/$(dirname "$f")"; cp -p "$f" "$WORK/src/$f"
  done)
else
  LABEL="$(git -C "$REPO" rev-parse --short "$REF")"
  git -C "$REPO" archive "$REF" | tar -x -C "$WORK/src"
fi
echo "building $LABEL"

# Nothing that may not be redistributed.
BAD="$(cd "$WORK/src" && find . \( -iname 'Satoshi*' -o -name 'rawtherapee-cli' -o -path './photolab/luts/*' -o -path './photolab/bin/*' \) | head -5)"
[ -z "$BAD" ] || die "non-redistributable files in the source: $BAD"
[ -f "$WORK/src/LICENSE" ] && [ -f "$WORK/src/THIRD_PARTY_NOTICES.md" ] || die "LICENSE and THIRD_PARTY_NOTICES.md must be in $REF"

APP="$WORK/Baseline Darkroom.app"
PHOTOLAB_RELEASE=1 PHOTOLAB_APP="$APP" PHOTOLAB_BUILD_ROOT="$HOME/Library/Developer/BaselineDarkroom-release" \
  "$WORK/src/photolab/scripts/build-app.sh" > "$WORK/build.log" 2>&1 || { grep -E "error:" "$WORK/build.log" | head -20 >&2; die "build failed"; }

# Check what's in the bundle before it goes anywhere.
[ -x "$APP/Contents/MacOS/BaselineDarkroom" ] || die "no app binary"
[ ! -e "$APP/Contents/MacOS/rawtherapee-cli" ] || die "rawtherapee-cli is inside the app"
[ -z "$(find "$APP" -iname 'Satoshi*')" ] || die "Satoshi is inside the app"
[ -f "$APP/Contents/Resources/LICENSE" ] && [ -f "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md" ] || die "licences missing from the app"
codesign --verify --strict "$APP" || die "signature check failed"
[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" = "design.baselinestudio.darkroom" ] || die "wrong bundle identifier"

mkdir -p "$OUT"
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUT/$NAME"   # no ._ metadata files
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "built: $OUT/$NAME ($(du -h "$OUT/$NAME" | cut -f1), $LABEL)"
echo "sha256: $(cut -d' ' -f1 "$OUT/$NAME.sha256")"
