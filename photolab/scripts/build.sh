#!/bin/bash
# Builds Baseline Darkroom (release) from a local mirror of the sources.
# Why: this package lives in an iCloud-synced Desktop folder. When the disk is nearly full, macOS evicts
# synced files ("dataless") right after they're written; stat() then reports stale sizes and reads
# during a build can come back truncated or with NUL bytes. So every file is read by content, twice,
# must read back identically and NUL-free, and is copied into a mirror outside iCloud; the build runs there.
#   PHOTOLAB_BUILD_ROOT (default ~/Library/Developer/BaselineDarkroom): src/ = mirror, build/ = SwiftPM scratch
# Output: $PHOTOLAB_BUILD_ROOT/build/release/{photolab,PhotoLabApp,PhotoLab_PhotoLabCore.bundle}
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${PHOTOLAB_BUILD_ROOT:-$HOME/Library/Developer/BaselineDarkroom}"
SRC="$ROOT/src"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$SRC.new"; mkdir -p "$SRC.new"
cd "$PKG"
find Package.swift Sources -type f ! -name '.DS_Store' ! -name '*.orig' ! -name '*.rej' | while IFS= read -r f; do
  ok=0
  for try in 1 2 3 4 5 6 7 8 9 10; do
    cat "$f" > "$TMP/a" && cat "$f" > "$TMP/b" || { sleep 1; continue; }
    # an empty read of a file that isn't empty = iCloud still downloading it: wait and read again
    if [ ! -s "$TMP/a" ] && [ "$(stat -f %z "$f")" != "0" ]; then sleep 2; continue; fi
    if cmp -s "$TMP/a" "$TMP/b"; then
      case "$f" in
        *.swift|*.html|*.js|*.css|*.json) [ "$(tr -cd '\000' < "$TMP/a" | wc -c | tr -d ' ')" = "0" ] || { sleep 1; continue; } ;;
      esac
      ok=1; break
    fi
    sleep 1
  done
  [ $ok = 1 ] || { echo "error: couldn't read $f reliably (iCloud?)" >&2; exit 1; }
  mkdir -p "$SRC.new/$(dirname "$f")"
  cp "$TMP/a" "$SRC.new/$f"
done
# Swap in the new mirror, keeping unchanged files' timestamps so SwiftPM rebuilds only what changed.
mkdir -p "$SRC"
rsync -a --delete --checksum "$SRC.new/" "$SRC/"
rm -rf "$SRC.new"
cd "$SRC"
swift build -c release --scratch-path "$ROOT/build" "$@"
echo "built: $ROOT/build/release"
