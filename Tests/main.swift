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

// Reply handling
func reply(_ status: UInt8, like r: RazerReport, args: [UInt8] = []) -> RazerReport {
  var b = r.bytes; b[0] = status
  for (i, a) in args.enumerated() { b[8 + i] = a }
  return RazerReport(raw: b)
}
let empty = RazerReport(raw: [UInt8](repeating: 0, count: 90))
let setReq = Cmd.setDPIByte(800, 800), getReq = Cmd.getDPIByte()
expect("isWrite set", setReq.isWrite, true)
expect("isWrite get", getReq.isWrite, false)
expect("reply ok", setReq.classify(reply: reply(2, like: setReq), allowEmptyAck: false), .ok)
expect("reply busy", setReq.classify(reply: reply(1, like: setReq), allowEmptyAck: false), .busy)
expect("reply failure", setReq.classify(reply: reply(3, like: setReq), allowEmptyAck: true), .failed(3))
expect("reply not supported", getReq.classify(reply: reply(5, like: getReq), allowEmptyAck: true), .failed(5))
expect("reply to another command", getReq.classify(reply: reply(2, like: setReq), allowEmptyAck: true), .mismatch)
expect("empty ack, legacy write", setReq.classify(reply: empty, allowEmptyAck: true), .emptyAck)
expect("empty reply, legacy read", getReq.classify(reply: empty, allowEmptyAck: true), .mismatch)
expect("empty reply, modern write", Cmd.setDPI(800, 800).classify(reply: empty, allowEmptyAck: false), .mismatch)
expect("Naga Epic takes empty ack", MouseModel.forPID(0x001F)!.acceptsEmptyWriteAck, true)
expect("Basilisk V3 refuses empty ack", MouseModel.forPID(0x0099)!.acceptsEmptyWriteAck, false)
expect("unknown device refuses empty ack", MouseModel.generic("").acceptsEmptyWriteAck, false)

// Reply parsing
let dpiReply = reply(2, like: Cmd.getDPI(), args: [0, 0x65, 0x90, 0x06, 0x40])
expect("parse dpi x", dpiReply.dpi.x, 26000)
expect("parse dpi y", dpiReply.dpi.y, 1600)
let byteReply = reply(2, like: getReq, args: [30, 255])
expect("parse byte dpi x", byteReply.dpiFromBytes.x, 794)
expect("parse byte dpi y", byteReply.dpiFromBytes.y, 6750)
expect("parse poll 1000", reply(2, like: Cmd.getPoll(), args: [1]).pollRate, 1000)
expect("parse poll 125", reply(2, like: Cmd.getPoll(), args: [8]).pollRate, 125)
expect("parse poll unknown", reply(2, like: Cmd.getPoll(), args: [0x40]).pollRate, nil)
expect("parse battery full", reply(2, like: Cmd.battery(), args: [0, 255]).batteryPercent, 100)
expect("parse battery half", reply(2, like: Cmd.battery(), args: [0, 128]).batteryPercent, 50)
expect("parse charging", reply(2, like: Cmd.charging(), args: [0, 1]).isCharging, true)
expect("parse idle 300 s", reply(2, like: Cmd.getIdle(), args: [0x01, 0x2C]).idleSeconds, 300)
expect("parse firmware", reply(2, like: Cmd.firmware(), args: [1, 4]).firmwareVersion, "v1.4")
check("setIdle clamps to 900 s", Cmd.setIdle(5000), [0,0xFF,0,0,0,0x02,0x07,0x03,0x03,0x84], 0x02^0x07^0x03^0x03^0x84)

// Models: transaction id and interface per OpenRazer razer_get_report / razermouse_driver.c
let bv3 = MouseModel.forPID(0x0099)!
expect("Basilisk V3 transaction id", bv3.transactionID, 0x1F)
expect("Basilisk V3 interface", bv3.usbIndex, 3)
expect("Basilisk V3 family", bv3.family, .extended)
expect("Naga Epic keeps per-command transaction ids", MouseModel.forPID(0x001F)!.transactionID, nil)
check("x breath scroll", Cmd.xBreath(.scrollWheel,9,8,7).withTransactionID(0x1F), [0,0x1F,0,0,0,0x09,0x0F,0x02,0x01,0x01,0x02,0x01,0,0x01,9,8,7], 0x09^0x0F^0x02^0x01^0x01^0x02^0x01^0x01^9^8^7)
check("x off logo", Cmd.xOff(.logo).withTransactionID(0x1F), [0,0x1F,0,0,0,0x06,0x0F,0x02,0x01,0x04,0x00], 0x06^0x0F^0x02^0x01^0x04)
check("x get brightness", Cmd.xGetBrightness(.all).withTransactionID(0x1F), [0,0x1F,0,0,0,0x03,0x0F,0x84,0x01,0x00], 0x03^0x0F^0x84^0x01)
check("setDPI 26000 x 1600", Cmd.setDPI(26000,1600).withTransactionID(0x1F), [0,0x1F,0,0,0,0x07,0x04,0x05,0x01,0x65,0x90,0x06,0x40,0,0], 0x07^0x04^0x05^0x01^0x65^0x90^0x06^0x40)

print(fails == 0 ? "ALL PASS" : "\(fails) FAIL")
exit(fails == 0 ? 0 : 1)
