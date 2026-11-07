#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT_ROOT="$PWD"
if [[ -n "${FARREACH_GO:-}" ]]; then
    GO_TOOL="$FARREACH_GO"
elif [[ -x "$PROJECT_ROOT/.tools/go/bin/go" ]]; then
    GO_TOOL="$PROJECT_ROOT/.tools/go/bin/go"
else
    GO_TOOL="$(command -v go)"
fi
export GOCACHE="${GOCACHE:-$PROJECT_ROOT/.cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-$PROJECT_ROOT/.cache/go-mod}"
export FARREACH_NETWORK_IMPAIRMENT=1
export FARREACH_NETWORK_BASELINE=1
cd Networking
"$GO_TOOL" test -race -count=1 -v ./internal/peer \
    -run 'TestVirtualWAN|TestLegacyVirtualWANBaseline'
