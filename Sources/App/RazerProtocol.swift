import Foundation

/// 90-byte Razer report (layout from OpenRazer's `struct razer_report`).
/// [0] status [1] transaction id [2..3] remaining packets [4] protocol
/// [5] data size [6] command class [7] command id [8..87] args [88] crc [89] reserved
struct RazerReport {
    var bytes = [UInt8](repeating: 0, count: 90)

    init(cls: UInt8, cmd: UInt8, size: UInt8, args: [UInt8] = [], tid: UInt8 = 0xFF) {
        bytes[1] = tid
        bytes[5] = size
        bytes[6] = cls
        bytes[7] = cmd
        for (i, a) in args.enumerated() where i < 80 { bytes[8 + i] = a }
        bytes[88] = RazerReport.crc(bytes)
    }

    init(raw: [UInt8]) { bytes = raw }

    func withTransactionID(_ tid: UInt8?) -> RazerReport {
        guard let tid else { return self }
        var r = self; r.bytes[1] = tid; r.bytes[88] = RazerReport.crc(r.bytes); return r
    }

    static func crc(_ b: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for i in 2..<88 { c ^= b[i] }
        return c
    }

    var status: UInt8 { bytes[0] }
    var cls: UInt8 { bytes[6] }
    var cmd: UInt8 { bytes[7] }
    func arg(_ i: Int) -> UInt8 { bytes[8 + i] }

    /// Set commands have bit 7 of the command id clear; get commands have it set.
    var isWrite: Bool { cmd & 0x80 == 0 }
}

enum RazerStatus: UInt8 {
    case busy = 1, ok = 2, failure = 3, timeout = 4, notSupported = 5
}

/// What a reply means for the request that produced it (rules from OpenRazer's razer_send_payload).
enum ReplyVerdict: Equatable {
    case ok                 // right command, status ok
    case busy               // right command, mouse still working; OpenRazer counts this as success
    case emptyAck           // no status/class/command at all; see `classify`
    case mismatch           // reply belongs to some other command
    case failed(UInt8)      // right command, status failure / timeout / not supported
}

extension RazerReport {
    /// `allowEmptyAck`: the original Naga Epic answers some writes (DPI) with an all-zero report
    /// while it applies them. Only accept that for a write, and only on models known to do it;
    /// anywhere else an empty reply means nothing answered (wrong interface, sleeping mouse).
    func classify(reply: RazerReport, allowEmptyAck: Bool) -> ReplyVerdict {
        if reply.status == 0, reply.cls == 0, reply.cmd == 0 {
            return allowEmptyAck && isWrite ? .emptyAck : .mismatch
        }
        if reply.cls != cls || reply.cmd != cmd { return .mismatch }
        switch RazerStatus(rawValue: reply.status) {
        case .ok: return .ok
        case .busy: return .busy
        default: return .failed(reply.status)
        }
    }

    // Reply parsing. Argument positions from OpenRazer's razermouse_driver.c read handlers.
    var firmwareVersion: String { "v\(arg(0)).\(arg(1))" }
    /// 04/85: [store, x hi, x lo, y hi, y lo]
    var dpi: (x: Int, y: Int) { (Int(arg(1)) << 8 | Int(arg(2)), Int(arg(3)) << 8 | Int(arg(4))) }
    /// 04/81 (original Naga Epic): [x, y], one byte each
    var dpiFromBytes: (x: Int, y: Int) { (Cmd.byteToDPI(arg(0)), Cmd.byteToDPI(arg(1))) }
    var pollRate: Int? { [1: 1000, 2: 500, 8: 125][Int(arg(0))] }
    /// 07/80: level 0...255 in the second argument
    var batteryPercent: Int { Int((Double(arg(1)) / 255 * 100).rounded()) }
    var isCharging: Bool { arg(1) == 1 }
    var idleSeconds: Int { Int(arg(0)) << 8 | Int(arg(1)) }
}

enum LEDZone: UInt8, CaseIterable, Identifiable {
    case all = 0x00, scrollWheel = 0x01, logo = 0x04, sidePanel = 0x05
    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .all: return "All lights"
        case .scrollWheel: return "Scroll wheel"
        case .logo: return "Logo"
        case .sidePanel: return "Side buttons"
        }
    }
}

enum LightEffect: String, CaseIterable, Identifiable {
    case staticColor = "Static", breathing = "Breathing", spectrum = "Spectrum", off = "Off"
    var id: String { rawValue }
}

/// Command family. `.legacy` = class 0x03 LED commands (2011-2016 mice);
/// `.extended` = class 0x0F matrix commands + scroll-wheel controls (2017+ mice like the Basilisk V3).
enum ProtocolFamily { case legacy, extended }

/// Per-model capabilities. Values from OpenRazer's daemon/hardware/mouse.py + razermouse_driver.c.
struct MouseModel {
    let name: String
    let maxDPI: Int
    let byteDPI: Bool          // original Naga Epic: 1 byte per axis, scaled over 0...6750
    let wireless: Bool
    let zones: [LEDZone]
    let rgb: Bool
    var family: ProtocolFamily = .legacy
    var transactionID: UInt8? = nil   // overrides every report's transaction id when set
    var usbIndex: UInt16 = 0          // USB interface the control transfer goes to (wIndex)
    var scrollControls = false        // free-spin / acceleration / smart reel
    var defaultEffect: LightEffect = .staticColor

    /// See `RazerReport.classify`. Seen live on the original Naga Epic; kept for its legacy siblings.
    var acceptsEmptyWriteAck: Bool { family == .legacy }

    static func forPID(_ pid: UInt16) -> MouseModel? {
        switch pid {
        case 0x003E: return MouseModel(name: "Naga Epic Chroma (wired)", maxDPI: 8200, byteDPI: false, wireless: true, zones: [.scrollWheel, .sidePanel], rgb: true)
        case 0x003F: return MouseModel(name: "Naga Epic Chroma (wireless dock)", maxDPI: 8200, byteDPI: false, wireless: true, zones: [.scrollWheel, .sidePanel], rgb: true)
        case 0x001F: return MouseModel(name: "Naga Epic", maxDPI: 5600, byteDPI: true, wireless: true, zones: [.scrollWheel], rgb: true)
        case 0x0040: return MouseModel(name: "Naga 2014", maxDPI: 8200, byteDPI: false, wireless: false, zones: [.scrollWheel, .sidePanel], rgb: false)
        case 0x0099: return MouseModel(name: "Basilisk V3", maxDPI: 26000, byteDPI: false, wireless: false,
                                       zones: [.all, .logo, .scrollWheel], rgb: true, family: .extended,
                                       transactionID: 0x1F, usbIndex: 3, scrollControls: true, defaultEffect: .spectrum)
        case 0x00CB: return MouseModel(name: "Basilisk V3 35K", maxDPI: 35000, byteDPI: false, wireless: false,
                                       zones: [.all, .logo, .scrollWheel], rgb: true, family: .extended,
                                       transactionID: 0x1F, usbIndex: 3, scrollControls: true, defaultEffect: .spectrum)
        default: return nil
        }
    }

    /// Unknown Razer mouse: best-effort with the modern command set.
    static func generic(_ product: String) -> MouseModel {
        MouseModel(name: product.isEmpty ? "Razer device" : product, maxDPI: 20000, byteDPI: false, wireless: false,
                   zones: [.all], rgb: true, family: .extended, transactionID: 0x1F)
    }
}

enum Cmd {
    static let VARSTORE: UInt8 = 0x01
    static let NOSTORE: UInt8 = 0x00

    static func firmware() -> RazerReport { .init(cls: 0x00, cmd: 0x81, size: 0x02) }
    static func battery() -> RazerReport { .init(cls: 0x07, cmd: 0x80, size: 0x02) }
    static func charging() -> RazerReport { .init(cls: 0x07, cmd: 0x84, size: 0x02) }
    static func getPoll() -> RazerReport { .init(cls: 0x00, cmd: 0x85, size: 0x01) }
    static func setPoll(_ hz: Int) -> RazerReport {
        let v: UInt8 = hz == 1000 ? 0x01 : hz == 125 ? 0x08 : 0x02
        return .init(cls: 0x00, cmd: 0x05, size: 0x01, args: [v])
    }
    static func getDPI() -> RazerReport { .init(cls: 0x04, cmd: 0x85, size: 0x07, args: [NOSTORE]) }
    static func setDPI(_ x: Int, _ y: Int) -> RazerReport {
        let x = UInt16(clamping: max(100, x)), y = UInt16(clamping: max(100, y))
        return .init(cls: 0x04, cmd: 0x05, size: 0x07,
                     args: [VARSTORE, UInt8(x >> 8), UInt8(x & 0xFF), UInt8(y >> 8), UInt8(y & 0xFF), 0, 0])
    }
    static func getDPIByte() -> RazerReport { .init(cls: 0x04, cmd: 0x81, size: 0x03) }
    static func setDPIByte(_ x: Int, _ y: Int) -> RazerReport {
        .init(cls: 0x04, cmd: 0x01, size: 0x03, args: [dpiToByte(x), dpiToByte(y), 0])
    }
    static func dpiToByte(_ d: Int) -> UInt8 { UInt8(clamping: Int((Double(min(max(d, 100), 6750)) / 6750 * 255).rounded())) }
    static func byteToDPI(_ b: UInt8) -> Int { Int((Double(b) / 255 * 6750).rounded()) }

    static func getBrightness(_ z: LEDZone) -> RazerReport { .init(cls: 0x03, cmd: 0x83, size: 0x03, args: [VARSTORE, z.rawValue]) }
    static func setBrightness(_ z: LEDZone, _ b: UInt8) -> RazerReport { .init(cls: 0x03, cmd: 0x03, size: 0x03, args: [VARSTORE, z.rawValue, b]) }
    static func setLEDState(_ z: LEDZone, on: Bool) -> RazerReport { .init(cls: 0x03, cmd: 0x00, size: 0x03, args: [VARSTORE, z.rawValue, on ? 1 : 0], tid: 0x3F) }
    static func setLEDRGB(_ z: LEDZone, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> RazerReport { .init(cls: 0x03, cmd: 0x01, size: 0x05, args: [VARSTORE, z.rawValue, r, g, b], tid: 0x3F) }
    static func setLEDEffect(_ z: LEDZone, _ e: UInt8) -> RazerReport { .init(cls: 0x03, cmd: 0x02, size: 0x03, args: [VARSTORE, z.rawValue, e], tid: 0x3F) }

    static func getLEDEffect(_ z: LEDZone) -> RazerReport { .init(cls: 0x03, cmd: 0x82, size: 0x03, args: [VARSTORE, z.rawValue]) }
    static func getLEDRGB(_ z: LEDZone) -> RazerReport { .init(cls: 0x03, cmd: 0x81, size: 0x05, args: [VARSTORE, z.rawValue]) }
    static func getLEDState(_ z: LEDZone) -> RazerReport { .init(cls: 0x03, cmd: 0x80, size: 0x03, args: [VARSTORE, z.rawValue]) }

    // Extended (class 0x0F) lighting, used by 2017+ mice. There is no read command for the
    // current effect (OpenRazer has none either), so the app can't show what the mouse is doing.
    static func xBrightness(_ z: LEDZone, _ b: UInt8) -> RazerReport { .init(cls: 0x0F, cmd: 0x04, size: 0x03, args: [VARSTORE, z.rawValue, b]) }
    static func xGetBrightness(_ z: LEDZone) -> RazerReport { .init(cls: 0x0F, cmd: 0x84, size: 0x03, args: [VARSTORE, z.rawValue]) }
    static func xStatic(_ z: LEDZone, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> RazerReport {
        .init(cls: 0x0F, cmd: 0x02, size: 0x09, args: [VARSTORE, z.rawValue, 0x01, 0, 0, 0x01, r, g, b])
    }
    static func xBreath(_ z: LEDZone, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> RazerReport {
        .init(cls: 0x0F, cmd: 0x02, size: 0x09, args: [VARSTORE, z.rawValue, 0x02, 0x01, 0, 0x01, r, g, b])
    }
    static func xSpectrum(_ z: LEDZone) -> RazerReport { .init(cls: 0x0F, cmd: 0x02, size: 0x06, args: [VARSTORE, z.rawValue, 0x03]) }
    static func xOff(_ z: LEDZone) -> RazerReport { .init(cls: 0x0F, cmd: 0x02, size: 0x06, args: [VARSTORE, z.rawValue, 0x00]) }

    // Scroll wheel (Basilisk V3 etc.): mode 0 = tactile, 1 = free spin.
    static func getScrollMode() -> RazerReport { .init(cls: 0x02, cmd: 0x94, size: 0x02, args: [VARSTORE]) }
    static func setScrollMode(freeSpin: Bool) -> RazerReport { .init(cls: 0x02, cmd: 0x14, size: 0x02, args: [VARSTORE, freeSpin ? 1 : 0]) }
    static func getScrollAccel() -> RazerReport { .init(cls: 0x02, cmd: 0x96, size: 0x02, args: [VARSTORE]) }
    static func setScrollAccel(_ on: Bool) -> RazerReport { .init(cls: 0x02, cmd: 0x16, size: 0x02, args: [VARSTORE, on ? 1 : 0]) }
    static func getSmartReel() -> RazerReport { .init(cls: 0x02, cmd: 0x97, size: 0x02, args: [VARSTORE]) }
    static func setSmartReel(_ on: Bool) -> RazerReport { .init(cls: 0x02, cmd: 0x17, size: 0x02, args: [VARSTORE, on ? 1 : 0]) }

    static func getIdle() -> RazerReport { .init(cls: 0x07, cmd: 0x83, size: 0x02) }
    static func setIdle(_ seconds: Int) -> RazerReport {
        let s = UInt16(min(max(seconds, 60), 900))
        return .init(cls: 0x07, cmd: 0x03, size: 0x02, args: [UInt8(s >> 8), UInt8(s & 0xFF)])
    }
}
