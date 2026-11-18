import Foundation
import AppKit
import Security

/// Self-update from GitHub Releases (github.com/MattMaximo/NagaControl).
/// Each release carries a notarized, Developer-ID-signed `NagaControl.zip`. The app checks the
/// latest release, downloads it, verifies the signature is Matt's team before touching anything,
/// then swaps its own bundle and relaunches. Same signing identity => macOS keeps the
/// Accessibility / Input Monitoring permissions across updates.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "MattMaximo/NagaControl"
    static let assetName = "NagaControl.zip"
    /// Only install bundles signed by this Developer ID team.
    nonisolated static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"8Z64Q39H79\" and identifier \"com.mattmaximo.nagacontrol\""

    enum State: Equatable { case idle, checking, upToDate, available(String), installing, failed(String) }
    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { MouseController.appendLogFile("Updater: \(state)") } }
    }
    private var downloadURL: URL?
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    func start() {
        // `--self-update`: check and install right away (used to test the updater end to end).
        if CommandLine.arguments.contains("--self-update") {
            Task { await check(); if availableVersion != nil { await install() } }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Task { await self.check(quiet: true) } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(quiet: true) }
        }
    }

    var availableVersion: String? { if case .available(let v) = state { return v }; return nil }

    func check(quiet: Bool = false) async {
        if state == .installing { return }
        if !quiet { state = .checking }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub said \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let asset = rel.assets.first(where: { $0.name == Self.assetName }) else { throw UpdateError("release has no \(Self.assetName)") }
            if Self.isNewer(latest, than: Self.currentVersion) {
                downloadURL = URL(string: asset.browser_download_url)
                state = .available(latest)
            } else {
                state = quiet && state == .idle ? .idle : .upToDate
            }
        } catch {
            if !quiet { state = .failed(error.localizedDescription) }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func install() async {
        guard let url = downloadURL else { return }
        state = .installing
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("NagaControlUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("download failed") }
            let zip = work.appendingPathComponent(Self.assetName)
            try FileManager.default.moveItem(at: tmp, to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("no app in the download") }
            try Self.verifySignature(newApp)

            // Swap the bundle after we exit, then relaunch the new one.
            let target = Bundle.main.bundleURL.path
            let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
            /bin/rm -rf "\(target).old" && /bin/mv "\(target)" "\(target).old" && /bin/mv "\(newApp.path)" "\(target)" \
              && /bin/rm -rf "\(target).old" || { /bin/rm -rf "\(target)"; /bin/mv "\(target).old" "\(target)"; }
            /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
            /usr/bin/open "\(target)"
            /bin/rm -rf "\(work.path)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Refuses anything not signed by Matt's Developer ID team with our bundle id.
    nonisolated static func verifySignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError("can't read signature") }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { throw UpdateError("bad requirement") }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), req)
        guard status == errSecSuccess else { throw UpdateError("signature check failed (\(status))") }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed") }
    }

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
