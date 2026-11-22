#!/bin/bash
# Builds Baseline Darkroom.app and installs it to ~/Applications/Baseline Darkroom.app.
#   0. One-time rename from PhotoLab: ~/Library/{Application Support,Caches,Logs}/PhotoLab become
#      .../Baseline Darkroom (a rename in place: catalog, edits, marks and My Look carry over untouched).
#   1. Release build (scripts/build.sh: from a local mirror, outside iCloud).
#   2. Support files, copied once to ~/Library/Application Support/Baseline Darkroom/: luts/ (≈400 MB film LUTs,
#      referenced, not duplicated into the app) and bin/rawtherapee-cli. RawTherapee.app must be in /Applications.
#   3. Bundle: Contents/MacOS/{BaselineDarkroom, rawtherapee-cli}, Contents/Resources/{studio/, AppIcon.icns from
#      assets/}, Info.plist.
#   4. Ad-hoc code signature with a fixed identifier (design.baselinestudio.darkroom).
# Env: PHOTOLAB_APP (default ~/Applications/Baseline Darkroom.app), PHOTOLAB_BUILD_ROOT (see build.sh).
#   PHOTOLAB_RELEASE=1: a build to hand to other people (scripts/release.sh). It touches nothing on this Mac (no
#   library rename, no support files, no install) and leaves RawTherapee's CLI out of the bundle: shipping that
#   GPL program would oblige us to ship its source too, and the app finds the user's own copy instead.
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${PHOTOLAB_BUILD_ROOT:-$HOME/Library/Developer/BaselineDarkroom}"
APP="${PHOTOLAB_APP:-$HOME/Applications/Baseline Darkroom.app}"
SUP="$HOME/Library/Application Support/Baseline Darkroom"
ID="design.baselinestudio.darkroom"
OLD_APP="$HOME/Applications/PhotoLab.app"
RELEASE="${PHOTOLAB_RELEASE:-0}"
REPO_ROOT="$(cd "$PKG/.." && pwd)"

# 0. PhotoLab → Baseline Darkroom: move the data folders before anything creates the new ones.
if [ "$RELEASE" != 1 ] && [ -d "$HOME/Library/Application Support/PhotoLab" ] && [ ! -e "$SUP" ]; then
  if pgrep -f "PhotoLab.app/Contents/MacOS/PhotoLab" >/dev/null || pgrep -fx ".*/photolab studio.*" >/dev/null; then
    echo "error: PhotoLab is running. Quit it, then run this again (your library is moved, not copied, so it must be closed)." >&2
    exit 1
  fi
  for area in "Application Support" "Caches" "Logs"; do
    old="$HOME/Library/$area/PhotoLab"; new="$HOME/Library/$area/Baseline Darkroom"
    if [ -d "$old" ] && [ ! -e "$new" ]; then mv "$old" "$new" && echo "moved: $old -> $new"; fi
  done
fi

"$PKG/scripts/build.sh"
BUILD="$ROOT/build/release"
SRC="$ROOT/src"

# Support files (once). The package's copies may be iCloud placeholders: cp downloads them.
if [ "$RELEASE" != 1 ]; then
  mkdir -p "$SUP/bin" "$SUP/luts"
  if [ ! -x "$SUP/bin/rawtherapee-cli" ]; then cp "$PKG/bin/rawtherapee-cli" "$SUP/bin/rawtherapee-cli"; fi
  if [ ! -d "$SUP/luts/HaldCLUT/Color/Kodak" ]; then rsync -a "$PKG/luts/" "$SUP/luts/"; fi
  [ -d /Applications/RawTherapee.app ] || echo "warning: /Applications/RawTherapee.app is missing; previews and export won't work" >&2
fi

STAGE="$(mktemp -d)/Baseline Darkroom.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/PhotoLabApp" "$STAGE/Contents/MacOS/BaselineDarkroom"
[ "$RELEASE" = 1 ] || cp "$SUP/bin/rawtherapee-cli" "$STAGE/Contents/MacOS/rawtherapee-cli"
rsync -a --exclude 'mock' "$SRC/Sources/PhotoLabCore/Resources/studio/" "$STAGE/Contents/Resources/studio/"
# Licences travel with the app (Lucide's ISC licence requires its notice in every copy).
cp "$REPO_ROOT/LICENSE" "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/Contents/Resources/"

# Icon
cp "$PKG/assets/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns" || echo "warning: no icon" >&2

VERSION="1.0"
BUILDNO="$(date +%Y%m%d%H%M)"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Baseline Darkroom</string>
  <key>CFBundleDisplayName</key><string>Baseline Darkroom</string>
  <key>CFBundleExecutable</key><string>BaselineDarkroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILDNO</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Baseline Darkroom</string>
  <key>NSDesktopFolderUsageDescription</key><string>Baseline Darkroom reads your photos where they are and exports finished photos to your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Baseline Darkroom reads your photos where they are.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Baseline Darkroom reads your photos where they are.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Baseline Darkroom reads photos on memory cards and external drives.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Baseline Darkroom reads photos on network drives.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Signature: rawtherapee-cli keeps its own (Developer ID) signature; the app is signed ad hoc with a fixed
# identifier AND an explicit designated requirement on that identifier. An ad-hoc signature's default
# requirement is its code hash, which changes with every build, so macOS privacy grants (Desktop,
# Documents, removable volumes) would be asked again after each rebuild; with this requirement they persist.
codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$STAGE"
codesign --verify --strict "$STAGE"

mkdir -p "$(dirname "$APP")"
if [ "$RELEASE" = 1 ]; then
  rm -rf "$APP"; mv "$STAGE" "$APP"
  echo "built: $APP"
  codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature"
  exit 0
fi
if pgrep -f "$APP/Contents/MacOS/BaselineDarkroom" >/dev/null; then echo "note: Baseline Darkroom is running; quit it to use the new build" >&2; fi
rm -rf "$APP"
mv "$STAGE" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "installed: $APP"
# The old PhotoLab.app is a build product (rebuildable, holds no data): remove it so it can't be opened by mistake.
if [ -d "$OLD_APP" ] && [ "$(defaults read "$OLD_APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "com.trxnt.photolab" ]; then
  rm -rf "$OLD_APP" && echo "removed old app: $OLD_APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|CDHash"
