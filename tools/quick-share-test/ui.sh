#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
CONTENTS="$PWD/build/quick-ui/FinderFlowQuickPreview.app/Contents"
./tools/share-test/build-agent.sh "$CONTENTS"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>QuickPreview</string><key>CFBundleIdentifier</key><string>com.finderflow.quick-preview</string><key>CFBundleName</key><string>FinderFlowQuickPreview</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
swiftc -swift-version 5 -Onone -target arm64-apple-macosx14.0 FinderFlow/SecureShareCore.swift FinderFlow/SecureShareRelay.swift FinderFlow/QuickShareServer.swift FinderFlow/QuickShareRuntime.swift FinderFlow/SecureShareUI.swift tools/quick-share-test/ui/main.swift -lsqlite3 -o "$CONTENTS/MacOS/QuickPreview"
codesign --force --sign - "${CONTENTS%/Contents}"
FF_SHARE_DIR="$(mktemp -d -t finderflow-quick-ui)"
export FF_SHARE_DIR FF_SHARE_TEST_MODE=1
trap 'rm -rf "$FF_SHARE_DIR"' EXIT
"$CONTENTS/MacOS/QuickPreview"
