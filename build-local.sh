#!/bin/bash
#
# build-local.sh — Build + run aiFlow (FinderFlow codebase) locally WITHOUT Xcode.
#
# Uses only Command Line Tools: swiftc + iconutil + codesign (ad-hoc, or "FinderFlow Dev" if present).
# No paid Apple Developer account needed. No notarization (local run only).
#
# Usage:
#   ./build-local.sh [Debug|Release] [--no-run]
#
# Output: build/local/aiFlow.app (+ automatic `open` unless --no-run)
#
# NOTE: The Finder Sync extension (.appex) is intentionally skipped — it needs
# Xcode's pluginkit packaging and a Settings opt-in. The main app runs fully
# without it (file browser, editor, markdown, search, archives, tags, QL).

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FinderFlow"          # Swift module (internal, unchanged: archived class names)
BUNDLE_NAME="aiFlow"           # what Finder, the Dock and Spotlight show
EXEC_NAME="aiFlow"             # process name in Activity Monitor / Force Quit
BUNDLE_ID="com.finderflow.app"
VERSION="1.5.2"
BUILD_NUM="8"
DEPLOYMENT_TARGET="14.0"
CONFIG="Debug"
RUN_APP=1

for arg in "$@"; do
    case "$arg" in
        Release|release) CONFIG="Release" ;;
        Debug|debug)     CONFIG="Debug" ;;
        --no-run)        RUN_APP=0 ;;
        -h|--help)
            echo "Usage: $0 [Debug|Release] [--no-run]"
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

OUT="build/local"
APP="$OUT/$BUNDLE_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
# Persistent Swift module cache: first build compiles AppKit/SwiftUI/WebKit
# .swiftinterface files (slow, single-threaded) — reuse across builds.
MODULE_CACHE="$OUT/ModuleCache"
# SDK: default (newest) — override with FF_SDK=/path/to/MacOSX.sdk if needed.
# History: with CLT 16.2 (Swift 6.0.3.1.10) NO bundled SDK matched the compiler
# (15.2 built with .1.5, 14.x built with Swift 5.10) — a CLT update is required.
# After the update, default SDK + compiler match and this just works.
SDK="${FF_SDK:-$(xcrun --show-sdk-path)}"
[ -d "$SDK" ] || { echo "ERROR: SDK not found: $SDK" >&2; exit 1; }
echo "==> SDK: $SDK"
echo "==> Compiler: $(swiftc --version | head -1)"

echo "==> Cleaning $OUT (keeping ModuleCache)"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$MODULE_CACHE"

if [ "$CONFIG" = "Release" ]; then
    SWIFT_FLAGS=(-O -swift-version 5)
else
    SWIFT_FLAGS=(-Onone -g -swift-version 5)
fi

echo "==> Compiling Swift sources ($CONFIG, arm64, macOS $DEPLOYMENT_TARGET+)..."
# Snapshot: swiftc aborts with "input file was modified during the build" if
# any source changes mtime mid-compile (editors, git ops) — copy to a temp
# dir first and compile the stable copies.
SNAPSHOT="$OUT/src-snapshot"
rm -rf "$SNAPSHOT"; mkdir -p "$SNAPSHOT"
cp FinderFlow/*.swift "$SNAPSHOT/"
# shellcheck disable=SC2206
SWIFT_SOURCES=("$SNAPSHOT"/*.swift)
swiftc \
    "${SWIFT_FLAGS[@]}" \
    -target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
    -sdk "$SDK" \
    -module-cache-path "$MODULE_CACHE" \
    -module-name "$APP_NAME" \
    -o "$MACOS/$EXEC_NAME" \
    "${SWIFT_SOURCES[@]}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Quartz \
    -framework QuickLookThumbnailing \
    -framework WebKit \
    -framework UniformTypeIdentifiers \
    -framework ServiceManagement \
    -framework CoreServices \
    -framework Carbon \
    -framework ApplicationServices
echo "    Binary: $(du -h "$MACOS/$EXEC_NAME" | cut -f1)"

echo "==> Writing Info.plist..."
python3 - "$CONTENTS/Info.plist" <<'PYEOF'
import plistlib, sys
plist = {
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleExecutable': 'aiFlow',
    'CFBundleIconFile': 'AppIcon',
    'CFBundleIdentifier': 'com.finderflow.app',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleName': 'aiFlow',
    'CFBundleDisplayName': 'aiFlow',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.5.2',
    'CFBundleVersion': '8',
    'LSMinimumSystemVersion': '14.0',
    'NSHumanReadableCopyright': 'Copyright © 2024 aiFlow. All rights reserved.',
    'NSPrincipalClass': 'NSApplication',
    'NSAppleEventsUsageDescription': 'aiFlow attaches files to your open Mail compose window when you press ⌥⌘A.',
    'CFBundleURLTypes': [
        {'CFBundleURLName': 'FinderFlow URL',
         'CFBundleURLSchemes': ['finderflow']},
    ],
    'CFBundleDocumentTypes': [
        {'CFBundleTypeName': 'Folder',
         'CFBundleTypeRole': 'Viewer',
         'LSHandlerRank': 'Alternate',
         'LSItemContentTypes': ['public.folder']},
    ],
    # Finder ▸ right-click ▸ Services: E-Sign (ESignServiceProvider).
    'NSServices': [
        {'NSMenuItem': {'default': 'Sign with aiFlow'},
         'NSMessage': 'signDocument',
         'NSPortName': 'aiFlow',
         'NSRequiredContext': {'NSApplicationIdentifier': 'com.apple.finder'},
         'NSSendFileTypes': ['com.adobe.pdf', 'public.image',
                             'org.openxmlformats.wordprocessingml.document',
                             'com.microsoft.word.doc',
                             'public.rtf',
                             'com.apple.rtfd',
                             'org.oasis-open.opendocument.text']},
        {'NSMenuItem': {'default': 'Verify E-Signature with aiFlow'},
         'NSMessage': 'verifySignature',
         'NSPortName': 'aiFlow',
         'NSRequiredContext': {'NSApplicationIdentifier': 'com.apple.finder'},
         'NSSendFileTypes': ['com.adobe.pdf']},
    ],
}
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(plist, f)
print("    Info.plist written")
PYEOF

echo "==> Copying resources (AceEditor)..."
cp -R FinderFlow/AceEditor "$RESOURCES/AceEditor"

echo "==> Building AppIcon.icns..."
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
ASSET="FinderFlow/Assets.xcassets/AppIcon.appiconset"
cp "$ASSET/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ASSET/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ASSET/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ASSET/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ASSET/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ASSET/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ASSET/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ASSET/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ASSET/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ASSET/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Writing PkgInfo..."
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Building embedded share agent..."
./tools/share-test/build-agent.sh "$CONTENTS"

# "FinderFlow Dev" (Settings > Mail integration > Napravi) daje stabilan
# designated requirement, pa Accessibility dozvola prezivi rebuild; bez
# njega ad-hoc (cdhash se menja svakim buildom).
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"FinderFlow Dev"'; then
    SIGN_ID="FinderFlow Dev"
fi
echo "==> Signing (${SIGN_ID/#-/ad-hoc})..."
codesign --force -s "$SIGN_ID" --entitlements FinderFlow/FinderFlow.entitlements "$APP"

echo "==> Verifying..."
codesign -dv "$APP" 2>&1 | sed -n 1,5p  # ne head: SIGPIPE + pipefail prekida build
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$CONTENTS/Info.plist" >/dev/null \
    && echo "    Info.plist OK (v$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$CONTENTS/Info.plist"))"
[ -f "$RESOURCES/AceEditor/editor.html" ] && echo "    AceEditor OK ($(ls "$RESOURCES/AceEditor" | wc -l | tr -d ' ') files)"
[ -f "$RESOURCES/AppIcon.icns" ] && echo "    AppIcon.icns OK"
echo "    Bundle size: $(du -sh "$APP" | cut -f1)"
echo ""
echo "==> Built: $(pwd)/$APP"

if [ "$RUN_APP" -eq 1 ]; then
    echo "==> Launching aiFlow..."
    open "$APP"
    echo "    App launched. Logs (if needed): log stream --predicate 'process == \"aiFlow\"'"
fi
