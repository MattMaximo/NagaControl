// Packet-encoding selftest. No device I/O: it only builds reports and compares bytes.
// Expected bytes come from OpenRazer (driver/razerchromacommon.c).
// Build + run: swiftc -swift-version 5 Sources/App/RazerProtocol.swift Tests/main.swift -o build/selftest && build/selftest
// Prints "ALL PASS" and exits 0 only when every check passed; otherwise exits 1.
import Foundation

var fails = 0

func hex(_ r: RazerReport) -> String {
  r.bytes.prefix(17).map { String(format: "%02X", $0) }.joined(separator: " ") + " … crc=" + String(format: "%02X", r.bytes[88])
}

/// Checks the leading bytes, the CRC byte and the total length of a report.
func check(_ name: String, _ r: RazerReport, _ expectPrefix: [UInt8], _ crc: UInt8) {
  let ok = Array(r.bytes.prefix(expectPrefix.count)) == expectPrefix && r.bytes[88] == crc && r.bytes.count == 90
  print(ok ? "PASS" : "FAIL", name, hex(r)); if !ok { fails += 1 }
}

func expect<T: Equatable>(_ name: String, _ got: T, _ want: T) {
  let ok = got == want
  print(ok ? "PASS" : "FAIL", name, ok ? "" : "got \(got), want \(want)"); if !ok { fails += 1 }
}

// Legacy commands (Naga Epic / Epic Chroma / 2014)
check("setDPI 1600", Cmd.setDPI(1600,1600), [0x00,0xFF,0,0,0,0x07,0x04,0x05,0x01,0x06,0x40,0x06,0x40,0,0], 0x07)
check("getDPI", Cmd.getDPI(), [0x00,0xFF,0,0,0,0x07,0x04,0x85,0x00], 0x07^0x04^0x85)
check("setPoll 1000", Cmd.setPoll(1000), [0,0xFF,0,0,0,0x01,0x00,0x05,0x01], 0x01^0x05^0x01)
check("battery", Cmd.battery(), [0,0xFF,0,0,0,0x02,0x07,0x80], 0x02^0x07^0x80)
check("led rgb", Cmd.setLEDRGB(.scrollWheel,0xFF,0,0x10), [0,0x3F,0,0,0,0x05,0x03,0x01,0x01,0x01,0xFF,0x00,0x10], 0x05^0x03^0x01^0x01^0x01^0xFF^0x10)
check("dpi byte 3375", Cmd.setDPIByte(3375,6750), [0,0xFF,0,0,0,0x03,0x04,0x01,128,255,0], 0x03^0x04^0x01^128^255)
expect("byteToDPI 255", Cmd.byteToDPI(255), 6750)
expect("dpiToByte 800", Cmd.dpiToByte(800), 30)

// Extended commands (Basilisk V3)
check("x static logo", Cmd.xStatic(.logo,1,2,3).withTransactionID(0x1F), [0,0x1F,0,0,0,0x09,0x0F,0x02,0x01,0x04,0x01,0,0,0x01,1,2,3], 0x09^0x0F^0x02^0x01^0x04^0x01^0x01^1^2^3)
check("x spectrum all", Cmd.xSpectrum(.all).withTransactionID(0x1F), [0,0x1F,0,0,0,0x06,0x0F,0x02,0x01,0x00,0x03], 0x06^0x0F^0x02^0x01^0x03)
check("x bright", Cmd.xBrightness(.scrollWheel, 0x80), [0,0xFF,0,0,0,0x03,0x0F,0x04,0x01,0x01,0x80], 0x03^0x0F^0x04^0x01^0x01^0x80)
check("free spin", Cmd.setScrollMode(freeSpin: true), [0,0xFF,0,0,0,0x02,0x02,0x14,0x01,0x01], 0x02^0x02^0x14^0x01^0x01)
check("smart reel get", Cmd.getSmartReel(), [0,0xFF,0,0,0,0x02,0x02,0x97,0x01], 0x02^0x02^0x97^0x01)

print(fails == 0 ? "ALL PASS" : "\(fails) FAIL")
exit(fails == 0 ? 0 : 1)
