# Naga Control

Small native macOS app that replaces Razer Synapse, OpenSnek and LinearMouse for Matt's mice:
the original Naga Epic (1532:001F) and the Basilisk V3 (1532:0099).
Also has entries for the Naga Epic Chroma (003E wired, 003F dock) and Basilisk V3 35K (00CB).

- DPI (presets, separate X/Y), polling rate, lighting + brightness, sleep timer, battery.
- Basilisk V3: free-spin / Smart Reel / scroll acceleration.
- Reverse scrolling for mouse wheels only (the trackpad keeps its own setting). Needs Accessibility permission.
- Settings are written to the mouse's onboard memory (VARSTORE), so they stick without the app running.
  The app only has to run for reversed scrolling.
- Menu-bar icon with quick DPI presets; optional open at login.
- Log: ~/Library/Logs/NagaControl.log (restarts at 1 MB); "Copy diagnostics" button in the app.

## Layout
- `Sources/RazerTransport/razer_transport.{c,h}`: sends one 90-byte report and reads the reply.
  USB control transfer first, IOHID feature report as fallback.
- `Sources/App/RazerProtocol.swift`: the report, the model table, every command, reply checking and parsing.
  No device access, so the selftest covers it. Protocol from OpenRazer (`driver/razerchromacommon.c`, `razermouse_driver.c`).
- `Sources/App/MouseController.swift`: device list, state, reads/writes, retries. All USB work on one serial queue.
- `Sources/App/ScrollInverter.swift`: the event tap that flips wheel scrolling, and the login item.
- `Sources/App/NagaControlApp.swift`: window and menu-bar UI.

## Build and test
    ./build.sh        # -> build/Naga Control.app (universal). Wipes build/ first.
    swiftc -swift-version 5 Sources/App/RazerProtocol.swift Sources/App/ButtonRemapper.swift Tests/main.swift -o build/selftest && build/selftest

The selftest needs no mouse. It prints `ALL PASS` and exits 0 only when every check passed.
UI preview with no Razer device plugged in: `NAGA_DEMO=0099 build/Naga\ Control.app/Contents/MacOS/NagaControl`
(the value is the product id in hex: `0099` Basilisk V3, `001F` Naga Epic; anything else shows the unknown-device layout).

### Live tools (they talk to the real mouse or post scroll events; never run while Matt is using the mice)
Build after `./build.sh`, with `O=build/obj/transport_$(uname -m).o H=Sources/RazerTransport/razer_transport.h`:

    swiftc -swift-version 5 -import-objc-header $H Sources/App/RazerProtocol.swift Sources/App/MouseController.swift Tests/harness/main.swift $O -framework IOKit -framework CoreFoundation -o build/harness
    swiftc -swift-version 5 -import-objc-header $H Sources/App/RazerProtocol.swift Tests/probe/main.swift $O -framework IOKit -framework CoreFoundation -o build/probe
    swiftc -swift-version 5 Sources/App/ScrollInverter.swift Tests/scroll/main.swift -o build/scrolltest

- `harness`: reads the mouse, sets DPI 800 / 1800 / back to the original, then sets the scroll-wheel light to Spectrum (not restored).
- `probe`: one-off. Writes byte-DPI 2409 to the first Razer device it finds. Only valid for the original Naga Epic.
- `scrolltest`: posts synthetic scroll events and checks they come out reversed. Flips the reverse setting briefly.
- `Tests/render`: renders the window to a PNG. Needs the app sources with `@main` removed.

## Notes for live testing
- Test harnesses must read the mouse's current values first and restore them after (Matt uses the mice live).
- IOUSBHostDevice matching ignores idVendor in the matching dict on macOS 27: enumerate all, filter manually.
- Original Naga Epic (001F) answers DPI writes with an all-zero report; confirm via read-back instead.
  That empty reply is accepted for writes on the legacy family only.
- Naga Epic stores DPI as one byte per axis (0...6750), so 800 reads back as 794.
- Basilisk V3 (0099): transaction id 0x1F, control transfers to interface 3 (per OpenRazer). Not yet verified live.
  Checklist: `.audit/FABLE-REVIEW.md`.
- Scroll reversal: CGEventTap flips only non-continuous (wheel) events; needs Accessibility permission.
