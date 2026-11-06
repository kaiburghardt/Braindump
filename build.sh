#!/bin/zsh
# Builds Braindump.app (release, ad-hoc signed – no developer certificate needed).
#
#   ./build.sh             → build/Braindump.app
#   ./build.sh --install   → also copy it to ~/Applications and launch it
#
# Optional: SIGN_ID="Apple Development: …" ./build.sh signs with a fixed identity, so macOS
# doesn't ask for access to Documents (and the Keychain) again after every rebuild.
set -euo pipefail
cd "${0:A:h}"

APP_NAME=Braindump
BUNDLE_ID=local.kai.Braindump
APP="build/${APP_NAME}.app"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

[[ -f Resources/AppIcon.icns ]] || ./Tools/make_icon.sh

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/TrainingLines.json "$APP/Contents/Resources/TrainingLines.json"
codesign --force --sign "${SIGN_ID:--}" --timestamp=none "$APP" >/dev/null
echo "✓ Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  # quit the running copy cleanly (it saves on quit)
  osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "✓ Installed: ~/Applications/$APP_NAME.app"
  open "$HOME/Applications/$APP_NAME.app"
fi
