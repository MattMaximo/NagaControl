import SwiftUI
import AppKit

let razerGreen = Color(red: 0.27, green: 0.84, blue: 0.17)

@main
struct NagaControlApp: App {
    @StateObject private var mouse = MouseController()
    @StateObject private var scroll = ScrollInverter.shared

    var body: some Scene {
        WindowGroup("Naga Control") {
            ContentView().environmentObject(mouse).environmentObject(scroll)
                .frame(minWidth: 460, idealWidth: 480, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuDPI().environmentObject(mouse).environmentObject(scroll)
        } label: {
            Image(systemName: "computermouse.fill")
        }
    }
}

struct MenuDPI: View {
    @EnvironmentObject var mouse: MouseController
    @EnvironmentObject var scroll: ScrollInverter
    var body: some View {
        if let d = mouse.selected {
            Text("\(d.model.name) — \(mouse.dpiX) DPI")
            if let b = mouse.battery { Text("Battery \(b)%\(mouse.charging ? " (charging)" : "")") }
            Divider()
            ForEach(presets(max: d.model.maxDPI), id: \.self) { p in
                Button("\(p) DPI\(p == mouse.dpiX ? "  ✓" : "")") {
                    mouse.dpiX = p; mouse.dpiY = p; mouse.linkXY = true; mouse.applyDPI(debounce: false)
                }
            }
        } else {
            Text("No Razer mouse found")
        }
        Divider()
        Toggle("Reverse mouse wheel", isOn: $scroll.reverseVertical)
        Button("Rescan") { mouse.rescan() }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

func presets(max: Int) -> [Int] {
    (max > 10000 ? [400, 800, 1600, 3200, 6400, 12000, 16000, 26000] : [400, 800, 1200, 1600, 2400, 3200, 4800, 6400, 8200])
        .filter { $0 <= max }
}

struct ContentView: View {
    @EnvironmentObject var mouse: MouseController
    @EnvironmentObject var scroll: ScrollInverter

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(razerGreen.opacity(0.4))
            if let dev = mouse.selected {
                ScrollView {
                    VStack(spacing: 14) {
                        performance(dev.model)
                        scrolling(dev.model)
                        lighting(dev.model)
                        if dev.model.wireless { power }
                        appSettings
                        if !dev.known { unknownNote(dev) }
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .background(Color(white: 0.08))
        .tint(razerGreen)
    }

    // MARK: header
    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "computermouse.fill").font(.system(size: 26)).foregroundStyle(razerGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(mouse.selected?.model.name ?? "No mouse").font(.headline)
                HStack(spacing: 8) {
                    if !mouse.firmware.isEmpty { Text("Firmware \(mouse.firmware)") }
                    if !mouse.transportPath.isEmpty { Text("· \(mouse.transportPath)") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let b = mouse.battery {
                HStack(spacing: 4) {
                    Image(systemName: mouse.charging ? "battery.100.bolt" : batteryIcon(b))
                        .foregroundStyle(b < 20 && !mouse.charging ? .red : razerGreen)
                    Text("\(b)%").monospacedDigit()
                }
            }
            if mouse.devices.count > 1 {
                Menu {
                    ForEach(mouse.devices) { d in Button(d.model.name) { mouse.select(d) } }
                } label: { Image(systemName: "chevron.down.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Button { mouse.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Rescan / re-read the mouse")
        }
        .padding(14)
    }

    func batteryIcon(_ b: Int) -> String {
        b > 85 ? "battery.100" : b > 60 ? "battery.75" : b > 35 ? "battery.50" : b > 10 ? "battery.25" : "battery.0"
    }

    // MARK: performance
    func performance(_ m: MouseModel) -> some View {
        Card(title: "Sensitivity", icon: "scope") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(mouse.dpiX)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(razerGreen)
                Text(mouse.linkXY ? "DPI" : "DPI X").foregroundStyle(.secondary)
                Spacer()
                Toggle("Separate X / Y", isOn: $mouse.linkXY.inverted).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: mouse.linkXY) { _, linked in if linked { mouse.dpiY = mouse.dpiX; mouse.applyDPI() } }
            }
            dpiSlider(value: $mouse.dpiX, max: m.maxDPI, step: m.byteDPI ? 50 : 50)
            if !mouse.linkXY {
                HStack {
                    Text("Y").foregroundStyle(.secondary).frame(width: 14)
                    dpiSlider(value: $mouse.dpiY, max: m.maxDPI, step: 50)
                    Text("\(mouse.dpiY)").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                ForEach(presets(max: m.maxDPI), id: \.self) { p in
                    Button(String(p)) {
                        mouse.dpiX = p; if mouse.linkXY { mouse.dpiY = p }; mouse.applyDPI(debounce: false)
                    }
                    .buttonStyle(Chip(active: mouse.dpiX == p))
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Polling rate")
                Spacer()
                Picker("", selection: Binding(get: { mouse.pollRate }, set: { mouse.applyPoll($0) })) {
                    Text("125 Hz").tag(125); Text("500 Hz").tag(500); Text("1000 Hz").tag(1000)
                }.pickerStyle(.segmented).frame(width: 240)
            }
        }
    }

    func dpiSlider(value: Binding<Int>, max: Int, step: Int) -> some View {
        Slider(value: Binding(get: { Double(value.wrappedValue) },
                              set: { value.wrappedValue = Int(($0 / Double(step)).rounded()) * step }),
               in: 100...Double(max)) { editing in
            if !editing { mouse.applyDPI(debounce: false) }
        }
    }

    // MARK: scrolling
    func scrolling(_ m: MouseModel) -> some View {
        Card(title: "Scrolling", icon: "arrow.up.arrow.down") {
            SwitchRow(title: "Reverse scroll wheel", subtitle: "Mouse wheels only. Trackpad keeps its own setting.",
                      isOn: $scroll.reverseVertical)
            SwitchRow(title: "Reverse horizontal scroll", subtitle: "Wheel tilt left/right", isOn: $scroll.reverseHorizontal)
            if (scroll.reverseVertical || scroll.reverseHorizontal) && !scroll.trusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs Accessibility permission to flip scrolling.").font(.caption)
                    Spacer()
                    Button("Grant access") { scroll.requestAccess() }.controlSize(.small)
                }
            }
            if m.scrollControls {
                Divider().padding(.vertical, 2)
                SwitchRow(title: "Free-spin wheel", subtitle: "Off = tactile clicks",
                          isOn: Binding(get: { mouse.freeSpin }, set: { mouse.applyFreeSpin($0) }))
                SwitchRow(title: "Smart Reel", subtitle: "Free-spins automatically when you flick the wheel",
                          isOn: Binding(get: { mouse.smartReel }, set: { mouse.applySmartReel($0) }))
                SwitchRow(title: "Scroll acceleration",
                          isOn: Binding(get: { mouse.scrollAccel }, set: { mouse.applyScrollAccel($0) }))
            }
        }
    }

    var appSettings: some View {
        Card(title: "App", icon: "gearshape") {
            SwitchRow(title: "Open at login", isOn: Binding(get: { scroll.openAtLogin }, set: { scroll.setOpenAtLogin($0) }))
            Text("Mouse settings are saved on the mouse itself. The app only needs to run for reversed scrolling.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: lighting
    func lighting(_ m: MouseModel) -> some View {
        Card(title: "Lighting", icon: "lightbulb.max") {
            ForEach(m.zones) { z in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(z.label).font(.subheadline.weight(.medium))
                        Spacer()
                        if m.rgb && [LightEffect.staticColor, .breathing].contains(mouse.effects[z] ?? .staticColor) {
                            ColorPicker("", selection: Binding(get: { mouse.colors[z] ?? razerGreen },
                                                               set: { mouse.colors[z] = $0; mouse.applyLightingSoon(z) }),
                                        supportsOpacity: false).labelsHidden()
                        }
                        Picker("", selection: Binding(get: { mouse.effects[z] ?? .staticColor },
                                                      set: { mouse.effects[z] = $0; mouse.applyLighting(z) })) {
                            ForEach(effects(for: m)) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 120)
                    }
                    HStack {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { mouse.brightness[z] ?? 100 }, set: { mouse.brightness[z] = $0 }),
                               in: 0...100) { editing in if !editing { mouse.applyBrightness(z) } }
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                }
                if z != m.zones.last { Divider() }
            }
        }
    }

    func effects(for m: MouseModel) -> [LightEffect] {
        m.rgb ? LightEffect.allCases : [.staticColor, .breathing, .off]
    }

    // MARK: power
    var power: some View {
        Card(title: "Wireless", icon: "antenna.radiowaves.left.and.right") {
            HStack {
                Text("Sleep after idle")
                Spacer()
                Picker("", selection: Binding(get: { mouse.idleMinutes }, set: { mouse.applyIdle($0) })) {
                    ForEach([1, 2, 3, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden().frame(width: 110)
            }
            if mouse.battery == nil {
                Text("Battery isn't reported right now (mouse may be asleep — move it, then hit refresh).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func unknownNote(_ d: FoundDevice) -> some View {
        Text(String(format: "This Razer device (1532:%04X) isn't in the known list, so settings are best-effort.", d.pid))
            .font(.caption).foregroundStyle(.orange)
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cable.connector").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No Razer mouse found").font(.title3)
            Text("Plug the Naga in with its USB cable, or plug in the charging dock.\nUSB-C adapters/hubs are fine.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Rescan") { mouse.rescan() }.buttonStyle(.borderedProminent)
            Spacer()
            scrolling(MouseModel.generic("")).padding(16)
        }.frame(maxWidth: .infinity)
    }

    // MARK: footer
    @State private var showLog = false
    var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Circle().fill(mouse.statusIsError ? Color.orange : razerGreen).frame(width: 7, height: 7)
                Text(mouse.status).font(.caption).lineLimit(2)
                Spacer()
                Button(showLog ? "Hide log" : "Log") { showLog.toggle() }.buttonStyle(.borderless).font(.caption)
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mouse.diagnostics(), forType: .string)
                }.buttonStyle(.borderless).font(.caption)
            }
            if showLog {
                ScrollView {
                    Text(mouse.log.suffix(80).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(height: 120)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct Card<Content: View>: View {
    let title: String, icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).textCase(.uppercase)
                .foregroundStyle(razerGreen)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
    }
}

/// Label on the left, switch pinned to the right edge.
struct SwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

struct Chip: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.monospacedDigit())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(active ? razerGreen : Color(white: 0.2)))
            .foregroundStyle(active ? .black : .primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension Binding where Value == Bool {
    var inverted: Binding<Bool> { Binding(get: { !wrappedValue }, set: { wrappedValue = !$0 }) }
}
