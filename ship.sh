#!/bin/zsh
# Wire icons in, build, sign (Developer ID, hardened runtime), notarize, staple, install, and drop a zip in the iCloud Inbox.
set -euo pipefail
cd "$(dirname "$0")"
KC="/Users/boostudio/Library/Application Support/Boo Hermes Desktop/DevelopmentSigning/BooDevelopment.keychain-db"
ID="Developer ID Application: Mathew Maximo (8Z64Q39H79)"
APP="build/Naga Control.app"
INBOX="/Users/boostudio/Library/Mobile Documents/com~apple~CloudDocs/Hermes/Inbox/NagaControl"

cp Design/AppIcon.icns Resources/AppIcon.icns
cp Design/MenuBarIcon.png Resources/MenuBarIcon.png
cp Design/MenuBarIcon@2x.png Resources/MenuBarIcon@2x.png
./build.sh
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
swiftc -swift-version 5 Sources/App/RazerProtocol.swift Tests/main.swift -o build/selftest && build/selftest | tail -1

op read --no-newline "op://BooStudio/Boo Desktop Signing/keychain-password" | ~/Tools/keychain-unlock/unlock "$KC"
codesign --force --options runtime --timestamp --keychain "$KC" --sign "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f build/notarize.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile BooNotary --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"

pkill -f "Naga Control.app/Contents/MacOS/NagaControl" || true
sleep 1
rm -rf "/Applications/Naga Control.app"
ditto "$APP" "/Applications/Naga Control.app"
mkdir -p "$INBOX"
rm -f "$INBOX/Naga Control.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$INBOX/Naga Control.zip"
shasum -a 256 "$INBOX/Naga Control.zip"
open "/Applications/Naga Control.app"
sleep 4
pgrep -fl "Naga Control.app/Contents/MacOS/NagaControl"
echo SHIP-OK
