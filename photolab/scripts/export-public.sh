#!/bin/bash
# The public repository's files: this repo's committed HEAD, minus private material. The public repo is a separate
# repository with its own history (no history from here, which holds private notes and earlier private files).
#
#   photolab/scripts/export-public.sh <empty folder>
#
# Left out: work/ (internal design notes and QA, with real shoot names and paths) and the UI's demo fixture
# (mock/, built from a real shoot). Git-ignored files (Satoshi, RawTherapee, the LUTs) are never in a git export.
# Refuses if anything that looks personal is still in the result.
set -euo pipefail
die() { echo "export-public: $*" >&2; exit 1; }
OUT="${1:-}"; [ -n "$OUT" ] || die "usage: export-public.sh <empty folder>"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
mkdir -p "$OUT"
[ -z "$(ls -A "$OUT")" ] || die "$OUT isn't empty"
git -C "$ROOT" diff --quiet HEAD -- || echo "export-public: note: uncommitted changes are not included (HEAD only)" >&2
git -C "$ROOT" archive HEAD | tar -x -C "$OUT"
rm -rf "$OUT/work" "$OUT/photolab/Sources/PhotoLabCore/Resources/studio/mock"
# Nothing personal: no email, home-folder paths, or the private library's shoot and folder names.
HITS="$(grep -rIn -E --exclude=export-public.sh '@gmail\.com|trxntmitchell|/Users/trxnt|Digital Photos|BedStuy|[Ww]alkround|jul\.4th|Knicks' "$OUT" || true)"
[ -z "$HITS" ] || { echo "$HITS" >&2; die "personal data found (above); not exporting"; }
[ -z "$(find "$OUT" -iname 'Satoshi*' -o -name 'rawtherapee-cli' -o -path '*/luts/*' | head -1)" ] || die "non-redistributable files found"
echo "public tree ready: $OUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files)"
