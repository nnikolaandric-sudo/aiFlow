#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUTPUT="${1:-build/local/FinderFlow.app/Contents}"
SDK="${FF_SDK:-$(xcrun --show-sdk-path)}"
mkdir -p "$OUTPUT/MacOS" "$OUTPUT/Library/LaunchAgents" build/local/ModuleCache
AGENT_ARCHS="${ARCHS:-arm64}"
AGENT_PARTS=()
for agent_arch in $AGENT_ARCHS; do
  agent_part="build/local/share-agent-$agent_arch"
  swiftc -swift-version 5 -O -target "$agent_arch-apple-macosx14.0" -sdk "$SDK" \
    -module-cache-path build/local/ModuleCache \
    FinderFlow/SecureShareCore.swift FinderFlow/SecureShareRelay.swift FinderFlow/QuickShareServer.swift FinderFlow/QuickShareRuntime.swift FinderFlowShareAgent/main.swift \
    -lsqlite3 -o "$agent_part"
  AGENT_PARTS+=("$agent_part")
done
lipo -create "${AGENT_PARTS[@]}" -output "$OUTPUT/MacOS/FinderFlowShareAgent"
cp FinderFlowShareAgent/com.finderflow.share-agent.plist "$OUTPUT/Library/LaunchAgents/"
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$OUTPUT/MacOS/FinderFlowShareAgent"
else
  codesign --force --sign - "$OUTPUT/MacOS/FinderFlowShareAgent"
fi

python3 tools/cloudflare/bundle.py "$OUTPUT"
