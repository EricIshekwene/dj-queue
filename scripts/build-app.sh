#!/bin/zsh
# Builds "build/DJ Queue.app" (release, ad-hoc signed) with the djq CLI inside (Contents/MacOS/djq).
# `--install` copies it to ~/Applications and points ~/bin/djq at the bundled CLI.
# djq finds ffmpeg by absolute path (/opt/homebrew/bin, /usr/local/bin) and uses the same Paths.standard as the app.
# Does not install or load the LaunchAgent — do that from Settings → Engine or `djq agent install`.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -license check >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

swift build -c release --product DJQueueApp
swift build -c release --product djq
BINDIR="$(swift build -c release --show-bin-path)"
BIN="$BINDIR/DJQueueApp"

APP="build/DJ Queue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
print "*" > build/.gitignore   # keep build output out of git
cp "$BIN" "$APP/Contents/MacOS/DJQueue"
cp "$BINDIR/djq" "$APP/Contents/MacOS/djq"

# Version = latest git tag (v0.3.0 → 0.3.0); commits since the tag append "-dev.N" so an untagged build is obvious.
if TAG="$(git describe --tags --abbrev=0 2>/dev/null)"; then
  AHEAD="$(git rev-list --count "$TAG"..HEAD 2>/dev/null || echo 0)"
else
  # No tag yet: every commit counts (a git repo with commits → 0.0.0-dev.N; not a git checkout → 0.0.0).
  TAG=v0.0.0
  AHEAD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
fi
VERSION="${TAG#v}"; [[ "$AHEAD" != "0" ]] && VERSION="$VERSION-dev.$AHEAD"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift Resources/icon/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/djq"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/DJ Queue.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed: $HOME/Applications/DJ Queue.app"
  CLI="$HOME/Applications/DJ Queue.app/Contents/MacOS/djq"
  LINK="$HOME/bin/djq"
  mkdir -p "$HOME/bin"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    echo "warning: $LINK exists and is not a symlink — left alone (point it at $CLI yourself)" >&2
  else
    ln -sfn "$CLI" "$LINK"
    echo "linked: $LINK -> $CLI"
  fi
fi
