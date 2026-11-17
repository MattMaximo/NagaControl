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

    static func crc(_ b: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for i in 2..<88 { c ^= b[i] }
        return c
    }

    var status: UInt8 { bytes[0] }
    var cls: UInt8 { bytes[6] }
    var cmd: UInt8 { bytes[7] }
    func arg(_ i: Int) -> UInt8 { bytes[8 + i] }
}

enum RazerStatus: UInt8 {
    case busy = 1, ok = 2, failure = 3, timeout = 4, notSupported = 5
}

enum LEDZone: UInt8, CaseIterable, Identifiable {
    case scrollWheel = 0x01, logo = 0x04, sidePanel = 0x05
    var id: UInt8 { rawValue }
    var label: String {
        switch self {
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

/// Per-model capabilities. Values from OpenRazer's daemon/hardware/mouse.py + razermouse_driver.c.
struct MouseModel {
    let name: String
    let maxDPI: Int
    let byteDPI: Bool          // original Naga Epic: 1 byte per axis, scaled over 0...6750
    let wireless: Bool
    let zones: [LEDZone]
    let rgb: Bool              // Chroma models take an RGB color; the original Epic is green only

    static func forPID(_ pid: UInt16) -> MouseModel? {
        switch pid {
        case 0x003E: return MouseModel(name: "Naga Epic Chroma (wired)", maxDPI: 8200, byteDPI: false, wireless: true, zones: [.scrollWheel, .sidePanel], rgb: true)
        case 0x003F: return MouseModel(name: "Naga Epic Chroma (wireless dock)", maxDPI: 8200, byteDPI: false, wireless: true, zones: [.scrollWheel, .sidePanel], rgb: true)
        case 0x001F: return MouseModel(name: "Naga Epic", maxDPI: 5600, byteDPI: true, wireless: true, zones: [.scrollWheel], rgb: true)
        case 0x0040: return MouseModel(name: "Naga 2014", maxDPI: 8200, byteDPI: false, wireless: false, zones: [.scrollWheel, .sidePanel], rgb: false)
        default: return nil
        }
    }

    /// Unknown Razer mouse: try the common Chroma-era commands.
    static func generic(_ product: String) -> MouseModel {
        MouseModel(name: product.isEmpty ? "Razer device" : product, maxDPI: 8200, byteDPI: false, wireless: true, zones: [.scrollWheel, .sidePanel], rgb: true)
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

    static func getIdle() -> RazerReport { .init(cls: 0x07, cmd: 0x83, size: 0x02) }
    static func setIdle(_ seconds: Int) -> RazerReport {
        let s = UInt16(min(max(seconds, 60), 900))
        return .init(cls: 0x07, cmd: 0x03, size: 0x02, args: [UInt8(s >> 8), UInt8(s & 0xFF)])
    }
}
