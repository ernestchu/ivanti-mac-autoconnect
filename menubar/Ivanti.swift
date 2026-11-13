// Ivanti Secure Access control (its AppleScript interface) and the sign-in driver
// (Accessibility API). Everything here is blocking; call it off the main thread.
import AppKit
import ApplicationServices

/// The Ivanti connection to use, matched against its server URL or display name.
/// Change this for another school or organization.
let vpnServerMatch = "vpn.jh.edu"

let ivantiBundleID = "net.pulsesecure.Pulse-Secure"

enum Ivanti {
    /// Runs an AppleScript through osascript. Returns trimmed stdout, or nil on error.
    @discardableResult
    static func osascript(_ source: String, _ args: [String] = []) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + args
        let input = Pipe(), out = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        input.fileHandleForWriting.write(source.data(using: .utf8)!)
        input.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// (connection index, status) of the configured connection, or nil if Ivanti isn't running
    /// or has no matching connection.
    static func connection() -> (index: String, status: String)? {
        let r = osascript("""
            on run argv
              if application id "\(ivantiBundleID)" is not running then return ""
              tell application id "\(ivantiBundleID)"
                repeat with i from 1 to (count of connections)
                  set u to (get connectionServerUrl of connection i) as text
                  set n to (get connectionDisplayName of connection i) as text
                  if u contains (item 1 of argv) or n contains (item 1 of argv) then
                    return ((get indexStr of connection i) as text) & tab & ((get connectionStatus of connection i) as text)
                  end if
                end repeat
              end tell
              return ""
            end run
            """, [vpnServerMatch])
        guard let r, let tab = r.firstIndex(of: "\t") else { return nil }
        return (String(r[..<tab]), String(r[r.index(after: tab)...]))
    }

    /// Presses the connection's Connect/Disconnect button (it toggles).
    static func pressConnectButton(_ index: String) {
        osascript("""
            on run argv
              tell application id "\(ivantiBundleID)"
                do PulseMainUI command "SELECTCONNECTION" ConnectionIndexStr (item 1 of argv)
                delay 0.3
                do PulseMainUI command "CLICKCONNECTBUTTON" ConnectionIndexStr (item 1 of argv)
              end tell
            end run
            """, [index])
    }
}

/// Drives one connect or disconnect: presses the button, fills each sign-in step the moment it
/// appears, keeps Ivanti's windows off-screen and your focus where it was, then puts the window
/// back and closes it.
final class SignInRunner {
    enum Mode { case connect, disconnect }

    private let mode: Mode
    private let creds: Credentials?
    private var originalPos: CGPoint?
    private var previousApp = NSWorkspace.shared.frontmostApplication
    private var doneAt: [String: Date] = [:]
    private var attempts: [String: Int] = [:]

    init(mode: Mode, credentials: Credentials?) {
        self.mode = mode
        self.creds = credentials
    }

    /// Returns a one-line result for the menu.
    func run() -> String {
        guard let conn = Ivanti.connection() else {
            return "Ivanti isn't running, or has no \(vpnServerMatch) connection."
        }
        let target = mode == .connect ? "Connected" : "Disconnected"
        if conn.status.hasPrefix(target) { return "Already \(target.lowercased())." }
        if !(mode == .connect && conn.status.hasPrefix("Connecting")) {
            Ivanti.pressConnectButton(conn.index)
        }

        let started = Date()
        let deadline = started.addingTimeInterval(mode == .connect ? 180 : 30)
        var lastCheck = Date.distantPast
        while Date() < deadline {
            park()
            guardFocus()
            if Date().timeIntervalSince(lastCheck) > 0.4 {
                lastCheck = Date()
                if Ivanti.connection()?.status.hasPrefix(target) == true {
                    usleep(300_000)   // let Ivanti finish redrawing before closing the window
                    restoreAndClose()
                    return String(format: "%@ in %.1f s.", target, Date().timeIntervalSince(started))
                }
            }
            if mode == .connect, let s = step() {
                doneAt[s] = Date()
                attempts[s, default: 0] += 1
                continue          // look again right away: the next page may already be there
            }
            usleep(100_000)
        }
        restorePositions()      // leave the window open, back on screen, to show where it stopped
        return "Timed out; Ivanti says \(Ivanti.connection()?.status ?? "nothing")."
    }

    // MARK: Accessibility helpers

    private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
    private func str(_ el: AXUIElement, _ name: String) -> String { attr(el, name) as String? ?? "" }

    private func point(_ el: AXUIElement) -> CGPoint? {
        guard let v: AXValue = attr(el, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }
    private func setPoint(_ el: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }
    private func press(_ el: AXUIElement) { AXUIElementPerformAction(el, kAXPressAction as CFString) }

    private struct Node { let el: AXUIElement; let role, subrole, desc, title: String }

    /// Flattened accessibility tree of one window, breadth-first and capped.
    private func walk(_ root: AXUIElement, limit: Int = 600) -> [Node] {
        var out: [Node] = []
        var queue = [root]
        while !queue.isEmpty && out.count < limit {
            let el = queue.removeFirst()
            out.append(Node(el: el, role: str(el, kAXRoleAttribute), subrole: str(el, kAXSubroleAttribute),
                            desc: str(el, kAXDescriptionAttribute), title: str(el, kAXTitleAttribute)))
            if let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) { queue.append(contentsOf: kids) }
        }
        return out
    }

    private func ivantiApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() &&
            ($0.bundleIdentifier == ivantiBundleID ||
             (($0.localizedName ?? "").contains("Ivanti") && $0.bundleIdentifier != Bundle.main.bundleIdentifier))
        }
    }
    private func windows(of app: NSRunningApplication) -> [AXUIElement] {
        attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) ?? []
    }

    // MARK: window parking and focus

    private func park() {
        for app in ivantiApps() {
            for w in windows(of: app) {
                guard let p = point(w), p.x > -300 else { continue }   // already parked
                if originalPos == nil { originalPos = p }
                setPoint(w, CGPoint(x: -10000, y: 10000))   // macOS clamps this to the bottom-left corner
            }
        }
    }

    private func guardFocus() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if ivantiApps().contains(where: { $0.processIdentifier == front.processIdentifier }) {
            if let prev = previousApp, !prev.isTerminated { prev.activate() }
        } else {
            previousApp = front
        }
    }

    private func restorePositions() {
        guard let p = originalPos else { return }
        for app in ivantiApps() { for w in windows(of: app) { setPoint(w, p) } }
    }

    private func restoreAndClose() {
        for app in ivantiApps() {
            for w in windows(of: app) {
                if let p = originalPos { setPoint(w, p) }
                if let close: AXUIElement = attr(w, kAXCloseButtonAttribute) { press(close) }
            }
        }
    }

    // MARK: sign-in steps

    /// A step may be retried once if it is still there 5 s later (the page wasn't ready), never
    /// more, so a rejected password isn't re-entered until the account locks.
    private func isDone(_ k: String) -> Bool {
        if attempts[k, default: 0] >= 2 { return true }
        return doneAt[k].map { Date().timeIntervalSince($0) < 5 } ?? false
    }

    private func fill(_ field: AXUIElement, _ text: String, in nodes: [Node]) {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
        if let submit = nodes.first(where: { $0.role == "AXButton" && ["Sign in", "Verify", "Next", "Yes"].contains($0.title) }) {
            press(submit.el)
        } else {
            AXUIElementPerformAction(field, "AXConfirm" as CFString)
        }
    }

    private func currentCode() -> String { creds.flatMap { TOTP.code(secret: $0.totpSecret) } ?? "" }

    /// One pass over Ivanti's windows: performs at most one step and returns its name.
    private func step() -> String? {
        guard let creds else { return nil }
        for app in ivantiApps() {
            for w in windows(of: app) {
                let nodes = walk(w)
                for n in nodes {
                    // Accounts whose default method is an Authenticator push: switch to a code.
                    // (Labels from Microsoft's sign-in page; untested with JHU, whose page asks
                    // for a code directly.)
                    if n.role == "AXLink" || n.role == "AXButton" {
                        let label = (n.title.isEmpty ? n.desc : n.title).lowercased()
                        if !isDone("cantuse"), label.contains("can't use my microsoft authenticator") || label.contains("can’t use my microsoft authenticator") {
                            press(n.el); return "cantuse"
                        }
                        if !isDone("usecode"), label.contains("use a verification code") {
                            press(n.el); return "usecode"
                        }
                    }
                    if n.role == "AXButton" {
                        if !isDone("proceed"), n.desc == "Proceed" { press(n.el); return "proceed" }
                        if !isDone("account"), n.desc.hasPrefix("Sign in with "),
                           n.desc.localizedCaseInsensitiveContains(creds.user) { press(n.el); return "account" }
                        continue
                    }
                    guard n.role == "AXTextField" || n.role == "AXSecureTextField" else { continue }
                    let value: String = attr(n.el, kAXValueAttribute) ?? ""
                    guard value.isEmpty else { continue }
                    let d = n.desc.lowercased()
                    if n.subrole == "AXSecureTextField" || n.role == "AXSecureTextField" {
                        if d.contains("code") { if !isDone("code") { fill(n.el, currentCode(), in: nodes); return "code" } }
                        else if !isDone("password") { fill(n.el, creds.password, in: nodes); return "password" }
                    } else if d.contains("code") {
                        if !isDone("code") { fill(n.el, currentCode(), in: nodes); return "code" }
                    } else if ["email", "phone", "sign-in", "skype"].contains(where: d.contains), !isDone("user") {
                        fill(n.el, creds.user, in: nodes); return "user"
                    }
                }
            }
        }
        return nil
    }
}
