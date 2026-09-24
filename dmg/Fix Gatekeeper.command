#!/bin/bash
# aiFlow — one-time Gatekeeper helper (unsigned free build).
# Only clears quarantine on /Applications/aiFlow.app — no network, no sudo.
set -e
APP="/Applications/aiFlow.app"
if [ ! -d "$APP" ]; then
  osascript -e 'display alert "aiFlow not found" message "Drag aiFlow into Applications first, then run this helper again." as critical'
  exit 1
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"
osascript -e 'display notification "aiFlow is ready to open." with title "aiFlow"'
