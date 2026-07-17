#!/bin/bash
# Builds the SwiftPM executable and wraps it in a minimal .app bundle.
#
# Why: several system frameworks assume a real app bundle — TCC permission
# prompts, the Translation framework's model-download UI, Dock/menu-bar
# integration. A bare SPM binary launched from a terminal has none of that
# identity, which causes hangs (e.g. Translation's consent sheet blocking
# the main thread invisibly) and hidden dialogs.
#
# Usage:
#   bash make-app.sh          # build + launch (logs go to the terminal)
set -euo pipefail
cd "$(dirname "$0")"

swift build

BIN=.build/debug/SuperResVideoPlayer
BUNDLE_SRC=.build/debug/SuperResVideoPlayer_SuperResVideoPlayer.bundle
APP=.build/SuperResVideoPlayer.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SuperResVideoPlayer"
cp Info.plist "$APP/Contents/Info.plist"

# SPM resource bundle (compiled shaders etc.) — Bundle.module looks for it
# in Contents/Resources.
if [ -d "$BUNDLE_SRC" ]; then
  cp -R "$BUNDLE_SRC" "$APP/Contents/Resources/"
fi

# Ad-hoc signature: enough for local use; TCC and system services want
# *some* stable code identity.
codesign --force --sign - "$APP"

echo "Built $APP"

# Launch the binary inside the bundle directly (instead of `open`) so
# stdout/stderr still print to this terminal. Bundle identity is derived
# from the executable's location, so this still counts as a real app.
exec "$APP/Contents/MacOS/SuperResVideoPlayer"
