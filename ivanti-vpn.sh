#!/bin/bash
# ivanti-vpn.sh — connect Ivanti Secure Access (vpn.jh.edu) and fill in the Microsoft sign-in:
# account tile -> password -> 6-digit authenticator code.
#
#   ./ivanti-vpn.sh setup        store password + TOTP secret in the login keychain (you type them)
#   ./ivanti-vpn.sh              connect and autofill
#   ./ivanti-vpn.sh disconnect   disconnect
#   ./ivanti-vpn.sh code         print the current 6-digit code (compare with the Passwords app)
#
# Env: IVANTI_SERVER (default vpn.jh.edu); IVANTI_AUTO_PROCEED=0 to click "Proceed" on the
# Pre Sign-In Notification yourself; IVANTI_SHOW_WINDOW=1 to leave the Ivanti window where it
# opens instead of parking it off-screen; IVANTI_DEBUG=1 to print when each step happens.
#
# The sign-in is driven by bin/ivanti-signin (built from menubar/signin.swift by menubar/build.sh):
# it fills each field the moment it appears, keeps the Ivanti window off-screen and your focus
# where it was, then puts the window back and closes it.
#
# Why the login keychain and not Passwords directly: Passwords items live in the iCloud
# (data-protection) keychain, which scripts and the `security` CLI cannot read.
set -euo pipefail

SERVER="${IVANTI_SERVER:-vpn.jh.edu}"
AUTO_PROCEED="${IVANTI_AUTO_PROCEED:-1}"
SVC="ivanti-vpn"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

kc_get() { security find-generic-password -s "$SVC-$1" -w 2>/dev/null; }
# -w as the last argument makes `security` prompt for the secret, so it never appears on argv.
kc_prompt() { echo "$2"; security add-generic-password -U -s "$SVC-$1" -a "$USER" -T /usr/bin/security -w; }

totp() {
  # RFC 6238: SHA1, 30 s, 6 digits. Accepts an otpauth:// URL or a bare base32 key.
  kc_get totp | /usr/bin/python3 -I -c '
import sys, hmac, hashlib, base64, struct, time, urllib.parse as u
s = sys.stdin.read().strip()
if s.startswith("otpauth://"):
    s = u.parse_qs(u.urlparse(s).query)["secret"][0]
s = s.replace(" ", "").upper(); s += "=" * (-len(s) % 8)
h = hmac.new(base64.b32decode(s), struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
o = h[-1] & 15
print("%06d" % ((struct.unpack(">I", h[o:o+4])[0] & 0x7fffffff) % 1000000))'
}

case "${1:-connect}" in
  setup)
    read -rp "Microsoft sign-in address (e.g. JHEDid@jh.edu): " u
    security add-generic-password -U -s "$SVC-user" -a "$USER" -T /usr/bin/security -w "$u"
    kc_prompt pass "Enter your JHED password (asked twice):"
    kc_prompt totp "Paste the otpauth://… value from the Passwords CSV export (asked twice):"
    echo "Saved. Current code: $(totp)  <- should match the Passwords app right now."
    exit 0 ;;
  _user) kc_get user; exit ;;
  _pass) kc_get pass; exit ;;
  _otp|code) totp; exit ;;
  connect|disconnect) ACTION="${1:-connect}" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac

if [ "$ACTION" = connect ]; then
  for k in user pass totp; do
    [ -n "$(kc_get $k || true)" ] || { echo "Missing $SVC-$k in keychain. Run: $0 setup" >&2; exit 1; }
  done
fi

HELPER="$(dirname "$SELF")/bin/ivanti-signin"
[ -x "$HELPER" ] || { echo "Missing $HELPER. Build it with: $(dirname "$SELF")/menubar/build.sh" >&2; exit 1; }

# Ivanti's own scripting interface: find the connection, and press Connect/Disconnect if needed.
read -r IDX STATE < <(/usr/bin/osascript - "$SERVER" <<'APPLESCRIPT'
on run argv
  set serverMatch to item 1 of argv
  tell application id "net.pulsesecure.Pulse-Secure"
    repeat with i from 1 to (count of connections)
      set u to (get connectionServerUrl of connection i) as text
      set n to (get connectionDisplayName of connection i) as text
      if u contains serverMatch or n contains serverMatch then
        return ((get indexStr of connection i) as text) & " " & ((get connectionStatus of connection i) as text)
      end if
    end repeat
  end tell
  error "No Ivanti connection matching " & serverMatch
end run
APPLESCRIPT
)

press_button() {
  /usr/bin/osascript - "$IDX" >/dev/null <<'APPLESCRIPT'
on run argv
  tell application id "net.pulsesecure.Pulse-Secure"
    do PulseMainUI command "SELECTCONNECTION" ConnectionIndexStr (item 1 of argv)
    delay 0.3
    do PulseMainUI command "CLICKCONNECTBUTTON" ConnectionIndexStr (item 1 of argv)
  end tell
end run
APPLESCRIPT
}

case "$ACTION:$STATE" in
  connect:Connected*)       echo "Already connected."; exit 0 ;;
  disconnect:Disconnected*) echo "Already disconnected."; exit 0 ;;
  connect:Connecting*)      ;;   # a connect is already under way; just drive the sign-in
  *)                        press_button ;;
esac

# The sign-in itself (and window parking / focus handling) is done by the compiled helper,
# which reads the window through the Accessibility API in milliseconds instead of seconds.
export IVANTI_CONN_INDEX="$IDX" IVANTI_AUTO_PROCEED="$AUTO_PROCEED"
exec "$HELPER" "$SELF" "$ACTION"
