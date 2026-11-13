// Ivanti AutoConnect — menu bar toggle for Ivanti Secure Access.
//   left-click : connect / disconnect (opens credential setup if none are saved)
//   right-click: status, connect/disconnect, set up / remove credentials, open at login, quit
import AppKit
import ApplicationServices
import ServiceManagement

enum VPNState { case connected, disconnected, busy, unknown }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var state: VPNState = .unknown
    private var running = false            // a connect/disconnect is in progress
    private var lastMessage = ""
    private var timer: Timer?
    private var setup: SetupWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        installEditMenu()
        CredentialStore.migrateOldName()
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        if !CredentialStore.exists() { openSetup() }   // first launch: go straight to setup
    }

    /// Without a main menu, Cmd-V/C/X/A don't work in the setup window's text fields.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Ivanti AutoConnect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(appItem); main.addItem(editItem); main.addItem(windowItem)
        NSApp.mainMenu = main
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
        guard !running else { return }
        let connecting = state != .connected
        if connecting && !CredentialStore.exists() { openSetup(); return }
        // The sign-in is driven through Accessibility; without it every window read fails
        // silently and the connect just sits on the first screen. Ask macOS to prompt for it.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            lastMessage = "Needs Accessibility: allow Ivanti AutoConnect in System Settings › Privacy & Security › Accessibility, then click again."
            showMenu()
            return
        }
        run(connecting ? .connect : .disconnect)
    }

    private func showMenu() {
        let m = NSMenu()
        let title: String
        switch state {
        case .connected: title = "VPN: Connected"
        case .disconnected: title = "VPN: Disconnected"
        case .busy: title = running ? "VPN: Working…" : "VPN: Connecting…"
        case .unknown: title = "VPN: Unknown (is Ivanti running?)"
        }
        m.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        if !lastMessage.isEmpty {
            m.addItem(withTitle: lastMessage, action: nil, keyEquivalent: "").isEnabled = false
        }
        m.addItem(.separator())
        let t = m.addItem(withTitle: state == .connected ? "Disconnect" : "Connect",
                          action: #selector(toggle), keyEquivalent: "")
        t.target = self
        t.isEnabled = !running

        m.addItem(.separator())
        let hasCreds = CredentialStore.exists()
        let s = m.addItem(withTitle: hasCreds ? "Set Up Credentials Again…" : "Set Up Credentials…",
                          action: #selector(openSetup), keyEquivalent: "")
        s.target = self
        s.isEnabled = !running
        let r = m.addItem(withTitle: "Remove Credentials…", action: #selector(removeCredentials), keyEquivalent: "")
        r.target = self
        r.isEnabled = hasCreds && !running

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

    // MARK: credentials

    @objc private func openSetup() {
        if let w = setup, w.window?.isVisible == true { w.present(); return }
        // Prefill the address from saved credentials; never the password or secret.
        let existing = CredentialStore.exists() ? CredentialStore.load()?.user : nil
        let w = SetupWindowController(existingUser: existing)
        w.onFinish = { [weak self] creds in
            guard let self else { return }
            do {
                try CredentialStore.save(creds)
                self.lastMessage = "Credentials saved for \(creds.user)."
                self.confirm("Credentials saved", "Click the shield in the menu bar to connect.")
            } catch {
                self.lastMessage = "Couldn’t save credentials: \(error.localizedDescription)"
                self.confirm("Couldn’t save credentials", error.localizedDescription)
            }
        }
        setup = w
        w.present()
    }

    @objc private func removeCredentials() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Remove saved credentials?"
        a.informativeText = "Your sign-in address, password and authenticator secret will be deleted from the keychain. You’ll need to set up again to connect.\n\nThe authenticator you added at aka.ms/MFASetup stays on your Microsoft account; you can delete it there."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        CredentialStore.remove()
        lastMessage = "Credentials removed."
    }

    private func confirm(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
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

    // MARK: connect / disconnect

    private func run(_ mode: SignInRunner.Mode) {
        running = true
        state = .busy
        render()
        DispatchQueue.global(qos: .userInitiated).async {
            let creds = mode == .connect ? CredentialStore.load() : nil
            let result: String
            if mode == .connect && creds == nil {
                result = "Couldn’t read the saved credentials. Set them up again."
            } else {
                result = SignInRunner(mode: mode, credentials: creds).run()
            }
            DispatchQueue.main.async {
                self.running = false
                self.lastMessage = result
                self.refreshStatus()
            }
        }
    }

    // MARK: status

    private func refreshStatus() {
        DispatchQueue.global(qos: .utility).async {
            let s = Ivanti.connection()?.status ?? ""
            let new: VPNState
            if s.hasPrefix("Connected") { new = .connected }
            else if s.hasPrefix("Disconnected") || s.contains("Failed") { new = .disconnected }
            else if s.isEmpty { new = .unknown }
            else { new = .busy }   // Connecting, Disconnecting, …
            DispatchQueue.main.async {
                self.state = (self.running && new != .connected) ? .busy : new
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
