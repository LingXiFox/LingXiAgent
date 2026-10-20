#!/bin/zsh
set -euo pipefail
: "${MIMO_API_KEY:?MIMO_API_KEY must be set in this shell}"
cd "$(dirname "$0")/.."
swift build --build-tests
LINGXI_RUN_REAL_PROVIDER_SMOKE=1 swift test --filter MIMO_liveSmoke
