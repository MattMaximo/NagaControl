import Foundation
import AppKit
nonisolated(unsafe) var seen: [(Int64, Int64)] = []
let listen: CGEventTapCallBack = { _, type, e, _ in
  if type == .scrollWheel, e.getIntegerValueField(.eventSourceUserData) == 4242 {
    seen.append((e.getIntegerValueField(.scrollWheelEventDeltaAxis1), e.getIntegerValueField(.scrollWheelEventIsContinuous)))
  }
  return Unmanaged.passUnretained(e)
}
MainActor.assumeIsolated {
  print("trusted:", AXIsProcessTrusted())
  let inv = ScrollInverter.shared
  let lt = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                             eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue), callback: listen, userInfo: nil)!
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, lt, 0), .commonModes)
  func post(_ continuous: Bool) {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
    e.setIntegerValueField(.eventSourceUserData, value: 4242)
    if continuous { e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
    e.post(tap: .cghidEventTap)
  }
  let wasV = inv.reverseVertical
  inv.reverseVertical = false; post(false); RunLoop.main.run(until: Date().addingTimeInterval(0.4))
  inv.reverseVertical = true;  RunLoop.main.run(until: Date().addingTimeInterval(0.3)); print("tap active:", inv.active)
  post(false); post(true); RunLoop.main.run(until: Date().addingTimeInterval(0.5))
  inv.reverseVertical = wasV
  print("events (deltaY, continuous):", seen)
}
