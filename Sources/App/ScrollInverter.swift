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
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

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
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        syncTap()
    }

    /// While reversing is switched on, notice Accessibility being granted or taken away.
    private func watchTrust(_ on: Bool) {
        if !on { trustTimer?.invalidate(); trustTimer = nil; return }
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Also retries a tap that could not be created the first time.
                if AXIsProcessTrusted() != self.trusted || (self.trusted && self.tap == nil) { self.syncTap() }
            }
        }
    }

    /// Brings the event tap in line with the two switches and the Accessibility permission.
    private func syncTap() {
        InverterFlags.vertical = reverseVertical
        InverterFlags.horizontal = reverseHorizontal
        let wanted = reverseVertical || reverseHorizontal
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted { trusted = nowTrusted }
        if !nowTrusted { removeTap() }                 // permission revoked: don't keep a dead tap
        else if wanted && tap == nil { installTap() }
        // With both switches off the tap stays installed but disabled, so scroll events
        // no longer make a round trip through this app.
        if let tap { CGEvent.tapEnable(tap: tap, enable: wanted) }
        let nowActive = wanted && tap != nil
        if nowActive != active { active = nowActive }
        watchTrust(wanted)
    }

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: scrollTapCallback, userInfo: nil) else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        InverterFlags.tap = t
        tap = t; source = src
    }

    private func removeTap() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(t)
        InverterFlags.tap = nil
        tap = nil; source = nil
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

/// A scroll event carries one axis three ways: whole lines, 16.16 fixed-point lines, and pixels.
/// Read all three before writing: setting the line delta makes CoreGraphics recompute the other two.
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
        // macOS switched the tap off (slow callback, secure input). Turn it back on if still wanted.
        if let t = InverterFlags.tap, InverterFlags.vertical || InverterFlags.horizontal {
            CGEvent.tapEnable(tap: t, enable: true)
        }
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
