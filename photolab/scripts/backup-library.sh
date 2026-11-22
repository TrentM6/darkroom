#!/bin/bash
# Back up Baseline Darkroom's catalog (edits, marks, My Look, favorites, analysis) before installing a new build.
# Photos themselves are never touched by the app and are not part of this backup.
# Works before and after the rename from PhotoLab (it backs up whichever catalog folder exists).
set -euo pipefail
SRC="$HOME/Library/Application Support/Baseline Darkroom"
[ -d "$SRC" ] || SRC="$HOME/Library/Application Support/PhotoLab"
DEST="$HOME/Documents/Baseline Darkroom Backups/$(date +%Y-%m-%d_%H%M%S)"
[ -d "$SRC" ] || { echo "No catalog found in ~/Library/Application Support"; exit 1; }
mkdir -p "$DEST"
# The preview cache lives in ~/Library/Caches and is disposable, so it isn't copied.
rsync -a "$SRC/" "$DEST/"
echo "Backed up to: $DEST"
