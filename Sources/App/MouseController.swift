import Foundation
import SwiftUI

struct FoundDevice: Identifiable, Hashable {
    let pid: UInt16
    let location: UInt32
    let product: String
    var id: String { "\(pid)-\(location)" }
    var model: MouseModel { MouseModel.forPID(pid) ?? .generic(product) }
    var known: Bool { MouseModel.forPID(pid) != nil }
}

enum TransportError: Error, LocalizedError {
    case io(Int32), status(UInt8), mismatch
    var errorDescription: String? {
        switch self {
        case .io(let c): return String(format: "USB error 0x%08X", UInt32(bitPattern: c))
        case .status(let s):
            switch RazerStatus(rawValue: s) {
            case .failure: return "Mouse rejected the command"
            case .timeout: return "Mouse didn't answer (asleep or out of range?)"
            case .notSupported: return "Not supported by this mouse"
            default: return "Unexpected status \(s)"
            }
        case .mismatch: return "Garbled reply"
        }
    }
}

@MainActor
final class MouseController: ObservableObject {
    // Discovery
    @Published var devices: [FoundDevice] = []
    @Published var selected: FoundDevice?
    @Published var transportPath = ""

    // State
    @Published var firmware = ""
    @Published var battery: Int?
    @Published var charging = false
    @Published var dpiX = 800
    @Published var dpiY = 800
    @Published var linkXY = true
    @Published var pollRate = 500
    @Published var idleMinutes = 5
    @Published var effects: [LEDZone: LightEffect] = [:]
    @Published var colors: [LEDZone: Color] = [:]
    @Published var brightness: [LEDZone: Double] = [:]
    @Published var freeSpin = false
    @Published var scrollAccel = false
    @Published var smartReel = false

    @Published var status = "Looking for your mouse…"
    @Published var statusIsError = false
    @Published var log: [String] = []

    private let queue = DispatchQueue(label: "naga.usb")
    private var pollTimer: Timer?
    private var dpiWork: DispatchWorkItem?

    init() {
        refreshDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var tickCount = 0
    private func tick() {
        tickCount += 1
        let before = devices.map(\.id)
        let now = Self.scan()
        if !now.isEmpty || devices.contains(where: { $0.location != 0 }), now.map(\.id) != before { refreshDevices() }
        else if selected != nil, tickCount % 10 == 0 { readBattery() }
    }

    static func scan() -> [FoundDevice] {
        var buf = [rz_device_info](repeating: rz_device_info(), count: Int(RZ_MAX_DEVICES))
        let n = Int(rz_list_devices(&buf, Int32(RZ_MAX_DEVICES)))
        return (0..<n).map { i in
            var d = buf[i]
            let name = withUnsafePointer(to: &d.product) {
                $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
            }
            return FoundDevice(pid: d.productID, location: d.locationID, product: name)
        }
    }

    func refreshDevices() {
        var found = Self.scan()
        if ProcessInfo.processInfo.environment["NAGA_DEMO"] != nil, found.isEmpty {
            found = [FoundDevice(pid: UInt16(ProcessInfo.processInfo.environment["NAGA_DEMO"] ?? "", radix: 16) ?? 0x003E, location: 0, product: "Demo")]   // UI preview only
        }
        devices = found
        log("Scan: " + (found.isEmpty ? "no Razer USB devices" :
            found.map { String(format: "%@ [1532:%04X]", $0.product, $0.pid) }.joined(separator: ", ")))
        // Prefer a known Naga; otherwise any Razer device.
        if let cur = selected, found.contains(cur) { return }
        selected = found.first(where: { $0.known }) ?? found.first
        if selected != nil { readAll() } else {
            setStatus("No Razer mouse found. Plug in the cable or the dock.", error: true)
        }
    }

    func select(_ d: FoundDevice) { selected = d; readAll() }

    // MARK: transport

    nonisolated private static func send(_ dev: FoundDevice, _ req0: RazerReport) throws -> (RazerReport, Int32) {
        let model = dev.model
        let req = req0.withTransactionID(model.transactionID)
        var lastErr: Error = TransportError.mismatch
        for attempt in 0..<4 {
            var out = [UInt8](repeating: 0, count: 90)
            var path: Int32 = 0
            let wait: UInt32 = attempt == 0 ? 1500 : 8000
            let r = req.bytes.withUnsafeBufferPointer { inb in
                out.withUnsafeMutableBufferPointer { outb in
                    rz_transfer(dev.location, dev.pid, model.usbIndex, inb.baseAddress, outb.baseAddress, wait, &path)
                }
            }
            if r != 0 { lastErr = TransportError.io(r); usleep(10_000); continue }
            let resp = RazerReport(raw: out)
            // The original Naga Epic answers some set commands (e.g. DPI) with an empty report while it
            // applies them. Don't resend; the caller confirms with a read-back.
            if req.cmd < 0x80, resp.status == 0, resp.cls == 0, resp.cmd == 0 { return (resp, path) }
            if resp.status == RazerStatus.busy.rawValue && attempt < 3 { usleep(15_000); continue }
            if resp.cls != req.cls || resp.cmd != req.cmd { lastErr = TransportError.mismatch; usleep(10_000); continue }
            if resp.status == RazerStatus.ok.rawValue || resp.status == RazerStatus.busy.rawValue { return (resp, path) }
            lastErr = TransportError.status(resp.status)
            if resp.status == RazerStatus.notSupported.rawValue { break }
            usleep(10_000)
        }
        throw lastErr
    }

    /// Runs a batch of commands off the main thread; returns results in order (nil = failed).
    private func run(_ reqs: [RazerReport], label: String, quiet: Bool = false,
                     done: @escaping ([RazerReport?], [String]) -> Void) {
        guard let dev = selected else { return }
        queue.async {
            var results: [RazerReport?] = []
            var errors: [String] = []
            var path: Int32 = 0
            for r in reqs {
                do { let (resp, p) = try Self.send(dev, r); results.append(resp); path = p }
                catch {
                    results.append(nil)
                    errors.append(String(format: "%02X/%02X: ", r.cls, r.cmd) + error.localizedDescription)
                }
            }
            DispatchQueue.main.async {
                if path == 1 { self.transportPath = "USB control" } else if path == 2 { self.transportPath = "HID feature" }
                for e in errors { self.log("\(label) – \(e)") }
                if !quiet {
                    if errors.isEmpty { self.setStatus(label, error: false) }
                    else if errors.count == reqs.count { self.setStatus("\(label) failed: \(errors[0].dropFirst(7))", error: true) }
                    else { self.setStatus("\(label) (some settings unavailable)", error: false) }
                }
                done(results, errors)
            }
        }
    }

    // MARK: reads

    func readAll() {
        guard let dev = selected else { return }
        let m = dev.model
        var reqs: [RazerReport] = [Cmd.firmware(), m.byteDPI ? Cmd.getDPIByte() : Cmd.getDPI(), Cmd.getPoll()]
        if m.wireless { reqs += [Cmd.battery(), Cmd.charging(), Cmd.getIdle()] }
        if m.family == .legacy {
            for z in m.zones { reqs += [Cmd.getBrightness(z), Cmd.getLEDState(z), Cmd.getLEDEffect(z), Cmd.getLEDRGB(z)] }
        } else {
            for z in m.zones { reqs.append(Cmd.xGetBrightness(z)) }
        }
        if m.scrollControls { reqs += [Cmd.getScrollMode(), Cmd.getScrollAccel(), Cmd.getSmartReel()] }
        run(reqs, label: "Connected to \(m.name)") { res, _ in
            var i = 0
            func next() -> RazerReport? { defer { i += 1 }; return res[i] }
            if let f = next() { self.firmware = "v\(f.arg(0)).\(f.arg(1))" }
            if let d = next() {
                if m.byteDPI { self.dpiX = Cmd.byteToDPI(d.arg(0)); self.dpiY = Cmd.byteToDPI(d.arg(1)) }
                else {
                    self.dpiX = Int(d.arg(1)) << 8 | Int(d.arg(2))
                    self.dpiY = Int(d.arg(3)) << 8 | Int(d.arg(4))
                }
                self.linkXY = self.dpiX == self.dpiY
            }
            if let p = next() { self.pollRate = [1: 1000, 2: 500, 8: 125][Int(p.arg(0))] ?? 500 }
            if m.wireless {
                if let b = next() { self.battery = Int((Double(b.arg(1)) / 255 * 100).rounded()) } else { self.battery = nil }
                if let c = next() { self.charging = c.arg(1) == 1 }
                if let t = next() { self.idleMinutes = max(1, (Int(t.arg(0)) << 8 | Int(t.arg(1))) / 60) }
            }
            if m.family == .extended {
                for z in m.zones {
                    if let b = next() { self.brightness[z] = Double(b.arg(2)) / 255 * 100 }
                    if self.effects[z] == nil { self.effects[z] = m.defaultEffect }
                    if self.colors[z] == nil { self.colors[z] = Color(red: 0.27, green: 0.84, blue: 0.17) }
                }
            } else {
            for z in m.zones {
                if let b = next() { self.brightness[z] = Double(b.arg(2)) / 255 * 100 }
                let st = next(), ef = next(), c = next()
                if let st, st.arg(2) == 0 { self.effects[z] = .off }
                else if let ef { self.effects[z] = [0: .staticColor, 2: .breathing, 4: .spectrum][Int(ef.arg(2))] ?? .staticColor }
                else if self.effects[z] == nil { self.effects[z] = .staticColor }
                if let c { self.colors[z] = Color(red: Double(c.arg(2)) / 255, green: Double(c.arg(3)) / 255, blue: Double(c.arg(4)) / 255) }
                else if self.colors[z] == nil { self.colors[z] = Color(red: 0.27, green: 0.84, blue: 0.17) }
            }
            }
            if m.scrollControls {
                if let r = next() { self.freeSpin = r.arg(1) == 1 }
                if let r = next() { self.scrollAccel = r.arg(1) == 1 }
                if let r = next() { self.smartReel = r.arg(1) == 1 }
            }
        }
    }

    func readBattery() {
        guard let m = selected?.model, m.wireless else { return }
        run([Cmd.battery(), Cmd.charging()], label: "Battery", quiet: true) { res, _ in
            if let b = res[0] { self.battery = Int((Double(b.arg(1)) / 255 * 100).rounded()) }
            if let c = res[1] { self.charging = c.arg(1) == 1 }
        }
    }

    // MARK: writes

    func applyDPI(debounce: Bool = true) {
        dpiWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let m = self.selected?.model else { return }
            let x = self.dpiX, y = self.linkXY ? self.dpiX : self.dpiY
            let req = m.byteDPI ? Cmd.setDPIByte(x, y) : Cmd.setDPI(x, y)
            let get = m.byteDPI ? Cmd.getDPIByte() : Cmd.getDPI()
            self.run([req, get], label: "DPI", quiet: true) { res, errs in
                guard let d = res[1] else {
                    self.setStatus("DPI change failed: \(errs.first ?? "no reply")", error: true); return
                }
                let rx = m.byteDPI ? Cmd.byteToDPI(d.arg(0)) : Int(d.arg(1)) << 8 | Int(d.arg(2))
                let ry = m.byteDPI ? Cmd.byteToDPI(d.arg(1)) : Int(d.arg(3)) << 8 | Int(d.arg(4))
                if abs(rx - x) <= 30 && abs(ry - y) <= 30 {
                    self.setStatus(self.linkXY ? "DPI set to \(x)" : "DPI set to \(x) × \(y)", error: false)
                } else {
                    self.setStatus("Mouse reports \(rx) DPI (asked for \(x))", error: true)
                }
                if abs(rx - x) > 30 || abs(ry - y) > 30 { self.dpiX = rx; self.dpiY = ry }
            }
        }
        dpiWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.25 : 0), execute: work)
    }

    func applyPoll(_ hz: Int) {
        pollRate = hz
        run([Cmd.setPoll(hz)], label: "Polling rate set to \(hz) Hz") { _, _ in }
    }

    func applyIdle(_ minutes: Int) {
        idleMinutes = minutes
        run([Cmd.setIdle(minutes * 60)], label: "Sleeps after \(minutes) min idle") { _, _ in }
    }

    func applyLighting(_ z: LEDZone) {
        guard let m = selected?.model else { return }
        let effect = effects[z] ?? .staticColor
        let (r, g, b) = rgb(colors[z] ?? .green)
        var reqs: [RazerReport] = []
        if m.family == .extended {
            switch effect {
            case .off: reqs = [Cmd.xOff(z)]
            case .staticColor: reqs = [Cmd.xStatic(z, r, g, b)]
            case .breathing: reqs = [Cmd.xBreath(z, r, g, b)]
            case .spectrum: reqs = [Cmd.xSpectrum(z)]
            }
            if z == .all { for other in m.zones where other != .all { effects[other] = effect; colors[other] = colors[z] } }
            run(reqs, label: "\(z.label): \(effect.rawValue)") { _, _ in }
            return
        }
        switch effect {
        case .off: reqs = [Cmd.setLEDState(z, on: false)]
        case .staticColor:
            reqs = [Cmd.setLEDState(z, on: true)]
            if m.rgb { reqs.append(Cmd.setLEDRGB(z, r, g, b)) }
            reqs.append(Cmd.setLEDEffect(z, 0x00))
        case .breathing:
            reqs = [Cmd.setLEDState(z, on: true)]
            if m.rgb { reqs.append(Cmd.setLEDRGB(z, r, g, b)) }
            reqs.append(Cmd.setLEDEffect(z, 0x02))
        case .spectrum:
            reqs = [Cmd.setLEDState(z, on: true), Cmd.setLEDEffect(z, 0x04)]
        }
        run(reqs, label: "\(z.label): \(effect.rawValue)") { _, _ in }
    }

    func applyBrightness(_ z: LEDZone) {
        let v = UInt8(clamping: Int(((brightness[z] ?? 100) / 100 * 255).rounded()))
        let req = selected?.model.family == .extended ? Cmd.xBrightness(z, v) : Cmd.setBrightness(z, v)
        if z == .all { for other in selected?.model.zones ?? [] { brightness[other] = brightness[z] } }
        run([req], label: "\(z.label) brightness \(Int(brightness[z] ?? 100))%") { _, _ in }
    }

    func applyFreeSpin(_ on: Bool) {
        freeSpin = on
        run([Cmd.setScrollMode(freeSpin: on)], label: on ? "Wheel: free spin" : "Wheel: tactile clicks") { _, _ in }
    }
    func applyScrollAccel(_ on: Bool) {
        scrollAccel = on
        run([Cmd.setScrollAccel(on)], label: "Scroll acceleration \(on ? "on" : "off")") { _, _ in }
    }
    func applySmartReel(_ on: Bool) {
        smartReel = on
        run([Cmd.setSmartReel(on)], label: "Smart Reel \(on ? "on" : "off")") { _, _ in }
    }

    private func rgb(_ c: Color) -> (UInt8, UInt8, UInt8) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .green
        func b(_ v: CGFloat) -> UInt8 { UInt8(clamping: Int((v * 255).rounded())) }
        return (b(ns.redComponent), b(ns.greenComponent), b(ns.blueComponent))
    }

    // MARK: misc

    private func setStatus(_ s: String, error: Bool) { status = s; statusIsError = error }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(s)"
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
        Self.appendLogFile(line)
    }

    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("NagaControl.log")
    }()

    static func appendLogFile(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: logURL) }
    }

    func diagnostics() -> String {
        var s = "NagaControl diagnostics\n"
        s += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        s += "Devices: " + devices.map { String(format: "%@ 1532:%04X loc %08X", $0.product, $0.pid, $0.location) }.joined(separator: "; ") + "\n"
        s += "Transport: \(transportPath)\nFirmware: \(firmware)\n\n" + log.suffix(60).joined(separator: "\n")
        return s
    }
}
