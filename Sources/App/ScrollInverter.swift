import Foundation
import AppKit
import ApplicationServices
import ServiceManagement

/// Reverses scroll direction for mouse wheels only (the LinearMouse "reverse scrolling" feature).
/// Trackpads and Magic Mouse send *continuous* scroll events, real wheels send discrete line
/// ticks, so flipping only non-continuous events leaves the trackpad's natural scrolling alone.
@MainActor
final class ScrollInverter: ObservableObject {
    static let shared = ScrollInverter()

    @Published var reverseVertical: Bool { didSet { save(); syncTap() } }
    @Published var reverseHorizontal: Bool { didSet { save(); syncTap() } }
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var active = false
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustTimer: Timer?

    private init() {
        let d = UserDefaults.standard
        reverseVertical = d.bool(forKey: "reverseVertical")
        reverseHorizontal = d.bool(forKey: "reverseHorizontal")
        syncTap()
    }

    private func save() {
        UserDefaults.standard.set(reverseVertical, forKey: "reverseVertical")
        UserDefaults.standard.set(reverseHorizontal, forKey: "reverseHorizontal")
        InverterFlags.vertical = reverseVertical
        InverterFlags.horizontal = reverseHorizontal
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        watchForTrust()
    }

    private func watchForTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                self.trusted = AXIsProcessTrusted()
                if self.trusted { t.invalidate(); self.syncTap() }
            }
        }
    }

    func syncTap() {
        InverterFlags.vertical = reverseVertical
        InverterFlags.horizontal = reverseHorizontal
        let wanted = reverseVertical || reverseHorizontal
        if wanted && tap == nil {
            trusted = AXIsProcessTrusted()
            guard trusted else { active = false; watchForTrust(); return }
            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .defaultTap, eventsOfInterest: mask,
                                            callback: scrollTapCallback, userInfo: nil) else {
                active = false; return
            }
            InverterFlags.tap = t
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            tap = t; source = src
        }
        active = tap != nil && wanted
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("NagaControl login item: \(error)") }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Plain globals read from the event-tap callback (it runs on the main run loop).
enum InverterFlags {
    nonisolated(unsafe) static var vertical = false
    nonisolated(unsafe) static var horizontal = false
    nonisolated(unsafe) static var tap: CFMachPort?
}

private func negate(_ e: CGEvent, _ delta: CGEventField, _ fixed: CGEventField, _ point: CGEventField) {
    let d = e.getIntegerValueField(delta)
    let f = e.getDoubleValueField(fixed)
    let p = e.getIntegerValueField(point)
    e.setIntegerValueField(delta, value: -d)
    e.setDoubleValueField(fixed, value: -f)
    e.setIntegerValueField(point, value: -p)
}

private func scrollTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = InverterFlags.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {   // trackpad → untouched
        return Unmanaged.passUnretained(event)
    }
    if InverterFlags.vertical {
        negate(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
    }
    if InverterFlags.horizontal {
        negate(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
    }
    return Unmanaged.passUnretained(event)
}
