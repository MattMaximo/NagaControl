// LIVE TOOL: talks to the real mouse. Sets DPI 800, 1800, then the original value, and sets the
// scroll-wheel light to Spectrum (not restored). Never run while Matt is using the mice.
import Foundation
import SwiftUI
@MainActor func go() {
  let m = MouseController()
  RunLoop.main.run(until: Date().addingTimeInterval(3))
  print("read:", m.selected?.model.name ?? "-", m.dpiX, "DPI, poll", m.pollRate, "batt", m.battery ?? -1, "status:", m.status)
  let orig = m.dpiX
  for v in [800, 1800, orig] {
    m.dpiX = v; m.dpiY = v; m.applyDPI(debounce: false)
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    print("set \(v):", m.status, "| app shows", m.dpiX)
  }
  m.effects[.scrollWheel] = .spectrum; m.applyLighting(.scrollWheel)
  RunLoop.main.run(until: Date().addingTimeInterval(2)); print("lighting:", m.status)
}
MainActor.assumeIsolated { go() }
