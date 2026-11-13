// IvantiVPN — menu bar toggle for ivanti-vpn.sh
//   left-click : connect / disconnect
//   right-click: menu (status, connect/disconnect, open at login, quit)
import AppKit
import ApplicationServices
import ServiceManagement

enum VPNState: String { case connected, disconnected, busy, unknown }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state: VPNState = .unknown
    private var running: Process?          // the ivanti-vpn.sh run in progress, if any
    private var lastMessage = ""
    private var timer: Timer?

    private var scriptPath: String {
        Bundle.main.object(forInfoDictionaryKey: "IVScriptPath") as? String
            ?? NSHomeDirectory() + "/ivanti-autoconnect/ivanti-vpn.sh"
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    // MARK: clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        guard running == nil else { return }          // already working on it
        // The sign-in is driven through Accessibility; without it every UI read fails silently
        // and the connect just sits on the first screen. Ask macOS to show the permission prompt.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            lastMessage = "Needs Accessibility: allow IvantiVPN in System Settings › Privacy & Security › Accessibility, then click again."
            showMenu()
            return
        }
        switch state {
        case .connected: run("disconnect")
        default:         run("connect")
        }
    }

    private func showMenu() {
        let m = NSMenu()
        let title: String
        switch state {
        case .connected: title = "VPN: Connected"
        case .disconnected: title = "VPN: Disconnected"
        case .busy: title = running != nil ? "VPN: Working…" : "VPN: Connecting…"
        case .unknown: title = "VPN: Unknown (is Ivanti running?)"
        }
        m.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        if !lastMessage.isEmpty {
            m.addItem(withTitle: "Last: " + lastMessage, action: nil, keyEquivalent: "").isEnabled = false
        }
        m.addItem(.separator())
        let t = m.addItem(withTitle: state == .connected ? "Disconnect" : "Connect",
                          action: #selector(toggle), keyEquivalent: "")
        t.target = self
        t.isEnabled = running == nil
        m.addItem(.separator())
        let login = m.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let q = m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        item.menu = m
        item.button?.performClick(nil)   // pop the menu open under the icon
        item.menu = nil                  // so the next left-click toggles again
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            lastMessage = "Open at Login failed: \(error.localizedDescription)"
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: running the script

    private func run(_ action: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath, action]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { [weak self] proc in
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = nil
                self.lastMessage = text.split(separator: "\n").last.map(String.init) ?? "exit \(proc.terminationStatus)"
                self.refreshStatus()
            }
        }
        do {
            try p.run()
            running = p
            state = .busy
            render()
            // Safety net: if the run hangs (e.g. stuck behind a permission prompt), stop it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self] in
                if p.isRunning {
                    p.terminate()
                    self?.lastMessage = "Gave up after 4 minutes — check System Settings › Privacy & Security."
                }
            }
        } catch {
            lastMessage = "Could not run \(scriptPath): \(error.localizedDescription)"
            render()
        }
    }

    // MARK: status

    private func refreshStatus() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", """
                if application id "net.pulsesecure.Pulse-Secure" is not running then return ""
                tell application id "net.pulsesecure.Pulse-Secure" to return connectionStatus of connection 1
                """]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var s = ""
            if (try? p.run()) != nil {
                p.waitUntilExit()
                s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let new: VPNState
            if s.hasPrefix("Connected") { new = .connected }
            else if s.hasPrefix("Disconnected") || s.contains("Failed") { new = .disconnected }
            else if s.isEmpty { new = .unknown }
            else { new = .busy }   // Connecting, Disconnecting, …
            DispatchQueue.main.async {
                self.state = (self.running != nil && new != .connected) ? .busy : new
                self.render()
            }
        }
    }

    private func render() {
        guard let b = item.button else { return }
        let (symbol, tip): (String, String)
        switch state {
        case .connected:    (symbol, tip) = ("lock.shield.fill", "VPN connected — click to disconnect")
        case .disconnected: (symbol, tip) = ("lock.shield", "VPN disconnected — click to connect")
        case .busy:         (symbol, tip) = ("ellipsis.circle", "VPN working…")
        case .unknown:      (symbol, tip) = ("questionmark.circle", "VPN status unknown — click to connect")
        }
        // A bit larger than the default menu bar glyph (~13 pt).
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .large)
        if state == .connected {
            // Two layers: the lock in white, the shield in green. A single palette color paints
            // both layers green and the lock disappears into the shield.
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        // Template images are tinted black/white by the menu bar; only the green one opts out.
        img?.isTemplate = state != .connected
        b.image = img
        b.toolTip = tip
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
