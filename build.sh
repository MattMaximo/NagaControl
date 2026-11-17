#!/bin/zsh
# Builds NagaControl.app (universal: arm64 + x86_64) into ./build
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
APP="$OUT/Naga Control.app"
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  clang -c -O2 -arch $ARCH -mmacosx-version-min=14.0 Sources/RazerTransport/razer_transport.c -o "$OUT/obj/transport_$ARCH.o"
  swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 \
    -import-objc-header Sources/RazerTransport/razer_transport.h \
    Sources/App/*.swift "$OUT/obj/transport_$ARCH.o" \
    -framework IOKit -framework CoreFoundation -framework SwiftUI -framework AppKit \
    -o "$OUT/obj/NagaControl_$ARCH"
done
lipo -create "$OUT/obj/NagaControl_arm64" "$OUT/obj/NagaControl_x86_64" -output "$APP/Contents/MacOS/NagaControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
echo "Built $APP"
