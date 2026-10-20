#!/bin/zsh
set -euo pipefail
: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY must be set in this shell}"
cd "$(dirname "$0")/.."
swift build --build-tests
LINGXI_RUN_REAL_PROVIDER_SMOKE=1 swift test --filter DEEPSEEK_liveSmoke
