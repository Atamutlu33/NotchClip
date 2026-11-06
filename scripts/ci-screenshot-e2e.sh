#!/usr/bin/env bash
# Real-system check on a macOS runner: launches the packaged app, takes a screenshot with the
# actual ⌘⇧3 shortcut and verifies it lands on the shelf (not the Desktop), then quits and
# verifies the user's screenshot settings are restored.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=build/NotchClip.app
HOME_DIR="${RUNNER_TEMP:-/tmp}/notchclip-e2e"
INBOX="$HOME_DIR/ScreenshotInbox"
rm -rf "$HOME_DIR"
fail() { echo "FAIL  $*"; pkill -x NotchClip 2>/dev/null; exit 1; }
pass() { echo "PASS  $*"; }

images_from_screenshots() {
  python3 - "$HOME_DIR/history.json" <<'PY'
import json, sys
try:
    items = json.load(open(sys.argv[1]))["items"]
except Exception:
    print(0); sys.exit()
print(sum(1 for i in items if i.get("kind") == "image" and i.get("sourceAppName") == "Screenshot"))
PY
}

before_location=$(defaults read com.apple.screencapture location 2>/dev/null || echo "<unset>")
desktop_before=$(ls -1 "$HOME/Desktop" 2>/dev/null | wc -l | tr -d ' ')
defaults delete com.atamutlu.NotchClip >/dev/null 2>&1 || true

open -n "$APP" --env NOTCHCLIP_HOME="$HOME_DIR"
sleep 6
pgrep -x NotchClip >/dev/null || fail "app is running"

location=$(defaults read com.apple.screencapture location 2>/dev/null || echo "<unset>")
[ "$location" = "$INBOX" ] || fail "system screenshot location points at NotchClip (got $location)"
pass "system screenshot location points at NotchClip"

swift scripts/press-screenshot-shortcut.swift
method="real ⌘⇧3 shortcut"
for _ in $(seq 1 40); do
  [ "$(images_from_screenshots)" -ge 1 ] && break
  sleep 0.5
done
if [ "$(images_from_screenshots)" -lt 1 ]; then
  # Some runners do not let synthetic key presses reach the system shortcut handler.
  echo "note: synthetic ⌘⇧3 was not delivered on this runner; using screencapture into the configured location"
  method="screencapture into the configured location"
  screencapture -x "$location/Screenshot ci.png" || fail "screencapture"
  for _ in $(seq 1 40); do
    [ "$(images_from_screenshots)" -ge 1 ] && break
    sleep 0.5
  done
fi
[ "$(images_from_screenshots)" -ge 1 ] || fail "screenshot appears on the shelf ($method)"
pass "screenshot appears on the shelf ($method)"

[ -z "$(ls -A "$INBOX" 2>/dev/null)" ] || fail "inbox is emptied"
pass "no screenshot file is left behind"
desktop_after=$(ls -1 "$HOME/Desktop" 2>/dev/null | wc -l | tr -d ' ')
[ "$desktop_after" = "$desktop_before" ] || fail "Desktop unchanged ($desktop_before -> $desktop_after)"
pass "nothing was saved to the Desktop"

osascript -e 'quit app "NotchClip"' >/dev/null 2>&1 || pkill -TERM -x NotchClip
sleep 4
pgrep -x NotchClip >/dev/null && fail "app quit"
after_location=$(defaults read com.apple.screencapture location 2>/dev/null || echo "<unset>")
[ "$after_location" = "$before_location" ] || fail "screenshot location restored ($after_location != $before_location)"
pass "screenshot location restored after quitting ($after_location)"

echo "SCREENSHOT E2E PASSED"
