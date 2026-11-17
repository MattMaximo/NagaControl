import Foundation
var buf = [rz_device_info](repeating: rz_device_info(), count: 16)
_ = rz_list_devices(&buf, 16); let d = buf[0]
var out = [UInt8](repeating: 0, count: 90); var path: Int32 = 0
_ = Cmd.getDPIByte().bytes.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in rz_transfer(d.locationID, d.productID, 0, i.baseAddress, o.baseAddress, 3000, &path) } }
print("mouse DPI now:", Cmd.byteToDPI(RazerReport(raw: out).arg(0)))
