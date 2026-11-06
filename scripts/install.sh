#!/usr/bin/env bash
# Builds NotchClip and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-1.0.0}"
pkill -x NotchClip 2>/dev/null || true
rm -rf /Applications/NotchClip.app
cp -R build/NotchClip.app /Applications/
xattr -dr com.apple.quarantine /Applications/NotchClip.app 2>/dev/null || true
open /Applications/NotchClip.app
echo "✓ Installed to /Applications/NotchClip.app"
