import Foundation
var buf = [rz_device_info](repeating: rz_device_info(), count: 16)
_ = rz_list_devices(&buf, 16); let d = buf[0]
func tx(_ r: RazerReport) -> RazerReport { var out = [UInt8](repeating: 0, count: 90); var path: Int32 = 0
  _ = r.bytes.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in rz_transfer(d.locationID, d.productID, 0, i.baseAddress, o.baseAddress, 3000, &path) } }; return RazerReport(raw: out) }
_ = tx(Cmd.setDPIByte(2409, 2409)); usleep(80000)
let g = tx(Cmd.getDPIByte()); print("restored bytes", g.arg(0), g.arg(1), "=", Cmd.byteToDPI(g.arg(0)))
