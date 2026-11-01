#!/bin/zsh
# Builds "build/DJ Queue.app" (release, ad-hoc signed). `--install` copies it to ~/Applications.
# Does not install or load the LaunchAgent — do that from Settings → Engine or `djq agent install`.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -license check >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

swift build -c release --product DJQueueApp
BIN="$(swift build -c release --show-bin-path)/DJQueueApp"

APP="build/DJ Queue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
print "*" > build/.gitignore   # keep build output out of git
cp "$BIN" "$APP/Contents/MacOS/DJQueue"

VERSION="0.1.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift Resources/icon/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DJ Queue.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed: $HOME/Applications/DJ Queue.app"
fi
