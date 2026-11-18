import Foundation
import AppKit
import IOKit.hid
import SwiftUI

/// Mouse buttons we can remap.
/// - `back`/`forward`/`middle` are normal mouse buttons: caught with an event tap (Accessibility).
/// - The rest are Razer "special" buttons. They only reach the computer once the mouse is in
///   driver mode (OpenRazer's device_mode 0x03); they then arrive as codes on the mouse's keyboard
///   interface ("report 4", see OpenRazer razermouse_driver.c REP4_*), read via IOHID (Input Monitoring).
enum MouseButtonID: String, CaseIterable, Codable, Identifiable {
    case back, forward, middle, sniper, tiltLeft, tiltRight, dpiUp, dpiDown, dpiCycle, scrollMode, profile
    var id: String { rawValue }

    var label: String {
        switch self {
        case .back: return "Side: back"
        case .forward: return "Side: forward"
        case .middle: return "Wheel click"
        case .sniper: return "Side: front paddle"
        case .tiltLeft: return "Wheel tilt left"
        case .tiltRight: return "Wheel tilt right"
        case .dpiUp: return "Top: DPI up"
        case .dpiDown: return "Top: DPI down"
        case .dpiCycle: return "Top: DPI cycle"
        case .scrollMode: return "Top: wheel mode"
        case .profile: return "Bottom: profile"
        }
    }

    /// CGEvent mouse button number for the normal buttons.
    var mouseButtonNumber: Int64? {
        switch self { case .middle: return 2; case .back: return 3; case .forward: return 4; default: return nil }
    }

    /// OpenRazer "report 4" code for the special buttons.
    var rep4Code: UInt8? {
        switch self {
        case .dpiUp: return 0x20; case .dpiDown: return 0x21
        case .tiltLeft: return 0x22; case .tiltRight: return 0x23
        case .profile: return 0x50; case .sniper: return 0x51
        case .dpiCycle: return 0x52; case .scrollMode: return 0x54
        default: return nil
        }
    }
    var needsDriverMode: Bool { rep4Code != nil }

    static func fromRep4(_ c: UInt8) -> MouseButtonID? { allCases.first { $0.rep4Code == c } }
}

enum ButtonAction: Hashable, Codable, Identifiable {
    case standard          // what the button does out of the box
    case disabled
    case fKey(Int)         // 1...12
    case mouseBack, mouseForward, middleClick
    var id: String { label }

    var label: String {
        switch self {
        case .standard: return "Default"
        case .disabled: return "Do nothing"
        case .fKey(let n): return "F\(n)"
        case .mouseBack: return "Back"
        case .mouseForward: return "Forward"
        case .middleClick: return "Middle click"
        }
    }

    static let menu: [ButtonAction] = [.standard] + (1...12).map { .fKey($0) } + [.mouseBack, .mouseForward, .middleClick, .disabled]

    /// macOS virtual key codes for F1–F12 (kVK_F1…).
    static let fKeyCodes: [Int: CGKeyCode] = [1: 122, 2: 120, 3: 99, 4: 118, 5: 96, 6: 97,
                                              7: 98, 8: 100, 9: 101, 10: 109, 11: 103, 12: 111]
}

@MainActor
final class ButtonRemapper: ObservableObject {
    static let shared = ButtonRemapper()

    /// Per mouse (product id) mapping, saved in UserDefaults.
    @Published private(set) var mappings: [UInt16: [MouseButtonID: ButtonAction]] = [:]
    /// Last button pressed, for the "press a button to find it" highlight.
    @Published var lastPressed: MouseButtonID? { didSet { if let b = lastPressed { seen.insert(b) } } }
    /// Buttons that have actually been pressed (shows rows for buttons a model list might miss).
    @Published private(set) var seen: Set<MouseButtonID> = []
    @Published private(set) var inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    /// Called when a special button with action `.standard` is pressed/released in driver mode,
    /// so the app can emulate what the firmware would have done (DPI cycle, sniper hold, ...).
    var standardHandler: ((MouseButtonID, Bool) -> Void)?

    private var tap: CFMachPort?
    private var hid: IOHIDManager?
    private var connectedPIDs: Set<UInt16> = []
    private var heldRep4: Set<UInt8> = []
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: "buttonMappings"),
           let decoded = try? JSONDecoder().decode([String: [MouseButtonID: ButtonAction]].self, from: data) {
            for (k, v) in decoded { if let pid = UInt16(k, radix: 16) { mappings[pid] = v } }
        }
    }

    func action(_ pid: UInt16, _ b: MouseButtonID) -> ButtonAction { mappings[pid]?[b] ?? .standard }

    func setAction(_ pid: UInt16, _ b: MouseButtonID, _ a: ButtonAction) {
        var m = mappings[pid] ?? [:]
        if a == .standard { m[b] = nil } else { m[b] = a }
        mappings[pid] = m
        let encoded = Dictionary(uniqueKeysWithValues: mappings.map { (String(format: "%04X", $0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { UserDefaults.standard.set(data, forKey: "buttonMappings") }
        if b.mouseButtonNumber != nil && a != .standard { requestAccessibilityIfNeeded() }
        if b.needsDriverMode && a != .standard { requestInputMonitoringIfNeeded() }
        sync()
    }

    /// True when this mouse should be in driver mode (some special button is remapped).
    func wantsDriverMode(_ pid: UInt16) -> Bool {
        (mappings[pid] ?? [:]).contains { $0.key.needsDriverMode && $0.value != .standard }
    }

    func setConnected(_ pids: Set<UInt16>) {
        connectedPIDs = pids
        sync()
    }

    // MARK: permissions

    func requestAccessibilityIfNeeded() {
        accessibilityGranted = AXIsProcessTrusted()
        guard !accessibilityGranted else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
    }

    func requestInputMonitoringIfNeeded() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        sync()
    }

    // MARK: wiring

    /// Mapping in force for a button: the first connected mouse that remaps it.
    private func activeAction(_ b: MouseButtonID) -> ButtonAction {
        for pid in connectedPIDs.sorted() { if let a = mappings[pid]?[b] { return a } }
        return .standard
    }

    private func sync() {
        RemapFlags.actions = Dictionary(uniqueKeysWithValues: MouseButtonID.allCases.compactMap { b in
            b.mouseButtonNumber.map { ($0, activeAction(b)) }
        })
        let needTap = RemapFlags.actions.values.contains { $0 != .standard }
        if needTap, tap == nil, AXIsProcessTrusted() { installTap() }
        RemapFlags.enabled = needTap

        let needHID = connectedPIDs.contains { wantsDriverMode($0) }
        if needHID, hid == nil { startHID() }
        if !needHID, let h = hid { IOHIDManagerClose(h, IOOptionBits(kIOHIDOptionsTypeNone)); hid = nil }
    }

    private func installTap() {
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: remapTapCallback, userInfo: nil) else { return }
        RemapFlags.tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
    }

    // MARK: special buttons (driver mode, keyboard interface)

    private func startHID() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: 0x1532, kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x06]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<ButtonRemapper>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.attach(device) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        hid = mgr
    }

    private func attach(_ device: IOHIDDevice) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        reportBuffers.append(buf)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, 64, { ctx, _, _, _, reportID, report, length in
            guard let ctx else { return }
            let me = Unmanaged<ButtonRemapper>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            MainActor.assumeIsolated { me.handleReport(reportID: UInt8(truncatingIfNeeded: reportID), bytes) }
        }, ctx)
    }

    /// Report 4: [0x04, code, code, ...] listing every special button currently held.
    func handleReport(reportID: UInt8, _ bytes: [UInt8]) {
        var codes = bytes
        if reportID == 0x04, codes.first == 0x04 { codes.removeFirst() }
        else if reportID == 0x04 { /* id not included */ }
        else if codes.first == 0x04 { codes.removeFirst() }
        else { return }
        let now = Set(codes.filter { $0 != 0 })
        for c in now.subtracting(heldRep4) { special(c, down: true) }
        for c in heldRep4.subtracting(now) { special(c, down: false) }
        heldRep4 = now
    }

    private func special(_ code: UInt8, down: Bool) {
        guard let b = MouseButtonID.fromRep4(code) else { return }
        if down { lastPressed = b }
        let a = activeAction(b)
        if a == .standard { standardHandler?(b, down) } else { perform(a, down: down) }
    }
}

/// Globals read by the event-tap callback.
enum RemapFlags {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var actions: [Int64: ButtonAction] = [:]
    nonisolated(unsafe) static var tap: CFMachPort?
    static let synthetic: Int64 = 0x4E414741   // "NAGA": marks events we post so we never remap our own output
}

/// Sends the action's key or mouse button, down or up.
func perform(_ a: ButtonAction, down: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    switch a {
    case .fKey(let n):
        guard let code = ButtonAction.fKeyCodes[n],
              let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        e.flags = .maskSecondaryFn      // real F-key presses carry the fn flag
        e.setIntegerValueField(.eventSourceUserData, value: RemapFlags.synthetic)
        e.post(tap: .cghidEventTap)
    case .mouseBack, .mouseForward, .middleClick:
        let button: Int64 = a == .middleClick ? 2 : a == .mouseBack ? 3 : 4
        let loc = CGEvent(source: nil)?.location ?? .zero
        guard let e = CGEvent(mouseEventSource: src, mouseType: down ? .otherMouseDown : .otherMouseUp,
                              mouseCursorPosition: loc, mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center) else { return }
        e.setIntegerValueField(.mouseEventButtonNumber, value: button)
        e.setIntegerValueField(.eventSourceUserData, value: RemapFlags.synthetic)
        e.post(tap: .cghidEventTap)
    case .standard, .disabled:
        break
    }
}

private func remapTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = RemapFlags.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard RemapFlags.enabled,
          event.getIntegerValueField(.eventSourceUserData) != RemapFlags.synthetic else {
        return Unmanaged.passUnretained(event)
    }
    let button = event.getIntegerValueField(.mouseEventButtonNumber)
    if type != .otherMouseDragged, let id = MouseButtonID.allCases.first(where: { $0.mouseButtonNumber == button }) {
        DispatchQueue.main.async { MainActor.assumeIsolated { ButtonRemapper.shared.lastPressed = id } }
    }
    guard let a = RemapFlags.actions[button], a != .standard else { return Unmanaged.passUnretained(event) }
    if type == .otherMouseDragged { return nil }
    perform(a, down: type == .otherMouseDown)
    return nil   // swallow the original button
}
