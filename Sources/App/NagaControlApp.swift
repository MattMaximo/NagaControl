import SwiftUI
import AppKit

let razerGreen = MouseController.defaultColor

/// Light theme: white cards on a soft grey page, near-black text, Razer green for active state.
enum Theme {
    static let page = Color(red: 0.955, green: 0.957, blue: 0.962)
    static let card = Color.white
    static let cardBorder = Color.black.opacity(0.08)
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.08)        // headings, big numbers
    static let inkSoft = Color(red: 0.33, green: 0.34, blue: 0.36)    // section titles
    static let chipOff = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let greenText = Color(red: 0.13, green: 0.55, blue: 0.08)  // green that's readable as text on white
}

@main
struct NagaControlApp: App {
    @StateObject private var mouse = MouseController()
    @StateObject private var scroll = ScrollInverter.shared

    init() { Updater.shared.start() }

    var body: some Scene {
        // Menu-bar-only app (LSUIElement): clicking the icon opens the full control panel.
        MenuBarExtra {
            ContentView().environmentObject(mouse).environmentObject(scroll)
                .frame(width: 360)
                .preferredColorScheme(.light)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Template glyph from Resources/MenuBarIcon.png when bundled, else an SF Symbol.
struct MenuBarLabel: View {
    var body: some View {
        if let img = NSImage(named: "MenuBarIcon") {
            Image(nsImage: { img.isTemplate = true; img.size = NSSize(width: 18, height: 18); return img }())
        } else {
            Image(systemName: "computermouse.fill")
        }
    }
}

func presets(max: Int) -> [Int] {
    (max > 10000 ? [400, 800, 1600, 3200, 6400, 12000, 16000, 26000] : [400, 800, 1200, 1600, 2400, 3200, 4800, 6400, 8200])
        .filter { $0 <= max }
}

struct ContentView: View {
    @EnvironmentObject var mouse: MouseController
    @EnvironmentObject var scroll: ScrollInverter
    @ObservedObject var remap = ButtonRemapper.shared
    @ObservedObject var updater = Updater.shared
    @State private var showLog = false
    @State private var cardsHeight: CGFloat = 500

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Scrolls only when the panel would be taller than the screen (small laptops).
            ScrollView {
                cards.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .scrollIndicators(.automatic)
            .frame(height: min(cardsHeight, (NSScreen.main?.visibleFrame.height ?? 800) - 120))
            .onPreferenceChange(HeightKey.self) { cardsHeight = $0 }
            if showLog { logView }
            Divider()
            footer
        }
        .background(Theme.page)
        .tint(razerGreen)
        .controlSize(.small)
    }

    var cards: some View {
            VStack(spacing: 8) {
                if let dev = mouse.selected {
                    performance(dev.model)
                    scrolling(dev.model)
                    if !dev.model.buttons.isEmpty { buttons(dev) }
                    lighting(dev.model)
                    if dev.model.wireless { power }
                    if !dev.known { unknownNote(dev) }
                } else {
                    emptyState
                    scrolling(MouseModel.generic(""))
                }
            }
            .padding(10)
    }

    // MARK: header
    var header: some View {
        HStack(spacing: 8) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(mouse.selected?.model.name ?? "No mouse").font(.system(size: 13, weight: .semibold))
                if !mouse.firmware.isEmpty {
                    Text("Firmware \(mouse.firmware)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let b = mouse.battery {
                HStack(spacing: 3) {
                    Image(systemName: mouse.charging ? "battery.100.bolt" : batteryIcon(b))
                        .foregroundStyle(b < 20 && !mouse.charging ? .red : Theme.inkSoft)
                    Text("\(b)%").monospacedDigit()
                }.font(.system(size: 11))
            }
            if mouse.devices.count > 1 {
                Menu {
                    ForEach(mouse.devices) { d in Button(d.model.name) { mouse.select(d) } }
                } label: { Image(systemName: "chevron.up.chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Switch mouse")
            }
            if let v = updater.availableVersion {
                Button { Task { await updater.install() } } label: { Text("Update \(v)").padding(.horizontal, 6) }
                    .buttonStyle(Chip(active: true)).fixedSize()
                    .help("Install Naga Control \(v) and relaunch")
            } else if updater.state == .installing {
                ProgressView().controlSize(.mini)
            }
            Button { mouse.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).foregroundStyle(Theme.inkSoft).help("Re-read the mouse")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).foregroundStyle(Theme.inkSoft).help("Quit Naga Control")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white)
    }

    func batteryIcon(_ b: Int) -> String {
        b > 85 ? "battery.100" : b > 60 ? "battery.75" : b > 35 ? "battery.50" : b > 10 ? "battery.25" : "battery.0"
    }

    // MARK: sensitivity
    func performance(_ m: MouseModel) -> some View {
        Card(title: "Sensitivity", icon: "scope") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(mouse.dpiX)").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if !mouse.linkXY {
                    Text("× \(mouse.dpiY)").font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.inkSoft)
                }
                Text("DPI").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("Separate X/Y").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { !mouse.linkXY }, set: { mouse.setLinkXY(!$0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            dpiSlider(value: $mouse.dpiX, max: m.maxDPI)
            if !mouse.linkXY {
                HStack(spacing: 6) {
                    Text("Y").font(.system(size: 11)).foregroundStyle(.secondary)
                    dpiSlider(value: $mouse.dpiY, max: m.maxDPI)
                }
            }
            HStack(spacing: 4) {
                ForEach(presets(max: m.maxDPI), id: \.self) { p in
                    Button(p >= 1000 && p % 1000 == 0 && p >= 10000 ? "\(p / 1000)K" : String(p)) {
                        mouse.dpiX = p; if mouse.linkXY { mouse.dpiY = p }; mouse.applyDPI(debounce: false)
                    }
                    .buttonStyle(Chip(active: mouse.isCurrentDPI(p)))
                }
            }
            SwitchRow(title: "Pointer acceleration", isOn: Binding(get: { mouse.pointerAccel }, set: { mouse.applyPointerAccel($0) }))
                .help("macOS acceleration for this mouse only. Off = 1:1 movement, crisper aim.")
            Row("Polling rate") {
                Picker("", selection: Binding(get: { mouse.pollRate }, set: { mouse.applyPoll($0) })) {
                    Text("125").tag(125); Text("500").tag(500); Text("1000 Hz").tag(1000)
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
        }
    }

    func dpiSlider(value: Binding<Int>, max: Int) -> some View {
        let step = 50
        return Slider(value: Binding(get: { Double(value.wrappedValue) },
                              set: { value.wrappedValue = Int(($0 / Double(step)).rounded()) * step }),
               in: 100...Double(max)) { editing in
            if !editing { mouse.applyDPI(debounce: false) }
        }
    }

    // MARK: scrolling
    func scrolling(_ m: MouseModel) -> some View {
        Card(title: "Scrolling", icon: "arrow.up.arrow.down") {
            SwitchRow(title: "Reverse wheel", isOn: $scroll.reverseVertical)
                .help("Mouse wheels only. The trackpad keeps its own setting.")
            SwitchRow(title: "Reverse tilt (horizontal)", isOn: $scroll.reverseHorizontal)
            if (scroll.reverseVertical || scroll.reverseHorizontal) && !scroll.trusted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Needs Accessibility access").font(.system(size: 11))
                    Spacer()
                    Button("Grant") { scroll.requestAccess() }
                }
            }
            if m.scrollControls {
                SwitchRow(title: "Free-spin wheel", isOn: Binding(get: { mouse.freeSpin }, set: { mouse.applyFreeSpin($0) }))
                    .help("Off = tactile clicks")
                SwitchRow(title: "Smart Reel", isOn: Binding(get: { mouse.smartReel }, set: { mouse.applySmartReel($0) }))
                    .help("Free-spins automatically when you flick the wheel")
                SwitchRow(title: "Scroll acceleration", isOn: Binding(get: { mouse.scrollAccel }, set: { mouse.applyScrollAccel($0) }))
            }
        }
    }

    // MARK: buttons
    func buttons(_ dev: FoundDevice) -> some View {
        let list = dev.model.buttons + MouseButtonID.allCases.filter { remap.seen.contains($0) && !dev.model.buttons.contains($0) }
        let usesNormal = list.contains { $0.mouseButtonNumber != nil && remap.action(dev.pid, $0) != .standard }
        let usesSpecial = remap.wantsDriverMode(dev.pid)
        return Card(title: "Buttons", icon: "computermouse") {
            Text("Press a button on the mouse to find its row.").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(list) { b in
                Row(b.label) {
                    HStack(spacing: 6) {
                        Circle().fill(remap.lastPressed == b ? razerGreen : Color.clear).frame(width: 6, height: 6)
                        Picker("", selection: Binding(get: { remap.action(dev.pid, b) },
                                                      set: { remap.setAction(dev.pid, b, $0); mouse.syncDriverMode() })) {
                            ForEach(ButtonAction.menu) { Text($0.label).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
            if usesNormal && !remap.accessibilityGranted {
                permissionRow("Side buttons need Accessibility access") { remap.requestAccessibilityIfNeeded() }
            }
            if usesSpecial && !remap.inputMonitoringGranted {
                permissionRow("Paddle/top buttons need Input Monitoring access") {
                    remap.requestInputMonitoringIfNeeded()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
            }
        }
        .onAppear { remap.refreshPermissions() }
    }

    func permissionRow(_ text: String, grant: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 11))
            Spacer()
            Button("Grant", action: grant)
        }
    }

    // MARK: lighting
    func lighting(_ m: MouseModel) -> some View {
        Card(title: "Lighting", icon: "lightbulb.max") {
            ForEach(m.zones) { z in
                let effect = mouse.effects[z] ?? .staticColor
                HStack(spacing: 6) {
                    Text(z.label).font(.system(size: 12)).lineLimit(1).frame(width: 74, alignment: .leading)
                    Picker("", selection: Binding(get: { effect }, set: { mouse.effects[z] = $0; mouse.applyLighting(z) })) {
                        ForEach(effects(for: m)) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize()
                    // Fixed slot so every row's brightness slider lines up, with or without a colour well.
                    Group {
                        if m.rgb {
                            // The system ColorPicker opens NSColorPanel, which a menu-bar panel can't host
                            // (it never shows). Use our own swatch popover instead.
                            SwatchButton(color: Binding(get: { mouse.colors[z] ?? MouseController.defaultColor },
                                                        set: {
                                                            mouse.colors[z] = $0
                                                            // Picking a colour while on Spectrum/Off means "show this colour".
                                                            if ![LightEffect.staticColor, .breathing].contains(effect) { mouse.effects[z] = .staticColor }
                                                            mouse.applyLighting(z)
                                                        }))
                        } else { Color.clear }
                    }.frame(width: 34, height: 18)
                    Image(systemName: "sun.max").font(.system(size: 10)).foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    Slider(value: Binding(get: { mouse.brightness[z] ?? 100 }, set: { mouse.brightness[z] = $0 }),
                           in: 0...100) { editing in if !editing { mouse.applyBrightness(z) } }
                        .frame(minWidth: 40, maxWidth: .infinity)
                        .disabled(effect == .off)
                }
            }
        }
    }

    func effects(for m: MouseModel) -> [LightEffect] {
        m.rgb ? LightEffect.allCases : [.staticColor, .breathing, .off]
    }

    // MARK: power
    var power: some View {
        Card(title: "Wireless", icon: "antenna.radiowaves.left.and.right") {
            Row("Sleep after idle") {
                Picker("", selection: Binding(get: { mouse.idleMinutes }, set: { mouse.applyIdle($0) })) {
                    // Include the mouse's own value when it isn't one of ours, or the picker shows blank.
                    ForEach((MouseController.idleChoices + [mouse.idleMinutes]).uniquedSorted, id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden().fixedSize()
            }
            .help(mouse.battery == nil ? "Battery isn't reported right now. The mouse may be asleep: move it, then refresh." : "")
        }
    }

    func unknownNote(_ d: FoundDevice) -> some View {
        Text(String(format: "Unknown Razer device (1532:%04X). Settings are best-effort.", d.pid))
            .font(.system(size: 11)).foregroundStyle(.orange)
    }

    var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "cable.connector").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("No Razer mouse found").font(.system(size: 13, weight: .semibold))
            Text("Plug in the mouse or its dock.").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Rescan") { mouse.rescan() }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    }

    // MARK: footer
    var logView: some View {
        ScrollView {
            Text(mouse.log.suffix(80).joined(separator: "\n"))
                .font(.system(size: 9.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).padding(8)
        }
        .frame(height: 110).background(Color.white)
    }

    var updateMenuLabel: String {
        switch updater.state {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Up to date (v\(Updater.currentVersion))"
        case .available(let v): return "Update available: v\(v)"
        case .failed(let e): return "Update check failed: \(e)"
        default: return "Check for updates (v\(Updater.currentVersion))"
        }
    }

    var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(mouse.statusIsError ? Color.orange : razerGreen).frame(width: 6, height: 6)
            Text(mouse.status).font(.system(size: 11)).foregroundStyle(Theme.inkSoft).lineLimit(1).truncationMode(.tail)
            Spacer()
            Menu {
                Toggle("Open at login", isOn: Binding(get: { scroll.openAtLogin }, set: { scroll.setOpenAtLogin($0) }))
                Divider()
                Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
                Button("Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mouse.diagnostics(), forType: .string)
                }
                Divider()
                Button(updateMenuLabel) { Task { await updater.check() } }
                Divider()
                Button("Quit Naga Control") { NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Theme.inkSoft)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white)
    }
}

struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Card<Content: View>: View {
    let title: String, icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(razerGreen)
                Text(title).foregroundStyle(Theme.inkSoft)
            }
            .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(0.4)
            content
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardBorder))
    }
}

/// Label on the left, control pinned to the right.
struct Row<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control
    init(_ title: String, @ViewBuilder control: () -> Control) { self.title = title; self.control = control() }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            control
        }
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Row(title) { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
    }
}

/// Colour dot that opens a small grid of preset colours.
struct SwatchButton: View {
    @Binding var color: Color
    @State private var open = false
    static let presets: [(String, Color)] = [
        ("White", .white),
        ("Razer green", MouseController.defaultColor),
        ("Red", Color(red: 1, green: 0, blue: 0)),
        ("Orange", Color(red: 1, green: 0.45, blue: 0)),
        ("Yellow", Color(red: 1, green: 0.85, blue: 0)),
        ("Cyan", Color(red: 0, green: 0.85, blue: 1)),
        ("Blue", Color(red: 0, green: 0.25, blue: 1)),
        ("Purple", Color(red: 0.55, green: 0, blue: 1)),
        ("Pink", Color(red: 1, green: 0.2, blue: 0.6)),
    ]
    var body: some View {
        Button { open.toggle() } label: {
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain).help("Pick a colour")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 5), spacing: 6) {
                ForEach(Self.presets, id: \.0) { name, c in
                    Button { color = c; open = false } label: {
                        Circle().fill(c).frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain).help(name)
                }
            }
            .padding(10)
        }
    }
}

struct Chip: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: active ? .semibold : .regular).monospacedDigit())
            .lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Capsule().fill(active ? razerGreen : Theme.chipOff))
            .foregroundStyle(Theme.ink)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private extension Array where Element == Int {
    var uniquedSorted: [Int] { Array(Set(self)).sorted() }
}
