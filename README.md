# ivanti-mac-autoconnect

One-click connect and disconnect for **Ivanti Secure Access** (formerly Pulse Secure) on macOS,
from your menu bar. **Ivanti AutoConnect** fills in the whole sign-in for you in the background: usage
notice, account, password and 6-digit authenticator code. You can keep working while it does.

- **One click:** click the shield to connect or disconnect. Green means connected.
- **Hands-off:** the Ivanti window is parked off-screen while it works, and your focus stays
  where it was. A connect takes about 8–9 seconds, most of it Ivanti and Microsoft loading pages.
- **All in the app:** setting up, replacing and removing credentials happens in the app. The
  only command you run is the one-time build.

> **Tested only with Johns Hopkins (`vpn.jh.edu`, Microsoft Entra sign-in).** Other schools
> and organizations using Ivanti will probably need small changes; see
> [Other schools and organizations](#other-schools-and-organizations). Pull requests welcome!

## Requirements

- macOS 13 or later
- Ivanti Secure Access Client, with your VPN connection already added
- Xcode or the Command Line Tools, for `swiftc` (`xcode-select --install`)
- A Microsoft account where you can add sign-in methods at
  [aka.ms/MFASetup](https://aka.ms/MFASetup)

## Install (one-time build)

```bash
git clone https://github.com/ernestchu/ivanti-mac-autoconnect.git ~/ivanti-autoconnect
~/ivanti-autoconnect/menubar/build.sh
open ~/ivanti-autoconnect/"Ivanti AutoConnect.app"
```

That's the only time you need the command line. The shield appears in your menu bar, and on
first launch the setup window opens by itself.

`build.sh` signs the app with your **Apple Development** certificate if you have one (any free
Apple ID can create one in Xcode → Settings → Accounts). That way macOS remembers the app's
permissions and keychain access when you rebuild. Without a certificate it falls back to ad-hoc
signing, and macOS asks again after every rebuild.

## Set up credentials

The setup window walks you through everything. Only one set of credentials is kept: setting up
again replaces it.

**Every user adds a new authenticator just for Ivanti AutoConnect.** You don't reuse the one on your
phone. Microsoft lets you register several authenticator apps, and Ivanti AutoConnect becomes one of
them. That way it can make its own 6-digit codes, and your phone keeps working as before.

1. **Your VPN sign-in:** enter your sign-in address (JHU: `JHEDid@jh.edu`) and password.
2. **Add an authenticator:** click **Open aka.ms/MFASetup**, sign in if asked, then on
   Microsoft's page:
   1. Click **+ Add sign-in method**.
   2. Choose **Microsoft Authenticator**.
   3. Don't click Next. Click **Set up a different authentication app**.
   4. On the QR code page, click **Can't scan the QR code?**
3. **Paste the secret key:** Microsoft shows an account name and a **Secret key**. Click
   **Copy key** there, then **Paste** in Ivanti AutoConnect. It checks that the key looks valid. Then click
   **Next** on Microsoft's page.
4. **Confirm with Microsoft:** Ivanti AutoConnect shows a live 6-digit code. Click **Copy Code**, paste
   it into Microsoft's **Enter the code** box and click **Next** there. Once Microsoft confirms
   it, click **Finish** in Ivanti AutoConnect to save.

Nothing is saved until you click **Finish**. Each step in the window shows a screenshot of the
matching Microsoft page.

> **Tip:** if your Security info page lets you choose a **default sign-in method**, pick one
> that asks for a code (for example "Authenticator app or hardware token – code"). Then the VPN
> sign-in asks for a code rather than sending a push to your phone. Ivanti AutoConnect also tries to
> switch from a push page to a code by itself, but that path is untested.

### Permissions

On the first connect macOS asks for these. Allow them all:

| Permission | Why |
|---|---|
| **Accessibility** → Ivanti AutoConnect | read and fill Ivanti's sign-in window |
| **Automation** → Ivanti AutoConnect controls Ivanti Secure Access | start/stop the connection and read its status |

Both are in System Settings → Privacy & Security. If a connect sits on the first screen and does
nothing, Accessibility is almost always the missing piece. Ivanti AutoConnect checks for it before
connecting and asks for it.

## Using it

| Icon | Meaning | Left-click |
|---|---|---|
| Green shield with lock | Connected | Disconnect |
| Outline shield | Disconnected | Connect |
| `⋯` | Connecting or disconnecting | (ignored until done) |
| `?` | Ivanti isn't running | Connect |

If no credentials are saved, a left-click opens the setup window instead of connecting.

**Right-click** (or Control-click) opens the menu:

- the current status and the result of the last connect or disconnect
- **Connect** / **Disconnect**
- **Set Up Credentials…** (**Set Up Credentials Again…** once saved): opens the setup window;
  finishing it replaces the saved credentials
- **Remove Credentials…**: deletes them from the keychain, after asking
- **Open at Login**
- **Quit**

The icon refreshes every 5 seconds, so it also follows connections you start or stop in Ivanti
itself.

## After a password change

Right-click the shield → **Set Up Credentials Again…**, enter the new password and go through
the steps. Finishing replaces the old credentials.

The steps include adding a new authenticator at aka.ms/MFASetup. Afterwards you can delete the
previous Ivanti AutoConnect authenticator from your Security info page so the list stays tidy.

## Removing credentials

Right-click the shield → **Remove Credentials…**. That deletes your sign-in address, password
and authenticator secret from the keychain. The authenticator you added stays on your Microsoft
account until you delete it at [aka.ms/MFASetup](https://aka.ms/MFASetup).

To uninstall completely: remove the credentials, quit Ivanti AutoConnect, delete `Ivanti AutoConnect.app`, and
remove it from System Settings → Privacy & Security → Accessibility.

## How it works

Ivanti's sign-in runs inside its own embedded browser, so macOS Passwords can't autofill it.
Ivanti AutoConnect drives the client instead:

1. **Ivanti's AppleScript interface** starts or stops the connection
   (`SELECTCONNECTION` + `CLICKCONNECTBUTTON`) and reports its status.
2. **The macOS Accessibility API** lets Ivanti AutoConnect read Ivanti's windows about 10 times a second
   and act as soon as the next step appears:
   - **Pre Sign-In Notification** → clicks *Proceed*
   - **Pick an account** → clicks your account
   - **Enter password** → fills the password, clicks *Sign in*
   - **Enter code** → fills the current 6-digit code, clicks *Verify*

   Meanwhile it keeps Ivanti's windows in the bottom-left corner, almost entirely off-screen,
   and switches you back to your previous app if Ivanti steals focus. When the VPN is up, it puts
   the window back where it was and closes it.
3. **Credentials** are one item in your login keychain (`Ivanti AutoConnect credentials`), readable by
   Ivanti AutoConnect. The 6-digit codes are computed locally from the authenticator secret (standard
   TOTP, RFC 6238).

If a step is still there 5 seconds later, because the page wasn't ready, Ivanti AutoConnect retries it
once. It never tries more than twice, so an outdated password can't lock your account.

## Other schools and organizations

Only Johns Hopkins has been tested. Ivanti itself behaves the same everywhere, but each
organization configures its own sign-in pages. What to change, in `menubar/`:

- **Connection name:** `vpnServerMatch` at the top of [`Ivanti.swift`](menubar/Ivanti.swift)
  has to match your connection's server URL or name in Ivanti.
- **Sign-in pages:** `step()` in [`Ivanti.swift`](menubar/Ivanti.swift) recognizes the
  controls by their labels:
  - a *Proceed* button on the usage notice
  - a *Sign in with <your address>* account button (Microsoft "Pick an account")
  - a secure text field for the password
  - a text field whose label contains "code" for the authenticator code
  - submit buttons titled *Sign in*, *Verify*, *Next* or *Yes*

  Organizations with a different identity provider (Okta, Duo, Shibboleth, Ivanti's own login
  page, …) will probably need new labels or steps.
- **Setup instructions:** the wizard text in
  [`SetupWindow.swift`](menubar/SetupWindow.swift) and the screenshots in `setup-totp/` are
  for Microsoft's aka.ms/MFASetup flow.

Accessibility Inspector (Xcode → Open Developer Tool) shows the labels of each field and button
on your sign-in pages. Rebuild with `menubar/build.sh` after changes.

**Pull requests are welcome**, especially support for other schools and identity providers.
Please mention which organization and sign-in flow you tested.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Connect sits on the first screen | Grant **Accessibility** to Ivanti AutoConnect, and remove stale Ivanti AutoConnect entries from older builds. |
| Code rejected at sign-in | Make sure Microsoft confirmed the authenticator in setup step 4 (you clicked **Next** there). If unsure, set up again. |
| Permissions or keychain prompts after every rebuild | Build with an Apple Development certificate (see [Install](#install-one-time-build)). |
| Stops at a page it doesn't recognize | The right-click menu shows where it stopped. See [Other schools and organizations](#other-schools-and-organizations). |
| `?` icon | Ivanti Secure Access isn't running, or has no connection matching `vpnServerMatch`. |

## Security notes

- **This turns two factors into one.** With both your password and an authenticator secret
  stored on the same Mac, anyone who can use your unlocked Mac can sign in to the VPN as you.
  Decide whether that's acceptable for your device, and check your organization's policies.
- Credentials are stored in your login keychain, which is encrypted and unlocked only when you
  log in to macOS. The setup window empties its password and secret fields when it closes.
- The usage notice is accepted on your behalf each time you connect.
- Removing credentials doesn't remove the authenticator from your Microsoft account; delete it at
  aka.ms/MFASetup if you stop using Ivanti AutoConnect.

## Project layout

```
menubar/main.swift         menu bar icon, menu, connect/disconnect
menubar/Ivanti.swift       Ivanti control (AppleScript) and the sign-in driver (Accessibility)
menubar/Credentials.swift  keychain storage and TOTP codes
menubar/SetupWindow.swift  the credential setup window
menubar/make-icon.swift    draws the app icon (the menu bar shield) at build time
menubar/build.sh           builds and signs Ivanti AutoConnect.app
setup-totp/                screenshots shown in the setup window
```

## License

[MIT](LICENSE)

## Disclaimer

Not affiliated with or endorsed by Ivanti, Microsoft or Johns Hopkins University. It works by
automating the Ivanti client's user interface, so an Ivanti or sign-in page update may break it.
Use at your own risk.
