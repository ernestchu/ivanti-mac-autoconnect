# ivanti-mac-autoconnect

One-click connect and disconnect for **Ivanti Secure Access** (formerly Pulse Secure) on macOS.
It fills in the whole sign-in for you — usage notice, account, password and 6-digit
authenticator code — in the background, while you keep working.

- **Menu bar app:** click the shield to connect or disconnect. Green means connected.
- **CLI:** `ivanti-vpn.sh` / `ivanti-vpn.sh disconnect` for scripts and terminals.
- **Hands-off:** the Ivanti window is parked off-screen while it works and your focus stays where
  it was. A connect takes about 8–9 seconds, most of it Ivanti and Microsoft loading pages.

> **Tested only with Johns Hopkins (`vpn.jh.edu`, Microsoft Entra sign-in with an authenticator
> code).** Other schools and organizations using Ivanti will probably need small changes —
> see [Other schools and organizations](#other-schools-and-organizations). Pull requests welcome!

## How it works

Ivanti's sign-in runs inside its own embedded browser, so macOS Passwords can't autofill it.
This project drives the client instead:

1. **Ivanti's AppleScript interface** starts or stops the connection
   (`SELECTCONNECTION` + `CLICKCONNECTBUTTON`) and reports its status.
2. **`bin/ivanti-signin`**, a small Swift helper, watches Ivanti's windows through the macOS
   Accessibility API. About 10 times a second it looks for the next step and acts as soon as it
   appears:
   - **Pre Sign-In Notification** → clicks *Proceed*
   - **Pick an account** → clicks your account
   - **Enter password** → fills the password, clicks *Sign in*
   - **Enter code** → fills the current 6-digit code, clicks *Verify*

   Meanwhile it keeps Ivanti's windows in the bottom-left corner, almost entirely off-screen,
   and switches you back to your previous app if Ivanti steals focus. When the VPN is up, it puts
   the window back where it was and closes it. The app keeps running in the menu bar.
3. **Secrets live in your login keychain.** Items in the Passwords app are stored in iCloud
   Keychain, which no script can read, not even with `sudo`. So `setup` stores a copy of your
   password and authenticator secret in the login keychain. The 6-digit code is computed locally
   (standard TOTP, RFC 6238).

## Requirements

- macOS 13 or later (developed on Apple Silicon)
- Ivanti Secure Access Client, with your VPN connection already added
- Xcode or the Command Line Tools, for `swiftc` (`xcode-select --install`)
- Your password, and an authenticator **setup key** (TOTP secret) for your account.
  Push-only MFA (approve on your phone) can't be automated; see
  [Getting your authenticator secret](#getting-your-authenticator-secret).

## Setup

### 1. Get the code and build

```bash
git clone https://github.com/ernestchu/ivanti-mac-autoconnect.git ~/ivanti-autoconnect
cd ~/ivanti-autoconnect
./menubar/build.sh
```

This builds:

| Output | What it is |
|---|---|
| `bin/ivanti-signin` | the sign-in helper used by both the CLI and the app |
| `IvantiVPN.app` | the menu bar app |

`build.sh` signs both with your **Apple Development** certificate if you have one (any free
Apple ID can make one in Xcode → Settings → Accounts). That keeps macOS permissions across
rebuilds. Without a certificate it falls back to ad-hoc signing, and macOS will ask for
permissions again after every rebuild. To choose a certificate yourself, set
`SIGN_ID="Apple Development: …" ./menubar/build.sh`.

The app runs `ivanti-vpn.sh` from the folder it was built in. If you move the folder, run
`build.sh` again.

### 2. Store your credentials

```bash
./ivanti-vpn.sh setup
```

It asks for:

1. **Your sign-in address**, as shown on the Microsoft page (JHU: `JHEDid@jh.edu`).
2. **Your password**, entered twice. It's typed into the `security` prompt and never appears
   in the command line.
3. **Your authenticator secret**, entered twice: an `otpauth://…` URL or a bare base32 key.

At the end it prints the current 6-digit code. Check that it matches your authenticator app or
the Passwords app before going on.

The items are saved in your login keychain as `ivanti-vpn-user`, `ivanti-vpn-pass` and
`ivanti-vpn-totp`. Only `/usr/bin/security` is allowed to read them without asking.

### 3. Grant permissions

On the first run macOS asks for these. Allow them all:

| Permission | Granted to | Why |
|---|---|---|
| **Accessibility** | `IvantiVPN` (menu bar), or your terminal app (CLI) | read and fill Ivanti's sign-in window |
| **Automation → Ivanti Secure Access** | same | start/stop the connection and read its status |

All of these are in System Settings → Privacy & Security. If a connect sits on the first
screen and does nothing, Accessibility is almost always the missing piece. The menu bar app
checks for it and asks before it starts.

### 4. Start the menu bar app

```bash
open IvantiVPN.app
```

Right-click the icon and tick **Open at Login** to have it start automatically.

## Using the menu bar app

| Icon | Meaning | Left-click |
|---|---|---|
| Green shield with lock | Connected | Disconnect |
| Outline shield | Disconnected | Connect |
| `⋯` | Connecting or disconnecting | (ignored until done) |
| `?` | Ivanti isn't running | Connect |

**Right-click** (or Control-click) opens a menu with:

- the current status and the result of the last run
- Connect / Disconnect
- **Open at Login**
- Quit

The icon refreshes every 5 seconds, so it also follows connections you start or stop in Ivanti
itself. A run that hangs for more than 4 minutes is stopped.

## Using the command line

```bash
./ivanti-vpn.sh              # connect (fills in the sign-in)
./ivanti-vpn.sh disconnect   # disconnect
./ivanti-vpn.sh setup        # store or replace your credentials
./ivanti-vpn.sh code         # print the current 6-digit code
```

Add `&` to get your prompt back straight away, for example `./ivanti-vpn.sh &`.

Options, set as environment variables:

| Variable | Default | Effect |
|---|---|---|
| `IVANTI_SERVER` | `vpn.jh.edu` | which Ivanti connection to use (matched against its URL or name) |
| `IVANTI_AUTO_PROCEED` | `1` | `0` = click *Proceed* on the usage notice yourself |
| `IVANTI_SHOW_WINDOW` | `0` | `1` = leave the Ivanti window where it opens instead of parking it off-screen |
| `IVANTI_DEBUG` | `0` | `1` = print when each step happens |

Example with step timings:

```
$ IVANTI_DEBUG=1 ./ivanti-vpn.sh
1.2 s: proceed
2.7 s: account
3.1 s: password
4.5 s: code
Connected. (7.8 s)
```

The menu bar app doesn't pass these variables through. To change a default for the app, edit it
at the top of `ivanti-vpn.sh`.

## After a password change

When your password changes, run `setup` again and enter the new password:

```bash
./ivanti-vpn.sh setup
```

It overwrites the stored items. Enter the same sign-in address and authenticator secret as
before, unless those changed too. Nothing needs to be rebuilt.

If you re-enroll your authenticator, run `setup` with the new secret the same way.

**Removing everything** from the keychain:

```bash
for k in user pass totp; do security delete-generic-password -s "ivanti-vpn-$k"; done
```

## Getting your authenticator secret

The script needs the TOTP **secret** (setup key), not a 6-digit code. Ways to get it:

- **Apple Passwords:** if Passwords already shows your verification codes, choose
  File → Export Passwords…. The CSV has an `OTPAuth` column with the `otpauth://…` URL.
  Copy it, then **delete the CSV**, because it contains all of your passwords in plain text.
- **Adding a new authenticator method:** in your organization's MFA settings (JHU: Microsoft
  "Security info"), add an authenticator app and choose the option for a different app or
  "Can't scan image?". That usually shows the secret key. Add it to Passwords or your authenticator app
  too, so you still have a second device.

## Other schools and organizations

Only Johns Hopkins has been tested. Ivanti itself behaves the same everywhere, but each
organization configures its own sign-in pages. What to check:

- **Connection name:** set `IVANTI_SERVER` (CLI), or change its default in `ivanti-vpn.sh`
  (menu bar app), to match your connection's URL or name in Ivanti.
- **Sign-in pages:** the helper recognizes the controls by their labels. They're all in
  `step()` in [`menubar/signin.swift`](menubar/signin.swift):
  - a *Proceed* button on the usage notice
  - a *Sign in with <your address>* account button (Microsoft "Pick an account")
  - a secure text field for the password
  - a text field whose label contains "code" for the authenticator code
  - submit buttons titled *Sign in*, *Verify*, *Next* or *Yes*

  Organizations using a different identity provider (Okta, Duo, Shibboleth, Ivanti's own
  login page, …) will probably need new labels or steps here.
- **Seeing what your pages expose:** run with `IVANTI_SHOW_WINDOW=1 IVANTI_DEBUG=1` to watch
  each step. Accessibility Inspector (in Xcode → Open Developer Tool) shows the labels of each
  field and button.

**Pull requests are welcome**, especially support for other schools and identity providers.
Please mention which organization and sign-in flow you tested.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Connect sits on the first screen | Grant **Accessibility** to `IvantiVPN` (or your terminal). Remove stale entries for old builds from the list. |
| Permissions keep resetting after a rebuild | Build with an Apple Development certificate (see [Setup](#1-get-the-code-and-build)). |
| `Missing … in keychain` | Run `./ivanti-vpn.sh setup`. |
| Code rejected | Compare `./ivanti-vpn.sh code` with your authenticator app. If they differ, check the stored secret and your Mac's clock. |
| Stops at a page it doesn't recognize | Run with `IVANTI_SHOW_WINDOW=1 IVANTI_DEBUG=1` to see the last step, then adjust `step()` in `signin.swift`. |
| `Missing bin/ivanti-signin` | Run `./menubar/build.sh`. |

If the password is rejected, the helper re-enters it at most once. That way an outdated
password won't lock your account; run `setup` with the new one.

## Security notes

- **This turns two factors into one.** With both your password and your authenticator secret
  stored on the same Mac, anyone who can use your unlocked Mac can sign in to the VPN as you.
  Decide whether that's acceptable for your device, and check your organization's policies.
- Both are stored in your login keychain, which is encrypted and unlocked only when you log in
  to macOS.
- Secrets are read only when needed and are never passed on the command line or written to
  disk.
- With `IVANTI_AUTO_PROCEED=1` (the default) the usage notice is accepted on your behalf every
  time you connect.

## Project layout

```
ivanti-vpn.sh          CLI: setup, keychain, TOTP, starts/stops the connection, hands off to the helper
menubar/signin.swift   source of bin/ivanti-signin (Accessibility-driven sign-in)
menubar/main.swift     source of IvantiVPN.app (menu bar toggle)
menubar/build.sh       builds and signs both
```

## License

[MIT](LICENSE)

## Disclaimer

Not affiliated with or endorsed by Ivanti, Microsoft or Johns Hopkins University. It works by
automating the Ivanti client's user interface, so an Ivanti or sign-in page update may break it.
Use at your own risk.
