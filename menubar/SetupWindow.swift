// Credential setup wizard: account + password, then adding a new authenticator at
// https://aka.ms/MFASetup, pasting its secret key here and confirming the code with Microsoft.
// Nothing is saved until Finish; saving replaces any existing credentials.
import AppKit

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SetupWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onFinish: ((Credentials) -> Void)?

    private var page = 0
    private let pageCount = 4
    private let scroll = NSScrollView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let stepLabel = NSTextField(labelWithString: "")

    // collected values
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let secretField = NSTextField()
    private let secretStatus = NSTextField(labelWithString: "")
    private var secret: String? { TOTP.normalize(secretField.stringValue) }

    // code page
    private let codeLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private var codeTimer: Timer?

    private let contentWidth: CGFloat = 500

    init(existingUser: String?) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Set Up Ivanti AutoConnect"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        userField.stringValue = existingUser ?? ""
        buildChrome()
        showPage(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()   // menu bar apps aren't always allowed to activate
        window?.level = .floating         // keep it above the browser while following the steps
    }

    func windowWillClose(_ notification: Notification) {
        codeTimer?.invalidate()
        passField.stringValue = ""      // don't keep secrets around in a closed window
        secretField.stringValue = ""
    }

    // MARK: layout

    private func buildChrome() {
        guard let content = window?.contentView else { return }
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        backButton.target = self; backButton.action = #selector(back)
        nextButton.target = self; nextButton.action = #selector(next)
        nextButton.keyEquivalent = "\r"
        stepLabel.textColor = .secondaryLabelColor

        let bar = NSStackView(views: [cancel, stepLabel, NSView(), backButton, nextButton])
        bar.orientation = .horizontal
        bar.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll); content.addSubview(sep); content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: sep.topAnchor),
            sep.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func label(_ s: String, size: CGFloat = 13, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        t.textColor = color
        t.preferredMaxLayoutWidth = contentWidth
        t.isSelectable = false
        return t
    }

    /// Text with **bold** spans, for naming the exact buttons to click on Microsoft's pages.
    private func rich(_ s: String) -> NSTextField {
        let out = NSMutableAttributedString()
        for (i, part) in s.components(separatedBy: "**").enumerated() {
            out.append(NSAttributedString(string: part, attributes: [
                .font: i % 2 == 1 ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor]))
        }
        let t = NSTextField(labelWithAttributedString: out)
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 0
        t.preferredMaxLayoutWidth = contentWidth
        return t
    }

    private func screenshot(_ n: Int) -> NSView {
        guard let url = Bundle.main.url(forResource: "\(n)", withExtension: "png", subdirectory: "setup"),
              let img = NSImage(contentsOf: url) else { return NSView() }
        // Screenshots are @2x; show them at half their pixel size, never wider than the page.
        let rep = img.representations.first
        let w = CGFloat(rep?.pixelsWide ?? Int(img.size.width)) / 2
        let h = CGFloat(rep?.pixelsHigh ?? Int(img.size.height)) / 2
        let scale = min(0.8, 360 / w)
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor.separatorColor.cgColor
        iv.layer?.cornerRadius = 6
        iv.layer?.masksToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: w * scale).isActive = true
        iv.heightAnchor.constraint(equalToConstant: h * scale).isActive = true
        let wrap = NSStackView(views: [iv])
        wrap.edgeInsets = NSEdgeInsets(top: 2, left: 20, bottom: 6, right: 0)
        return wrap
    }

    private func row(_ title: String, _ field: NSTextField, placeholder: String) -> NSView {
        field.placeholderString = placeholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let l = NSTextField(labelWithString: title)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 120).isActive = true
        return NSStackView(views: [l, field])
    }

    private func showPage(_ n: Int) {
        page = n
        codeTimer?.invalidate()
        let views: [NSView]
        switch n {
        case 0: views = accountPage()
        case 1: views = authenticatorPage()
        case 2: views = secretPage()
        default: views = codePage()
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 30, bottom: 22, right: 30)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.contentView.scroll(to: .zero)

        stepLabel.stringValue = "Step \(n + 1) of \(pageCount)"
        backButton.isHidden = n == 0
        nextButton.title = n == pageCount - 1 ? "Finish" : "Next"
        updateNext()
        switch n {
        case 0: window?.makeFirstResponder(userField.stringValue.isEmpty ? userField : passField)
        case 2: window?.makeFirstResponder(secretField)
        default: window?.makeFirstResponder(nextButton)
        }
    }

    // MARK: pages

    private func accountPage() -> [NSView] {
        [label("Your VPN sign-in", size: 20, bold: true),
         label("Ivanti AutoConnect signs you in to the VPN by itself: your password, then a 6-digit code from its own authenticator, which you’ll add to your Microsoft account in the next steps."),
         label("Everything is stored in your Mac’s login keychain. Only one set of credentials is kept; setting up again replaces it.", color: .secondaryLabelColor),
         row("Sign-in address", userField, placeholder: "JHEDid@jh.edu"),
         row("Password", passField, placeholder: "JHED password")]
    }

    private func authenticatorPage() -> [NSView] {
        let open = NSButton(title: "Open aka.ms/MFASetup", target: self, action: #selector(openMFASetup))
        open.bezelStyle = .rounded
        open.keyEquivalent = ""
        return [label("Add an authenticator for Ivanti AutoConnect", size: 20, bold: true),
                label("Open Microsoft’s Security info page in your browser and sign in if asked. Then follow these steps there."),
                open,
                rich("1. Click **+ Add sign-in method**."),
                screenshot(1),
                rich("2. Choose **Microsoft Authenticator**."),
                screenshot(2),
                rich("3. Don’t click Next. Click **Set up a different authentication app** at the bottom."),
                screenshot(3),
                rich("4. On the QR code page, click **Can’t scan the QR code?**"),
                screenshot(4),
                label("Microsoft then shows an account name and a secret key. Click Next here to continue.", color: .secondaryLabelColor)]
    }

    private func secretPage() -> [NSView] {
        let paste = NSButton(title: "Paste", target: self, action: #selector(pasteSecret))
        secretField.placeholderString = "Secret key"
        secretField.delegate = self
        secretField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        secretField.translatesAutoresizingMaskIntoConstraints = false
        secretField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let fieldRow = NSStackView(views: [secretField, paste])
        updateSecretStatus()
        return [label("Paste the secret key", size: 20, bold: true),
                rich("5. On the Microsoft page, click **Copy key** next to **Secret key**, then paste it below."),
                screenshot(5),
                fieldRow,
                secretStatus,
                rich("Then click **Next** on the Microsoft page, and **Next** here.")]
    }

    private func codePage() -> [NSView] {
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        codeLabel.isSelectable = true
        countdownLabel.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Copy Code", target: self, action: #selector(copyCode))
        let codeRow = NSStackView(views: [codeLabel, copy])
        codeRow.spacing = 16
        refreshCode()
        codeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshCode() }
        return [label("Confirm with Microsoft", size: 20, bold: true),
                rich("6. Microsoft asks you to **Enter the code**. Copy this code, paste it into **Code**, and click **Next** there."),
                codeRow,
                countdownLabel,
                screenshot(6),
                rich("When Microsoft confirms the new authenticator, click **Finish** here to save."),
                label("Tip: if your Security info page lets you choose a default sign-in method, pick one that asks for a code (for example “Authenticator app or hardware token – code”). Then the VPN asks for a code instead of a push to your phone.", size: 12, color: .secondaryLabelColor)]
    }

    // MARK: actions

    @objc private func openMFASetup() {
        NSWorkspace.shared.open(URL(string: "https://aka.ms/MFASetup")!)
    }

    @objc private func pasteSecret() {
        secretField.stringValue = NSPasteboard.general.string(forType: .string) ?? ""
        updateSecretStatus(); updateNext()
    }

    @objc private func copyCode() {
        guard let s = secret, let code = TOTP.code(secret: s) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        countdownLabel.stringValue = "Copied. " + countdownText()
    }

    private func countdownText() -> String { "Changes in \(TOTP.secondsLeft()) s." }

    private func refreshCode() {
        guard let s = secret, let code = TOTP.code(secret: s) else { return }
        codeLabel.stringValue = String(code.prefix(3)) + " " + String(code.suffix(3))
        if !countdownLabel.stringValue.hasPrefix("Copied") || TOTP.secondsLeft() == 30 {
            countdownLabel.stringValue = countdownText()
        } else {
            countdownLabel.stringValue = "Copied. " + countdownText()
        }
    }

    private func updateSecretStatus() {
        if secretField.stringValue.isEmpty {
            secretStatus.stringValue = ""
        } else if secret != nil {
            secretStatus.stringValue = "✓ Looks like a valid secret key."
            secretStatus.textColor = .systemGreen
        } else {
            secretStatus.stringValue = "That doesn’t look like a secret key. Use Copy key on the Microsoft page."
            secretStatus.textColor = .systemRed
        }
    }

    private func updateNext() {
        switch page {
        case 0: nextButton.isEnabled = userField.stringValue.contains("@") && !passField.stringValue.isEmpty
        case 2, 3: nextButton.isEnabled = secret != nil
        default: nextButton.isEnabled = true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === secretField { updateSecretStatus() }
        updateNext()
    }

    @objc private func back() { if page > 0 { showPage(page - 1) } }

    @objc private func next() {
        guard nextButton.isEnabled else { return }
        if page < pageCount - 1 { showPage(page + 1); return }
        guard let s = secret else { return }
        let c = Credentials(user: userField.stringValue.trimmingCharacters(in: .whitespaces),
                            password: passField.stringValue, totpSecret: s)
        onFinish?(c)
        close()
    }

    @objc private func cancel() { close() }
}
