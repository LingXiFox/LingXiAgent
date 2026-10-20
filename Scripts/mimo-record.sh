#!/bin/zsh
set -euo pipefail
: "${MIMO_API_KEY:?MIMO_API_KEY must be set in this shell}"
cd "$(dirname "$0")/.."
OUT="${1:-ContractTests/Fixtures/mimo-chat-live.json}"
swift build --build-tests
LINGXI_RUN_REAL_PROVIDER_SMOKE=1 \
LINGXI_RECORD_MIMO_CASSETTE="$PWD/$OUT" \
  swift test --filter MIMO_liveSmoke
echo "cassette written to $OUT (sanitized: no headers, credential excluded)"
