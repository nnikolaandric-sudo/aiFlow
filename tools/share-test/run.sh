#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/local/share-test build/local/ModuleCache
SDK="${FF_SDK:-$(xcrun --show-sdk-path)}"
swiftc -swift-version 5 -Onone -target arm64-apple-macosx14.0 -sdk "$SDK" -module-cache-path build/local/ModuleCache \
  FinderFlow/SecureShareCore.swift tools/share-test/main.swift -lsqlite3 -o build/local/share-test/seed
swiftc -swift-version 5 -Onone -target arm64-apple-macosx14.0 -sdk "$SDK" -module-cache-path build/local/ModuleCache \
  FinderFlow/SecureShareCore.swift FinderFlow/SecureShareRelay.swift FinderFlow/QuickShareServer.swift FinderFlow/QuickShareRuntime.swift FinderFlowShareAgent/main.swift -lsqlite3 -o build/local/share-test/agent
FF_SWIFT_SHARE_TEST=1 npm test --prefix share-server
