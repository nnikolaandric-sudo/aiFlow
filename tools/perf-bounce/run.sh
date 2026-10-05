#!/bin/bash
# Perf harness for the folder-bounce report ("skakanje iz foldera u folder ide
# sporo i kuca se"). Compiles the app's REAL DirectoryCache (Foundation-only,
# no UI) and measures the revalidation gate.
#
# Usage: ./tools/perf-bounce/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="build/perf-bounce"
mkdir -p "$OUT"
SDK="${FF_SDK:-$(xcrun --show-sdk-path)}"

swiftc -O -swift-version 5 \
    -target "arm64-apple-macosx14.0" \
    -sdk "$SDK" \
    -module-name FinderFlow \
    -o "$OUT/perf-bounce" \
    aiFlow/DirectoryCache.swift \
    tools/perf-bounce/FileItemStub.swift \
    tools/perf-bounce/main.swift

"$OUT/perf-bounce"
