#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
./tools/share-test/build-agent.sh build/quick-test/Contents
swiftc -swift-version 5 -Onone aiFlow/SecureShareCore.swift aiFlow/QuickShareServer.swift aiFlow/QuickShareRuntime.swift tools/quick-share-test/main.swift -lsqlite3 -o build/quick-test/Contents/MacOS/QuickTest
node tools/quick-share-test/test.mjs "$@"
