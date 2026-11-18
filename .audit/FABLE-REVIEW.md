# Naga Control: review and cleanup

Reviewer: Fable (claude-fable-5-2). Finished 2026-11-17 19:20 EST.
Scope: static review against the OpenRazer clone, plus `./build.sh` and the selftest. No device I/O, nothing launched, nothing signed, nothing pushed.
Line numbers are for HEAD `61370e2`. "OR" is the OpenRazer clone at `~/.hermes/cache/scratch/razer-src/openrazer`.

## Verdict

**Good shape. Safe to keep using on the Naga Epic. The Basilisk V3 path matches OpenRazer byte for byte, with two lighting options OpenRazer never tested on that model.**

- Every command the app sends matches OpenRazer for all six model entries: class, command id, size, arguments, transaction id, interface index and stored-vs-temporary flag.
- I found no bug that would send a wrong packet. The bugs were around the edges: stale state when the mouse changes, extra DPI writes, a scroll tap that stayed on when unused, one small handle leak.
- 10 commits, each one builds and passes the selftest (checked one by one in a scratch worktree). The selftest went from 13 checks to 55.
- None of the changes has run on a real mouse yet. The installed app is still the old build (see "Decisions").

## What I could not verify

- Anything on real hardware. Every behaviour change below is static reasoning plus the selftest.
- Off and Breathing on the Basilisk V3 (finding P1).
- That restricting the empty reply to the legacy family (commit `4bf18ef`) leaves the Naga Epic's DPI write working. The Naga Epic is in the legacy family, so it should; it needs one live DPI change to confirm.

## Findings

Severity: High = wrong behaviour Matt would hit. Medium = wrong in a less common case. Low = cosmetic or unlikely.

### 1. Protocol vs OpenRazer

| # | Finding | Severity | Status |
|---|---|---|---|
| P1 | Basilisk V3 (0099): the app offers **Off** and **Breathing**. OR exposes only static, wave and spectrum for it. `razer_attr_write_matrix_effect_none_common` (OR `razermouse_driver.c:5408-5547`) has a case for the 35K but none for 0099; `..._breath_common` (`:4972-5190`) has neither. The packets the app sends (`RazerProtocol.swift:186`, `:190`) are the standard extended ones, so they will probably work, but nobody has confirmed it. | Medium | Proposed: live test. If Off does nothing, send brightness 0 instead. If Breathing does nothing, hide it for this model. |
| P2 | Interface index 3 and transaction id 0x1F for 0099 and 00CB (`RazerProtocol.swift:127-132`) match OR `razermouse_driver.c:112-116` and the per-command `transaction_id.id = 0x1f` cases. | – | Correct |
| P3 | DPI is always written as stored (VARSTORE). OR's `razer_chroma_misc_set_dpi_xy` ignores its own parameter and hardcodes VARSTORE (`razerchromacommon.c:1213-1225`), so this is what OR puts on the wire too. | – | Correct, not a deviation |
| P4 | Reply parsing matches OR: battery is `arg[1]` of 255 (daemon divides by 255 × 100), charging `arg[1]`, idle `arg[0]<<8 \| arg[1]` seconds, DPI big-endian at args 1-4, byte DPI at args 0-1 with scale 6750, poll rate 1/2/8 → 1000/500/125. Now in one place: `RazerProtocol.swift:69-80`. | – | Correct; moved and tested in `4bf18ef` |
| P5 | Extended lighting (class 0x0F): none, static, breathing, spectrum, brightness set and get all match `razerchromacommon.c` for size and argument layout. Zones logo 0x04, scroll 0x01, all 0x00 match. | – | Correct |
| P6 | Scroll mode (02/14, 02/94), acceleration (02/16, 02/96), Smart Reel (02/17, 02/97): match, reply read from `arg[1]`. | – | Correct |
| P7 | Legacy lighting (class 0x03) for the Naga family: ids, sizes, LED ids and the state → colour → effect order match. Transaction ids 0x3F / 0xFF match. | – | Correct |
| P8 | Original Naga Epic (001F): the app offers Breathing; OR exposes only none, static, spectrum for it. Lighting was verified live, so low risk. | Low | Proposed: confirm Breathing once, or hide it |
| P9 | Naga 2014 (0040): OR exposes only on/off for scroll, logo and backlight. The app's entry (`RazerProtocol.swift:126`) has scroll + side panel, no logo, and offers effects and brightness. Matt does not own one. | Low | Proposed: fix or delete the entry |
| P10 | The app never writes the Basilisk's DPI stage list (04/06). Setting DPI in the app works, but pressing the mouse's DPI buttons afterwards jumps to the stages stored on the mouse. | Low | Proposed only if Matt wants the buttons to match the presets |

### 2. Transport

| # | Finding | Severity | Status |
|---|---|---|---|
| T1 | `rz_list_devices` leaked one IOKit handle per scan when the output array was full (old loop took the next object, then checked the count). | Low | Fixed `31aa226` (`razer_transport.c:56-80`) |
| T2 | The device scan runs every 3 s and read product strings for every USB device on the Mac. It now checks the vendor first. | Low | Fixed `31aa226` |
| T3 | **The all-zero reply was accepted for any command on any model**, reads included. A read answered by all zeros parsed as "DPI 0, battery 0 %". On a Basilisk V3 a wrong interface or the HID fallback hitting the wrong HID interface would have looked like success. OR treats an all-zero reply as a mismatch. Now it is accepted only for a write, only on the legacy family (`RazerProtocol.swift:57-67`, `:119`). | Medium | Fixed `4bf18ef`, with 34 new selftest checks for reply checking and parsing |
| T4 | Retry and BUSY handling (`MouseController.swift:134-164`): 4 tries, resend on I/O error or wrong reply, accept BUSY after the last try, stop at once on "not supported". This follows OR's `razer_send_payload` (5 tries, BUSY counts as success). | – | Correct |
| T5 | `DeviceRequest` has no timeout (`razer_transport.c:123`, `:136`). A mouse that stops answering mid-transfer would block the USB queue (not the UI) until macOS gives up. OR uses 5 s. | Low | Proposed: `DeviceRequestTO` with 1 s. Needs a live test, so I left it. |
| T6 | Every transfer walks the whole USB device list and creates a new plug-in interface (`razer_transport.c:82-110`). A full read is about 10 transfers. Fine at this size. | Low | Proposed only if reads ever feel slow: cache the device interface per location |
| T7 | HID fallback ignores the interface index (`razer_transport.c:211-216`) and matches location on the top 16 bits only (`:185`). It tries the mouse interface first, then every other one. For the Basilisk V3 (control interface 3) it may talk to the wrong interface. After T3 that gives a clear error instead of fake success. | Low | Left as is. The USB path is the real one; the fallback only matters if another app holds the device. |
| T8 | No memory leaks found in the transfer paths. Every `IOObjectRelease` / `CFRelease` / `Release` pairs up on all exits. `g_mgr` is created once and only touched from the serial USB queue. `calloc` failure now handled. | – | Checked; small fix in `31aa226` |
| T9 | `rz_close_all` and `rz_device_info.vendorID` were never used. | – | Removed `31aa226` |

### 3. Concurrency and UI

| # | Finding | Severity | Status |
|---|---|---|---|
| U1 | **Stale state on device change.** Unplugging or switching mice kept the old mouse's battery in the header, and its firmware, lighting and wheel state. A batch still in flight wrote its results into the new mouse's state. | Medium | Fixed `04eefd6` (`MouseController.swift:115-125`, guard at `:182`) |
| U2 | **Stray writes to the wrong mouse.** A debounced colour or DPI change still pending when the mouse changed was sent to the new one. The colour debounce lived in the view. | Medium | Fixed `04eefd6` (`:117-119`, `:308-311`) |
| U3 | **Extra DPI writes.** `onChange(linkXY)` fired on every read and menu preset, sending a second stored-settings DPI write each time. | Medium | Fixed `004d49d` (`setLinkXY`, `:284-287`) |
| U4 | Preset chips and the menu tick went dark on the Naga Epic after a re-read, because 800 reads back as 794. | Low | Fixed `004d49d` (`isCurrentDPI`, `:291-294`) |
| U5 | The refresh button and both Rescan buttons did nothing when the same mouse was still plugged in. | Low | Fixed `c065cc4` |
| U6 | "Sleep after idle" picker went blank if the mouse reported a value not in the list (4 min, say). | Low | Fixed `a20b593` (`NagaControlApp.swift:243`) |
| U7 | `~/Library/Logs/NagaControl.log` grew forever. A wireless mouse asleep on its dock logs one failed battery read every 30 s. | Low | Fixed `a20b593`: restarts at 1 MB (`MouseController.swift:388-399`) |
| U8 | Default lighting colour was Razer green on screen but system green when sent to the mouse. | Low | Fixed `a20b593` |
| U9 | Main-actor use is correct: all state changes on main, all USB work on one serial queue (`:61`), results hop back with `DispatchQueue.main.async`. No blocking calls on the main thread except the 3-second device scan, which is cheap after T2. | – | Checked |
| U10 | Timer cost: one 3 s scan, a battery read every 30 s for wireless models only (`:247-253`), a 2 s Accessibility check only while reversing is on. | – | Fine |
| U11 | `WindowGroup` (`NagaControlApp.swift:12`) allows several windows and opens one at every login. There is no "Open window" item in the menu-bar menu. | Low | Proposed (changes what Matt sees): `Window` scene, start hidden at login, add the menu item |

### 4. ScrollInverter

| # | Finding | Severity | Status |
|---|---|---|---|
| S1 | All three delta forms are negated per axis: line, 16.16 fixed-point, pixel (`ScrollInverter.swift:123-130`). All three are read before any write, which matters because setting the line delta makes CoreGraphics recompute the others. | – | Correct |
| S2 | Phase and momentum fields are not touched, and do not need to be. Wheel events carry no phase. Trackpad and Magic Mouse events are continuous and are passed through untouched (`:141-144`). | – | Correct |
| S3 | **The tap stayed enabled with both switches off**, so every scroll event on the Mac still went through this app's main thread for nothing. | Medium | Fixed `26f4d86` (`:80`) |
| S4 | **Accessibility revoked later:** the check only ran until permission was first granted. After a revoke the app kept a dead tap, kept re-enabling it and still showed "active". Now it tears the tap down, shows the "Needs Accessibility" row, and reinstalls when permission returns (`:57-84`). | Medium | Fixed `26f4d86` |
| S5 | Re-enable after timeout or secure input (`:134-140`): correct, and now only when a switch is on. | – | Correct; tightened `26f4d86` |
| S6 | "Open at login" only read the system state at launch. Removing the login item in System Settings left the switch on. | Low | Fixed `61370e2` (`:27-40`) |
| S7 | The tap callback runs on the main run loop (`:92`). If the app's main thread stalls, wheel scrolling stalls system-wide until macOS disables the tap. S3 removes this when reversing is off. | Low | Proposed: move the tap to its own thread. Needs a live scroll test. |

### 5. Structure

- Five Swift/C source files plus one header, about 1,360 lines. The split (transport / protocol / controller / scroll / UI) is right. **A tidier structure is not worth it at this size.** I would not split further.
- Removed: `rz_close_all`, `vendorID`, `Binding.inverted`, `byteDPI ? 50 : 50`, a `DateFormatter` built for every log line.
- Reply checking and parsing moved from the controller into `RazerProtocol.swift`, where the selftest can reach them.
- README described a different mouse (Naga Epic Chroma only). Rewritten in `f834e21`, with the build line for each test tool.
- The live test tools now start with a comment saying what they write to the mouse. `Tests/probe` writes DPI 2409 to the first Razer device it finds, which would be wrong on the Basilisk.

## Commits

All on `main`, on top of `110f34b`. Each one: `./build.sh` succeeds and the selftest prints ALL PASS.

| Commit | What |
|---|---|
| `124d022` | selftest: exit non-zero on failure, print ALL PASS once at the end |
| `31aa226` | transport: fix device-list handle leak, drop unused code |
| `4bf18ef` | protocol: testable reply check and parsing; empty ack only on legacy mice |
| `04eefd6` | controller: no stale state or stray writes when the mouse changes |
| `c065cc4` | Rescan re-reads the current mouse |
| `004d49d` | DPI: no writes on read, Y follows X while linked, presets light up after re-read |
| `26f4d86` | scroll: switch the tap off when unused, survive Accessibility being revoked |
| `a20b593` | tidy: idle picker never blank, capped log file, one default colour |
| `f834e21` | docs: README matches the app; label the live test tools; ignore run logs |
| `61370e2` | Open at login switch follows System Settings |

The four tools under `Tests/` (harness, probe, scroll, render) still compile against the changed code. They were type-checked and linked only, never run.

## Decisions for Matt or Boo

1. **Install the new build.** The app running now is the build from before this review (binary hash differs from `build/Naga Control.app`). Installing needs a sign and a relaunch, which I was told not to do. Do it when Matt is not mid-game, then run the checklist below.
2. **Basilisk V3 Off and Breathing (P1).** Keep both and test, or hide them until tested. I kept them.
3. **Window behaviour (U11).** One window that stays hidden at login, plus an "Open window" menu item? It changes what Matt sees, so I did not do it.
4. **Transfer timeout (T5) and tap thread (S7).** Both are small, both need a live test. Say the word and they are a 20-minute job each.
5. **Naga 2014 entry (P9).** Delete it, or correct it from OpenRazer? Matt does not own one.

## Live-test checklist

Run with the new build installed. `tail -f ~/Library/Logs/NagaControl.log` in a terminal shows every failed command.

### Basilisk V3 (first time on real hardware)
1. Plug in. The header shows "Basilisk V3", a firmware version and "USB control". No battery shown. If it says "HID feature" instead, tell Boo (T7).
2. DPI: pick 800, 1600, 3200. Pointer speed changes each time and the status line says "DPI set to …". Rescan: the same value comes back.
3. Separate X / Y: set 800 × 1600, check the pointer is slower sideways. Switch it off: Y returns to X with one write.
4. Polling rate: 125, 500, 1000. Each sticks after Rescan.
5. Lighting, for each of All lights, Logo, Scroll wheel:
   - Static with a colour, then Spectrum. These are the OpenRazer-tested ones.
   - **Off.** Does the zone go dark? If not, tell Boo (P1).
   - **Breathing.** Does it pulse in the chosen colour? If not, tell Boo (P1).
   - Brightness slider at 0, 50, 100.
6. Wheel: switch free-spin on and off (the wheel should change feel at once), then Smart Reel, then scroll acceleration. Rescan: all three read back as set.
7. Unplug and replug. Settings are still there (they are stored on the mouse).
8. Quit the app. DPI and lighting stay. Reverse scrolling stops (expected).

### Both mice (behaviour changed in this review)
9. Naga Epic: change DPI once. Status says "DPI set to …" with no error (confirms `4bf18ef`).
10. Naga Epic: pick 800, press Rescan. The 800 chip stays lit.
11. With both mice plugged in, switch between them in the picker. Battery, firmware and lighting belong to the mouse shown. The Basilisk shows no battery.
12. Drag a colour on one mouse and switch mice straight away. The other mouse's colour must not change.
13. Unplug the selected mouse. The header clears within about 3 seconds.
14. Reverse scrolling: wheel reverses, trackpad does not. Switch both directions off: scrolling is normal.
15. System Settings → Privacy → Accessibility: switch Naga Control off while reversing is on. Within 2 seconds the app shows "Needs Accessibility" and scrolling is normal. Switch it back on: reversing returns without a relaunch.
16. System Settings → General → Login Items: remove Naga Control, come back to the app. The "Open at login" switch is off.
