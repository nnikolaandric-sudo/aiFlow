#!/bin/bash
#
# run.sh — offline provera Google Drive engine-a (bez mreže, bez Keychaina,
# bez pravog Google naloga). Drive API se mockuje preko URLProtocol-a, mirror
# ide u temp folder i briše se na kraju.
#
# Usage: ./tools/gdrive-test/run.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="build/local/gdrive-test"
mkdir -p "$OUT"
SDK="${FF_SDK:-$(xcrun --show-sdk-path)}"

# Izolacija: mirror baza ide u temp folder (GoogleDrivePaths.base čita
# FF_GDRIVE_BASE), pa harness nikad ne dira pravi
# ~/Library/Application\ Support/FinderFlow/GoogleDrive korisnika.
export FF_GDRIVE_BASE="${TMPDIR:-/tmp}/ff-gdrive-base-$USER"
mkdir -p "$FF_GDRIVE_BASE"

echo "==> Compiling harness (SDK: $SDK)"
swiftc -swift-version 5 -Onone -g \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK" \
    -module-cache-path build/local/ModuleCache \
    -o "$OUT/gdrive-test" \
    FinderFlow/GoogleDriveAccount.swift \
    FinderFlow/GoogleDriveAPI.swift \
    FinderFlow/GoogleDriveOAuth.swift \
    FinderFlow/GoogleDriveSyncService.swift \
    FinderFlow/GoogleDriveBadge.swift \
    tools/gdrive-test/main.swift \
    -framework AppKit -framework SwiftUI -framework Network -framework Security

echo "==> Running"
"$OUT/gdrive-test"
