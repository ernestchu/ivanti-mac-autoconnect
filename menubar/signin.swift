// ivanti-signin — fast sign-in driver for Ivanti Secure Access, called by ivanti-vpn.sh.
//
//   ivanti-signin <path to ivanti-vpn.sh> connect     fill the sign-in until Connected
//   ivanti-signin <path to ivanti-vpn.sh> disconnect  wait until Disconnected
//
// Talks to the Accessibility API directly (milliseconds per scan instead of seconds through
// AppleScript), polls every 0.1 s, and acts as soon as a field or button appears.
// While it runs it also parks Ivanti's windows almost off-screen, hands focus back if Ivanti
// grabs it, and at the end puts the window back where it was and closes it.
//
// Env: IVANTI_AUTO_PROCEED (default 1), IVANTI_SHOW_WINDOW=1 (don't park windows).
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, ["connect", "disconnect"].contains(args[2]) else {
    FileHandle.standardError.write("usage: ivanti-signin <ivanti-vpn.sh> connect|disconnect\n".data(using: .utf8)!)
    exit(2)
}
let scriptPath = args[1]
let mode = args[2]
let env = ProcessInfo.processInfo.environment
let autoProceed = env["IVANTI_AUTO_PROCEED", default: "1"] == "1"
let parkWindows = env["IVANTI_SHOW_WINDOW"] != "1"
let ivantiBundle = "net.pulsesecure.Pulse-Secure"

guard AXIsProcessTrusted() else {
    print("Needs Accessibility permission (System Settings › Privacy & Security › Accessibility).")
    exit(3)
}

// MARK: helpers

func secret(_ which: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [scriptPath, which]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

let connIndex = env["IVANTI_CONN_INDEX"] ?? ""
let statusScript = NSAppleScript(source: """
    tell application id "\(ivantiBundle)"
      repeat with i from 1 to (count of connections)
        if "\(connIndex)" is "" or ((get indexStr of connection i) as text) is "\(connIndex)" then return connectionStatus of connection i
      end repeat
    end tell
    """)!
func vpnStatus() -> String {
    var err: NSDictionary?
    return statusScript.executeAndReturnError(&err).stringValue ?? ""
}

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}
func str(_ el: AXUIElement, _ name: String) -> String { attr(el, name) as String? ?? "" }

func point(_ el: AXUIElement) -> CGPoint? {
    guard let v: AXValue = attr(el, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v, .cgPoint, &p) ? p : nil
}
func setPoint(_ el: AXUIElement, _ p: CGPoint) {
    var p = p
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
}
func press(_ el: AXUIElement) { AXUIElementPerformAction(el, kAXPressAction as CFString) }

struct Node { let el: AXUIElement; let role, subrole, desc, title: String }

/// Flattened accessibility tree of one window (breadth-first, capped so a huge page can't stall us).
func walk(_ root: AXUIElement, limit: Int = 600) -> [Node] {
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

func ivantiApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == ivantiBundle ||
        (($0.localizedName ?? "").contains("Ivanti") && $0.processIdentifier != getpid()
            && $0.bundleIdentifier != "local.ivanti-autoconnect.menubar")
    }
}
func windows(of app: NSRunningApplication) -> [AXUIElement] {
    attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) ?? []
}

// MARK: window parking and focus

var originalPos: CGPoint?          // where the first Ivanti window was before we parked it
var parked: [CGPoint] = []
func park() {
    guard parkWindows else { return }
    for app in ivantiApps() {
        for w in windows(of: app) {
            guard let p = point(w), p.x > -300 else { continue }   // already parked
            if originalPos == nil { originalPos = p }
            setPoint(w, CGPoint(x: -10000, y: 10000))               // macOS clamps to bottom-left corner
        }
    }
}

var previousApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
func guardFocus() {
    guard let front = NSWorkspace.shared.frontmostApplication else { return }
    if ivantiApps().contains(where: { $0.processIdentifier == front.processIdentifier }) {
        if let prev = previousApp, !prev.isTerminated { prev.activate() }
    } else {
        previousApp = front
    }
}

func restoreAndClose() {
    for app in ivantiApps() {
        for w in windows(of: app) {
            if let p = originalPos { setPoint(w, p) }
            if let close: AXUIElement = attr(w, kAXCloseButtonAttribute) { press(close) }
        }
    }
}

// MARK: sign-in steps

let account = mode == "connect" ? secret("_user") : ""
// A step may be retried once if its field/button is still there 5 s later (the page wasn't ready).
// Never more than twice, so a rejected password isn't re-entered until the account locks.
var doneAt: [String: Date] = [:]
var attempts: [String: Int] = [:]
func isDone(_ k: String) -> Bool {
    if attempts[k, default: 0] >= 2 { return true }
    return doneAt[k].map { Date().timeIntervalSince($0) < 5 } ?? false
}

func fill(_ field: AXUIElement, _ text: String, in nodes: [Node]) {
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
    if let submit = nodes.first(where: { $0.role == "AXButton" && ["Sign in", "Verify", "Next", "Yes"].contains($0.title) }) {
        press(submit.el)
    } else {
        AXUIElementPerformAction(field, "AXConfirm" as CFString)
    }
}

/// One pass over Ivanti's windows: performs at most one step and returns its name.
func step() -> String? {
    for app in ivantiApps() {
        for w in windows(of: app) {
            let nodes = walk(w)
            for n in nodes {
                if n.role == "AXButton" {
                    if autoProceed, !isDone("proceed"), n.desc == "Proceed" { press(n.el); return "proceed" }
                    if !isDone("account"), !account.isEmpty,
                       n.desc.hasPrefix("Sign in with "), n.desc.contains(account) { press(n.el); return "account" }
                    continue
                }
                guard n.role == "AXTextField" || n.role == "AXSecureTextField" else { continue }
                let value: String = attr(n.el, kAXValueAttribute) ?? ""
                guard value.isEmpty else { continue }
                let d = n.desc.lowercased()
                if n.subrole == "AXSecureTextField" || n.role == "AXSecureTextField" {
                    if d.contains("code") { if !isDone("code") { fill(n.el, secret("_otp"), in: nodes); return "code" } }
                    else if !isDone("password") { fill(n.el, secret("_pass"), in: nodes); return "password" }
                } else if d.contains("code") {
                    if !isDone("code") { fill(n.el, secret("_otp"), in: nodes); return "code" }
                } else if ["email", "phone", "sign-in", "skype"].contains(where: d.contains), !isDone("user") {
                    fill(n.el, account, in: nodes); return "user"
                }
            }
        }
    }
    return nil
}

// MARK: main loop

let target = mode == "connect" ? "Connected" : "Disconnected"
let deadline = Date().addingTimeInterval(mode == "connect" ? 180 : 30)
var lastStatusCheck = Date.distantPast
let started = Date()

while Date() < deadline {
    park()
    guardFocus()
    if Date().timeIntervalSince(lastStatusCheck) > 0.4 {
        lastStatusCheck = Date()
        if vpnStatus().hasPrefix(target) {
            usleep(300_000)       // let Ivanti finish redrawing before we close the window
            restoreAndClose()
            print("\(target). (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
            exit(0)
        }
    }
    if mode == "connect", let s = step() {
        doneAt[s] = Date()
        attempts[s, default: 0] += 1
        if env["IVANTI_DEBUG"] == "1" {
            print(String(format: "%.1f s: %@", Date().timeIntervalSince(started), s))
        }
        continue           // look again right away: the next page may already be there
    }
    usleep(100_000)
}
for app in ivantiApps() { for w in windows(of: app) { if let p = originalPos { setPoint(w, p) } } }
print("Timed out; status is \(vpnStatus())")
exit(1)
