#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"
if [[ -n "${FARREACH_GO:-}" ]]; then
    GO_TOOL="$FARREACH_GO"
elif command -v go >/dev/null 2>&1; then
    GO_TOOL="$(command -v go)"
elif [[ -x "$PROJECT_ROOT/.tools/go/bin/go" ]]; then
    GO_TOOL="$PROJECT_ROOT/.tools/go/bin/go"
else
    printf '%s\n' 'Go 1.25+ is required to build the bundled network engine. Install it from https://go.dev/dl/ or set FARREACH_GO.' >&2
    exit 1
fi
export GOCACHE="${GOCACHE:-$PROJECT_ROOT/.cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-$PROJECT_ROOT/.cache/go-mod}"
mkdir -p Networking/bin
cd Networking
for TARGET_ARCH in arm64 amd64; do
    CGO_ENABLED=0 GOOS=darwin GOARCH="$TARGET_ARCH" "$GO_TOOL" build -trimpath -ldflags='-s -w' -o "bin/FarReachNetwork-$TARGET_ARCH" ./cmd/farreach-network
done
/usr/bin/lipo -create bin/FarReachNetwork-arm64 bin/FarReachNetwork-amd64 -output bin/FarReachNetwork
cd "$PROJECT_ROOT"
FARREACH_GO="$GO_TOOL" python3 scripts/collect-network-licenses.py
printf 'Built bundled direct-only network engine\n'
