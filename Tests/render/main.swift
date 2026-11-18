// UI tool: renders the panel to the PNG path given as the first argument (default layout: Basilisk V3).
// Usage: build/render out.png [pid-hex]. Run from the repo root so Design/AppIcon.icns is found.
// Creates a MouseController, so it also scans USB and reads the mouse once (reads only, no writes).
import SwiftUI
import AppKit
MainActor.assumeIsolated {
  _ = NSApplication.shared
  NSImage(contentsOfFile: "Design/AppIcon.icns")?.setName("AppIcon")
  let m = MouseController()
  let pid = CommandLine.arguments.count > 2 ? UInt16(CommandLine.arguments[2], radix: 16) ?? 0x0099 : 0x0099
  m.selected = FoundDevice(pid: pid, location: 0, product: "Preview")
  m.dpiX = 3200; m.dpiY = 3200; m.pollRate = 1000; m.firmware = "v1.2"; m.transportPath = "USB control"
  m.smartReel = true
  m.status = "Smart Reel on"; m.statusIsError = false
  m.battery = m.selected!.model.wireless ? 73 : nil
  for z in m.selected!.model.zones { m.effects[z] = .spectrum; m.brightness[z] = 80 }
  if let last = m.selected!.model.zones.last { m.effects[last] = .staticColor }
  let v = ContentView().environmentObject(m).environmentObject(ScrollInverter.shared)
    .frame(width: 360).fixedSize(horizontal: false, vertical: true).preferredColorScheme(.light)
  let host = NSHostingView(rootView: v)
  let size = host.fittingSize
  host.frame = NSRect(origin: .zero, size: size)
  let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = host; win.appearance = NSAppearance(named: .aqua); host.layoutSubtreeIfNeeded()
  NSApp.setActivationPolicy(.accessory); win.orderFrontRegardless(); win.makeKey(); NSApp.activate(ignoringOtherApps: true)
  RunLoop.main.run(until: Date().addingTimeInterval(1)); host.frame.size = host.fittingSize; RunLoop.main.run(until: Date().addingTimeInterval(0.5)); m.status = "Smart Reel on"; m.statusIsError = false; RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!; host.cacheDisplay(in: host.bounds, to: rep)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  print("rendered \(Int(size.width))x\(Int(size.height))")
}
