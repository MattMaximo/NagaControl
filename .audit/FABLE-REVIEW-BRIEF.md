# Fable: review + cleanup of Naga Control

## Matt's ask
"Have Fable do a review and cleanup" of Naga Control, a small native macOS app (SwiftUI + IOKit C) that replaces Razer Synapse, OpenSnek and LinearMouse for Matt's two mice. Matt is gaming on this Mac right now. Don't disturb his mice, his screen or the running app.

## Where things stand
- Repo: `/Users/boostudio/NagaControl` (git, branch master, no remote). Read `README.md` first.
- Sources: `Sources/RazerTransport/razer_transport.{c,h}` (USB control transfer + IOHID fallback), `Sources/App/RazerProtocol.swift` (90-byte Razer report, models, commands), `Sources/App/MouseController.swift` (state, reads/writes, retries), `Sources/App/ScrollInverter.swift` (CGEventTap that reverses wheel-only scrolling), `Sources/App/NagaControlApp.swift` (UI + menu bar).
- Tests: `Tests/main.swift` (packet-encoding selftest; build: `swiftc -swift-version 5 Sources/App/RazerProtocol.swift Tests/main.swift -o build/selftest && build/selftest`). `Tests/probe`, `Tests/harness`, `Tests/scroll` and `Tests/render` are live-device and UI tools; see the gates below.
- Build: `./build.sh` → `build/Naga Control.app` (universal).
- Protocol ground truth: OpenRazer clone at `~/.hermes/cache/scratch/razer-src/openrazer` (`driver/razermouse_driver.c`, `driver/razerchromacommon.c`, `daemon/openrazer_daemon/hardware/mouse.py`).
- Verified live: original Naga Epic (1532:001F). Reads, DPI byte writes, lighting and polling all work over the USB control path. Its DPI writes answer with an all-zero report, so the write is confirmed with a read-back.
- Not yet verified live: Basilisk V3 (1532:0099; tid 0x1F, wIndex 3, extended 0x0F lighting, scroll mode/accel/smart reel). Naga Epic Chroma entries come from OpenRazer only.

## Review questions
1. Correctness vs OpenRazer for every model entry. Check each command, the transaction id, the interface index, VARSTORE/NOSTORE, response parsing (battery scale, idle, DPI) and the Basilisk extended lighting. Flag anything that would misbehave on a real Basilisk V3.
2. Transport robustness: memory/handle leaks in `razer_transport.c`, the retry/BUSY handling, the all-zero-ack special case (is it too permissive for reads or for other models?), the IOHID fallback and the location matching.
3. Concurrency/UI: main-actor correctness, debounce logic, stale state when switching devices, timer/polling cost.
4. ScrollInverter: event-tap correctness (do the negated fields cover all three delta representations; are momentum and phase fields safe?), re-enable on timeout, behavior when Accessibility is revoked, the login item.
5. Dead code, duplication, naming, file layout. Is a tidier structure worth it at this size? Keep it small.

## Cleanup you may do (direct edits OK)
- Fix real bugs you find, remove dead code, tighten naming, and add selftest cases for anything you change in protocol encoding/parsing.
- Make small, separate local git commits with clear messages.
- Every commit must leave the project green: `./build.sh` succeeds and `build/selftest` prints ALL PASS.

## Hard gates
- **No device I/O at all.** Don't run `build/probe`, `build/harness`, `build/scrolltest` or any code that talks to the mice or posts or taps events. Matt is mid-game. Static review only, plus `build.sh` and `selftest`.
- Don't launch, quit or replace `/Applications/Naga Control.app`. Don't touch the iCloud Inbox zip. Don't run `codesign`.
- No visual redesign. Keep the layout and the controls Matt sees. Pure bug fixes to UI behavior are fine. List anything bigger as a proposal.
- No new dependencies, no push, no network beyond reading local files.
- Don't modify the OpenRazer clone.

## Deliverables
1. `/Users/boostudio/NagaControl/.audit/FABLE-REVIEW.md`: verdict; evidenced findings (file:line, severity, fixed or proposed); a list of the commits you made; anything Matt or Boo must decide; and a live-test checklist for the Basilisk V3 when it's plugged in.
2. Your local commits.
3. A final reply of ≤10 plain-English lines: what you fixed, what you only proposed, whether build and selftest are green, and follow-ups for Matt.
