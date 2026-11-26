#!/usr/bin/env bash
# Builds NotchClip and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-1.0.0}"

# Quit a running copy and wait until it has fully exited
# (it restores your screenshot settings on the way out).
if pgrep -x NotchClip >/dev/null; then
  echo "▸ Quitting the running NotchClip"
  osascript -e 'quit app "NotchClip"' >/dev/null 2>&1 || pkill -TERM -x NotchClip || true
  for _ in $(seq 1 50); do pgrep -x NotchClip >/dev/null || break; sleep 0.2; done
  pkill -KILL -x NotchClip 2>/dev/null || true
fi

echo "▸ Installing to /Applications"
rm -rf /Applications/NotchClip.app
cp -R build/NotchClip.app /Applications/
xattr -dr com.apple.quarantine /Applications/NotchClip.app 2>/dev/null || true

echo "▸ Launching"
for attempt in 1 2 3 4 5; do
  open /Applications/NotchClip.app && break
  sleep 1
  [ "$attempt" = 5 ] && { echo "Could not launch; run: open /Applications/NotchClip.app"; exit 1; }
done
echo "✓ Installed to /Applications/NotchClip.app"
