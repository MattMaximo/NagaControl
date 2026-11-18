// UI tool: proves remapping with synthetic events (no mouse I/O). Posts a button-3 click and a fake
// "report 4" sniper press; expects F1 then F3 key events and the original button-3 events swallowed.
import Foundation
import AppKit
nonisolated(unsafe) var seen: [String] = []
let listen: CGEventTapCallBack = { _, type, e, _ in
  if type == .keyDown || type == .keyUp { seen.append("\(type == .keyDown ? "down" : "up") key \(e.getIntegerValueField(.keyboardEventKeycode)) fn=\(e.flags.contains(.maskSecondaryFn))") }
  if (type == .otherMouseDown || type == .otherMouseUp) && e.getIntegerValueField(.eventSourceUserData) == 777 { seen.append("LEAKED button \(e.getIntegerValueField(.mouseEventButtonNumber))") }
  return Unmanaged.passUnretained(e)
}
MainActor.assumeIsolated {
  let r = ButtonRemapper.shared
  print("accessibility:", AXIsProcessTrusted())
  let mask = [CGEventType.keyDown, .keyUp, .otherMouseDown, .otherMouseUp].reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
  let lt = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: listen, userInfo: nil)!
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, lt, 0), .commonModes)
  let pid: UInt16 = 0x0099
  let before = (r.action(pid, .back), r.action(pid, .sniper))
  r.setConnected([pid])
  r.setAction(pid, .back, .fKey(1))
  RunLoop.main.run(until: Date().addingTimeInterval(0.3)); print("tap:", RemapFlags.tap != nil, "enabled:", RemapFlags.enabled, "actions:", RemapFlags.actions)
  for down in [true, false] {
    let e = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .center)!
    e.setIntegerValueField(.mouseEventButtonNumber, value: 3); e.setIntegerValueField(.eventSourceUserData, value: 777)
    e.post(tap: .cghidEventTap)
  }
  RunLoop.main.run(until: Date().addingTimeInterval(0.5))
  r.setAction(pid, .sniper, .fKey(3))
  r.handleReport(reportID: 4, [0x04, 0x51, 0, 0]); r.handleReport(reportID: 4, [0x04, 0, 0, 0])
  RunLoop.main.run(until: Date().addingTimeInterval(0.5))
  print("lastPressed:", r.lastPressed?.rawValue ?? "-", "wantsDriverMode:", r.wantsDriverMode(pid))
  r.setAction(pid, .back, before.0); r.setAction(pid, .sniper, before.1); r.setConnected([])
  print(seen.joined(separator: "\n"))
}
