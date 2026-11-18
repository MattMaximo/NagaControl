// UI tool: renders the window (Basilisk V3 layout) to the PNG path given as the first argument.
// Creates a MouseController, so it also scans USB and reads the mouse once.
import SwiftUI
import AppKit
MainActor.assumeIsolated {
  _ = NSApplication.shared
  let m = MouseController()
  m.selected = FoundDevice(pid: 0x0099, location: 0, product: "Basilisk V3")
  m.dpiX = 1600; m.dpiY = 1600; m.battery = nil; m.pollRate = 1000; m.firmware = "v1.2"; m.transportPath = "USB control"
  for z in m.selected!.model.zones { m.effects[z] = .spectrum; m.brightness[z] = 80 }
  let v = ContentView().environmentObject(m).environmentObject(ScrollInverter.shared).frame(width: 480, height: 1100).preferredColorScheme(.dark)
  let host = NSHostingView(rootView: v); host.frame = NSRect(x: 0, y: 0, width: 480, height: 1100)
  let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = host; win.appearance = NSAppearance(named: .darkAqua); host.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(1))
  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!; host.cacheDisplay(in: host.bounds, to: rep)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  print("rendered")
}
