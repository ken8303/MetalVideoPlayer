#!/bin/bash
# Builds a self-contained, shareable SuperResVideoPlayer.app:
#  - release build of the Swift package
#  - libmpv and its entire dependency tree copied into Contents/Frameworks
#    with install names rewritten to @rpath (so nothing from /opt/homebrew
#    is needed on the recipient's machine)
#  - ffmpeg + ffprobe bundled into Contents/Helpers (used for MKV subtitle
#    audio extraction and export repackaging), with their deps bundled too
#  - everything ad-hoc code signed, zipped for sharing
#
# Recipient requirements (inherent to the app, not the packaging):
#  - Apple Silicon Mac on macOS 26+
#  - First launch: right-click the app > Open (it's ad-hoc signed, not
#    notarized, so plain double-click is blocked by Gatekeeper)
#
# Usage: bash make-dist.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building (release)…"
# -gnone skips the dsymutil step some Macs block (see make-app.sh); a
# shipped binary doesn't need a dSYM anyway.
swift build -c release -Xswiftc -gnone

BIN=.build/release/SuperResVideoPlayer
BUNDLE_SRC=.build/release/SuperResVideoPlayer_SuperResVideoPlayer.bundle
DIST=dist
APP="$DIST/SuperResVideoPlayer.app"
FRAMEWORKS="$APP/Contents/Frameworks"
HELPERS="$APP/Contents/Helpers"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORKS" "$HELPERS"

cp "$BIN" "$APP/Contents/MacOS/SuperResVideoPlayer"
cp Info.plist "$APP/Contents/Info.plist"
if [ -d "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
fi

# Optional helper CLIs. The app degrades gracefully without them (subtitles
# for MKV and export-repackaging need them), but bundling means recipients
# install nothing.
for tool in ffmpeg ffprobe; do
  SRC="$(command -v "$tool" || true)"
  if [ -n "$SRC" ]; then
    cp "$SRC" "$HELPERS/$tool"
    chmod u+w "$HELPERS/$tool"
  else
    echo "warning: $tool not found on this machine — the shared app will lack MKV subtitle/export support"
  fi
done

# --- Dependency bundling -----------------------------------------------

is_bundleable() {
  case "$1" in
    /usr/lib/*|/System/*|@*) return 1 ;;   # system libs / already-relative refs
    *) return 0 ;;
  esac
}

# Recursively copy every non-system dylib a binary links against into
# Contents/Frameworks (by basename; the tree is a DAG so this terminates).
collect_deps() {
  local target="$1"
  local dep name
  for dep in $(otool -L "$target" | tail -n +2 | awk '{print $1}'); do
    is_bundleable "$dep" || continue
    name="$(basename "$dep")"
    if [ ! -f "$FRAMEWORKS/$name" ]; then
      if [ ! -f "$dep" ]; then
        echo "warning: dependency not found on disk: $dep (referenced by $target)"
        continue
      fi
      cp "$dep" "$FRAMEWORKS/$name"
      chmod u+w "$FRAMEWORKS/$name"
      collect_deps "$FRAMEWORKS/$name"
    fi
  done
}

# Rewrite a binary's references to bundled libs as @rpath/name.
rewrite_refs() {
  local target="$1"
  local dep name
  for dep in $(otool -L "$target" | tail -n +2 | awk '{print $1}'); do
    is_bundleable "$dep" || continue
    name="$(basename "$dep")"
    install_name_tool -change "$dep" "@rpath/$name" "$target" 2>/dev/null || true
  done
}

echo "==> Collecting library dependencies…"
collect_deps "$APP/Contents/MacOS/SuperResVideoPlayer"
for tool in "$HELPERS"/*; do
  [ -f "$tool" ] && collect_deps "$tool"
done
echo "    $(ls "$FRAMEWORKS" 2>/dev/null | wc -l | tr -d ' ') libraries bundled"

echo "==> Rewriting install names…"
rewrite_refs "$APP/Contents/MacOS/SuperResVideoPlayer"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SuperResVideoPlayer" 2>/dev/null || true

for lib in "$FRAMEWORKS"/*.dylib; do
  [ -f "$lib" ] || continue
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null || true
  rewrite_refs "$lib"
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

for tool in "$HELPERS"/*; do
  [ -f "$tool" ] || continue
  rewrite_refs "$tool"
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$tool" 2>/dev/null || true
done

# --- Signing (install_name_tool invalidates signatures) -----------------

echo "==> Code signing (ad-hoc)…"
for lib in "$FRAMEWORKS"/*.dylib; do
  [ -f "$lib" ] && codesign --force --sign - "$lib" > /dev/null 2>&1
done
for tool in "$HELPERS"/*; do
  [ -f "$tool" ] && codesign --force --sign - "$tool" > /dev/null 2>&1
done
codesign --force --sign - "$APP"

echo "==> Verifying…"
codesign --verify --deep "$APP" && echo "    signature OK"
# Smoke-test that the main binary resolves its libraries from the bundle.
if otool -L "$APP/Contents/MacOS/SuperResVideoPlayer" | grep -q "/opt/homebrew"; then
  echo "error: main binary still references /opt/homebrew — bundling incomplete"
  exit 1
fi

echo "==> Zipping…"
ditto -c -k --keepParent "$APP" "$DIST/SuperResVideoPlayer.zip"

echo ""
echo "Done:"
echo "  $APP"
echo "  $DIST/SuperResVideoPlayer.zip   <- share this"
echo ""
echo "Tell recipients: Apple Silicon + macOS 26 required; on first launch"
echo "right-click the app and choose Open (it isn't notarized)."
