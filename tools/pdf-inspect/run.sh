#!/bin/bash
#
# run.sh — build + run pdf-inspect CLI-ja za AI agente (bez Xcode-a).
#
# Usage:
#   ./tools/pdf-inspect/run.sh dokument.pdf [--json] [--excerpt 4000] [...]
#   ./tools/pdf-inspect/run.sh --build-only   # samo kompajlira u build/local/
#
# Binary: build/local/pdf-inspect (ad-hoc potpisan, radi lokalno).
# Posle builda agenti mogu zvati direktno:
#   build/local/pdf-inspect faktura.pdf --json | jq .pdf_type
#
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="build/local"
BIN="$OUT/pdf-inspect"
mkdir -p "$OUT"
SDK="${FF_SDK:-$(xcrun --show-sdk-path)}"

echo "==> Compiling pdf-inspect (SDK: $SDK)"
swiftc -swift-version 5 -O \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK" \
    -module-cache-path build/local/ModuleCache \
    -o "$BIN" \
    tools/pdf-inspect/main.swift \
    -framework AppKit -framework PDFKit -framework Vision -framework Quartz
codesign --force -s - "$BIN" >/dev/null 2>&1 || true

if [ "${1:-}" = "--build-only" ]; then
    echo "==> Built: $(pwd)/$BIN"
    exit 0
fi

if [ $# -eq 0 ]; then
    echo "Usage: $0 dokument.pdf [--json] [--excerpt 4000] [...]" >&2
    echo "       $0 --build-only" >&2
    exit 2
fi

exec "$BIN" "$@"
