#!/bin/bash
# Baseline Darkroom: install or update with one command.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/TrentM6/darkroom/main/install.sh)"
#
# What it does (each step is skipped when it's already done, so running it again updates the app):
#   1. Checks macOS 14+.
#   2. RawTherapee 5.11 → /Applications/RawTherapee.app (official macOS 12.3+ build from rawtherapee.com,
#      accepted only if it is signed by the RawTherapee developers).
#   3. RawTherapee's Film Simulation LUTs (≈420 MB, CC BY-SA 4.0), downloaded only on a first install.
#   4. The app: on Apple Silicon, the ready-made build from the latest GitHub release (checked against its
#      SHA-256), so nothing needs compiling. Otherwise, or with DARKROOM_FROM_SOURCE=1, it builds from source,
#      which needs the Xcode Command Line Tools (it offers to install them).
#   5. Installs ~/Applications/Baseline Darkroom.app.
# RawTherapee and the LUTs come from their publishers, never from this project. Your library
# (~/Library/Application Support/Baseline Darkroom) is never modified, only renamed from PhotoLab once if needed.
#
# Env: DARKROOM_REPO (git URL), DARKROOM_BRANCH (default main), DARKROOM_RELEASES (release download base URL),
#      DARKROOM_FROM_SOURCE=1 (always build), DARKROOM_SRC (build from this existing checkout; for development),
#      DARKROOM_APP_ZIP (install this local zip instead of downloading; for testing), DARKROOM_NO_OPEN=1.
set -euo pipefail

REPO="${DARKROOM_REPO:-https://github.com/TrentM6/darkroom.git}"
BRANCH="${DARKROOM_BRANCH:-main}"
RELEASES="${DARKROOM_RELEASES:-https://github.com/TrentM6/darkroom/releases/latest/download}"
ZIP_NAME="Baseline-Darkroom-macOS-arm64.zip"
APP_ID="design.baselinestudio.darkroom"
ROOT="$HOME/Library/Developer/BaselineDarkroom"
SUP="$HOME/Library/Application Support/Baseline Darkroom"
LEGACY_SUP="$HOME/Library/Application Support/PhotoLab"
APP="$HOME/Applications/Baseline Darkroom.app"
RT_APP="/Applications/RawTherapee.app"
RT_URL="https://rawtherapee.com/shared/builds/mac/RawTherapee_macOS_12.3_Universal_5.11.zip"
RT_TEAM="5SJ86G6Q2R"   # RawTherapee's Apple Developer ID team
LUT_URL="https://rawtherapee.com/shared/HaldCLUT.zip"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;38;2;254;69;6m›\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d)"
MOUNT=""
cleanup() { [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" >/dev/null 2>&1; [ -n "${LUT_LINK:-}" ] && rm -f "$LUT_LINK"; rm -rf "$TMP"; }
trap cleanup EXIT

bold "Baseline Darkroom installer"

# 1. System ------------------------------------------------------------------------------------------------
step "Checking your Mac"
[ "$(uname -s)" = "Darwin" ] || die "Baseline Darkroom is a Mac app."
MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 14 ] || die "macOS 14 or later is needed (this Mac has $MACOS)."
ok "macOS $MACOS ($(uname -m))"
MODE=prebuilt
if [ -n "${DARKROOM_SRC:-}" ] || [ "${DARKROOM_FROM_SOURCE:-0}" = 1 ] || [ "$(uname -m)" != arm64 ]; then MODE=source; fi

# 2. RawTherapee -------------------------------------------------------------------------------------------
step "RawTherapee (the rendering engine)"
rt_signed() { [[ "$(codesign -dv "$1" 2>&1)" == *"TeamIdentifier=$RT_TEAM"* ]]; }   # no grep -q: with pipefail its early exit fails the pipe
if [ -x "$RT_APP/Contents/MacOS/rawtherapee-cli" ]; then
  ok "found $RT_APP ($(defaults read "$RT_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
else
  [ -e "$RT_APP" ] && die "$RT_APP exists but has no rawtherapee-cli. Replace it with RawTherapee 5.11 from rawtherapee.com, then run this again."
  note "downloading RawTherapee 5.11 from rawtherapee.com (≈160 MB)…"
  curl -fL --progress-bar -o "$TMP/rt.zip" "$RT_URL"
  ditto -x -k "$TMP/rt.zip" "$TMP/rt"
  SRC_APP="$(find "$TMP/rt" -maxdepth 3 -name 'RawTherapee.app' -type d | head -1)"
  if [ -z "$SRC_APP" ]; then
    DMG="$(find "$TMP/rt" -maxdepth 3 -name '*.dmg' | head -1)"
    [ -n "$DMG" ] || die "Unexpected RawTherapee download (no app or disk image inside)."
    MOUNT="$TMP/rtmnt"
    hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
    SRC_APP="$(find "$MOUNT" -maxdepth 2 -name 'RawTherapee.app' -type d | head -1)"
    [ -n "$SRC_APP" ] || die "Unexpected RawTherapee disk image (no RawTherapee.app)."
  fi
  rt_signed "$SRC_APP" && codesign --verify --deep --strict "$SRC_APP" 2>/dev/null \
    || die "The downloaded RawTherapee isn't signed by the RawTherapee developers; not installing it."
  ditto "$SRC_APP" "$RT_APP" 2>/dev/null || die "Couldn't write to /Applications. Copy RawTherapee.app there yourself, then run this again."
  ok "installed $RT_APP"
fi
rt_signed "$RT_APP" || note "note: $RT_APP isn't signed by the RawTherapee team; using it anyway (it's already installed)."

# The official RawTherapee build signs rawtherapee-cli with the App Sandbox entitlement, so started by another
# program it crashes before it runs (exit 133). Darkroom uses a copy signed ad hoc, which drops the entitlement
# (its libraries still load from $RT_APP). The copy is checked before it replaces one that works.
rt_runs() { [[ "$("$1" -v 2>/dev/null)" == *RawTherapee* ]]; }   # -v prints the version and exits 255 (no pipe: pipefail)
install_cli() {   # install_cli <destination>
  local dest="$1" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(dirname "$dest")/.rawtherapee-cli.new"
  rm -f "$tmp"
  # -X and xattr -d: a RawTherapee downloaded in a browser is quarantined, and a quarantined copy signed ad hoc is
  # killed by macOS on launch (exit 137). The copy is Darkroom's own; RawTherapee.app itself is left as it is.
  cp -X "$RT_APP/Contents/MacOS/rawtherapee-cli" "$tmp"
  xattr -d com.apple.quarantine "$tmp" 2>/dev/null || true
  codesign --force --sign - "$tmp" 2>/dev/null || { rm -f "$tmp"; die "Couldn't sign the copy of rawtherapee-cli at $dest."; }
  if ! rt_runs "$tmp"; then
    rm -f "$tmp"
    if rt_runs "$dest"; then note "kept the existing $dest: a fresh copy of RawTherapee's CLI doesn't run on this Mac"; return; fi
    die "RawTherapee's command-line tool crashes on this Mac, so Darkroom can't render. Reinstall RawTherapee 5.11 from rawtherapee.com, then run this again."
  fi
  mv -f "$tmp" "$dest"
}

# Library folder: a PhotoLab install is renamed to Baseline Darkroom first (in place, never over an existing
# folder, never while PhotoLab runs), before anything below creates the new folder.
if [ -d "$LEGACY_SUP" ] && [ ! -e "$SUP" ]; then
  if pgrep -f "PhotoLab.app/Contents/MacOS/PhotoLab" >/dev/null || pgrep -fx ".*/photolab studio.*" >/dev/null; then
    die "PhotoLab is running. Quit it, then run this again (your library is moved, not copied, so it must be closed)."
  fi
  for area in "Application Support" "Caches" "Logs"; do
    old="$HOME/Library/$area/PhotoLab"; new="$HOME/Library/$area/Baseline Darkroom"
    if [ -d "$old" ] && [ ! -e "$new" ]; then mv "$old" "$new" && ok "moved your library: $old → $new"; fi
  done
fi

# 3. Film LUTs ---------------------------------------------------------------------------------------------
step "Film simulation LUTs"
have_luts() { [ -d "$1/HaldCLUT/Color/Kodak" ]; }
LUT_DIR=""
if have_luts "$SUP/luts"; then
  ok "already installed"
else
  note "downloading RawTherapee's Film Simulation Collection from rawtherapee.com (≈420 MB, CC BY-SA 4.0)…"
  curl -fL --progress-bar -o "$TMP/luts.zip" "$LUT_URL"
  ditto -x -k "$TMP/luts.zip" "$TMP/luts"
  KODAK="$(find "$TMP/luts" -maxdepth 4 -type d -name Kodak -path '*/Color/Kodak' | head -1)"
  [ -n "$KODAK" ] || die "Unexpected LUT download (no HaldCLUT/Color/Kodak inside)."
  LUT_DIR="$(dirname "$(dirname "$KODAK")")"   # …/HaldCLUT
  ok "downloaded"
fi

if [ "$MODE" = prebuilt ]; then
  # 4a. Ready-made app -------------------------------------------------------------------------------------
  step "Baseline Darkroom"
  if [ -n "${DARKROOM_APP_ZIP:-}" ]; then
    cp "$DARKROOM_APP_ZIP" "$TMP/app.zip"; cp "$DARKROOM_APP_ZIP.sha256" "$TMP/app.zip.sha256"
  elif curl -fsSL -o "$TMP/app.zip.sha256" "$RELEASES/$ZIP_NAME.sha256" 2>/dev/null; then
    note "downloading the latest release…"
    curl -fL --progress-bar -o "$TMP/app.zip" "$RELEASES/$ZIP_NAME"
  else
    note "no ready-made build available; building from source instead"
    MODE=source
  fi
fi

if [ "$MODE" = prebuilt ]; then
  [ "$(shasum -a 256 "$TMP/app.zip" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$TMP/app.zip.sha256")" ] \
    || die "The download doesn't match its checksum; not installing it. Try again."
  ditto -x -k "$TMP/app.zip" "$TMP/app"
  NEW="$TMP/app/Baseline Darkroom.app"
  [ -d "$NEW" ] && codesign --verify --strict "$NEW" 2>/dev/null \
    && [ "$(defaults read "$NEW/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$APP_ID" ] \
    || die "The download isn't a valid Baseline Darkroom app; not installing it."
  ok "verified ($(defaults read "$NEW/Contents/Info" CFBundleVersion))"
  # Support files the app looks for: the LUTs, and a local copy of the CLI from the user's own RawTherapee.
  install_cli "$SUP/bin/rawtherapee-cli"
  ok "rawtherapee-cli runs ($SUP/bin)"
  if [ -n "$LUT_DIR" ]; then mkdir -p "$SUP/luts"; rm -rf "$SUP/luts/HaldCLUT"; mv "$LUT_DIR" "$SUP/luts/HaldCLUT"; fi
  mkdir -p "$(dirname "$APP")"
  rm -rf "$APP"
  ditto "$NEW" "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
  ok "installed $APP"
else
  # 4b. Build from source ----------------------------------------------------------------------------------
  step "Build tools"
  if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "The Xcode Command Line Tools are needed to build the app. Finish the installer macOS just opened, then run this command again."
  fi
  SWIFT_VER="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' || echo 0.0)"
  SWIFT_MAJOR="${SWIFT_VER%%.*}"; SWIFT_MINOR="${SWIFT_VER#*.}"
  if [ "$SWIFT_MAJOR" -lt 5 ] || { [ "$SWIFT_MAJOR" -eq 5 ] && [ "$SWIFT_MINOR" -lt 10 ]; }; then
    die "Swift 5.10 or later is needed (found $SWIFT_VER). Update Xcode or the Command Line Tools (softwareupdate --list)."
  fi
  ok "Swift $SWIFT_VER"
  command -v git >/dev/null 2>&1 || die "git is missing (it comes with the Xcode Command Line Tools)."

  step "Baseline Darkroom source"
  if [ -n "${DARKROOM_SRC:-}" ]; then
    SRC="$(cd "$DARKROOM_SRC" && pwd)"
    ok "building from $SRC"
  else
    SRC="$ROOT/repo"
    mkdir -p "$ROOT"
    if [ -d "$SRC/.git" ]; then
      git -C "$SRC" fetch --quiet origin "$BRANCH"
      git -C "$SRC" checkout --quiet "$BRANCH"
      git -C "$SRC" merge --ff-only --quiet "origin/$BRANCH" \
        || die "$SRC has local changes that conflict with the update. Move that folder aside and run this again."
      ok "updated to $(git -C "$SRC" log -1 --format='%h %s' | cut -c1-70)"
    else
      git clone --quiet --branch "$BRANCH" "$REPO" "$SRC"
      ok "cloned $(git -C "$SRC" log -1 --format='%h') into $SRC"
    fi
  fi
  PKG="$SRC/photolab"
  [ -x "$PKG/scripts/build-app.sh" ] || die "$PKG/scripts/build-app.sh is missing; is $SRC a Baseline Darkroom checkout?"
  # The build copies RawTherapee's CLI and the LUTs from the package (photolab/bin, photolab/luts; both git-ignored)
  # into the library folder the first time.
  install_cli "$PKG/bin/rawtherapee-cli"
  install_cli "$SUP/bin/rawtherapee-cli"   # the build copies it only when missing; replace a broken one
  if [ -n "$LUT_DIR" ] && ! have_luts "$PKG/luts"; then
    [ -e "$PKG/luts" ] && die "$PKG/luts exists but has no HaldCLUT/Color/Kodak; remove it and run this again."
    mkdir -p "$TMP/lutroot"; mv "$LUT_DIR" "$TMP/lutroot/HaldCLUT"
    ln -s "$TMP/lutroot" "$PKG/luts"; LUT_LINK="$PKG/luts"   # copied into the library by the build, then removed
  fi

  step "Building the app (a few minutes the first time)"
  LOG="$ROOT/install.log"
  mkdir -p "$ROOT"
  if ! "$PKG/scripts/build-app.sh" > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | head -15 >&2 || tail -20 "$LOG" >&2
    die "The build failed. The full output is in $LOG"
  fi
  grep -E "^(moved:|removed old app:)" "$LOG" | sed 's/^/  /' || true
  [ -d "$APP" ] || die "The build finished but $APP is missing."
  ok "installed $APP"
fi

if pgrep -f "$APP/Contents/MacOS/BaselineDarkroom" >/dev/null; then
  bold $'\nDone. Quit Baseline Darkroom and open it again to use the new version.'
elif [ "${DARKROOM_NO_OPEN:-0}" = 1 ]; then
  bold $'\nDone.'
else
  open "$APP"
  bold $'\nDone. Baseline Darkroom is open. When macOS asks for access to your Desktop or Documents, allow it.'
fi
