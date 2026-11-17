# Naga Control

Tiny Synapse replacement for Matt's Razer Naga Epic Chroma (2014/15, wired + dock) on macOS.
Also handles the original Naga Epic (1532:001F) and Naga 2014 (1532:0040).

- DPI (100–8200, presets, separate X/Y), polling rate, scroll/side-panel lighting + brightness, sleep timer, battery.
- Settings are written to the mouse's onboard memory (VARSTORE) — they stick without the app running.
- Transport: Razer 90-byte feature report via USB control transfer (fallback: IOHID feature report).
  Protocol from OpenRazer (driver/razerchromacommon.c, razermouse_driver.c).
- Menu-bar icon has quick DPI presets.
- Log: ~/Library/Logs/NagaControl.log ; "Copy diagnostics" button in the app.

Build: ./build.sh   (UI preview without a mouse: NAGA_DEMO=1 build/Naga\ Control.app/Contents/MacOS/NagaControl)
Self-test of packet encoding: swiftc -swift-version 5 Sources/App/RazerProtocol.swift Tests/main.swift -o build/selftest && build/selftest
