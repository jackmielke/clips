#!/bin/bash
# Builds Clips.app and installs it to /Applications. Signs with the stable self-signed identity
# (see ~/dev/vantage/swiftui/Scripts/make-signing-id.sh) so screen/camera/mic grants survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Clips"
APP="build/Clips.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clips"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
KC="$HOME/Library/Keychains/vibevoice.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$HOME/.config/vibe-voice/signing/kc.pass")" "$KC"
  codesign --force --deep --sign "Vibe Voice Dev" --keychain "$KC" --timestamp=none "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
pkill -x Clips 2>/dev/null || true
rm -rf /Applications/Clips.app && cp -R "$APP" /Applications/Clips.app
echo "designated => $(codesign -d -r- /Applications/Clips.app 2>&1 | sed -n 's/^designated => //p')"
