#!/bin/zsh
set -euo pipefail
: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY must be set in this shell}"
cd "$(dirname "$0")/.."
OUT="${1:-ContractTests/Fixtures/deepseek-responses-live.json}"
swift build --build-tests
LINGXI_RUN_REAL_PROVIDER_SMOKE=1 \
LINGXI_RECORD_DEEPSEEK_CASSETTE="$PWD/$OUT" \
  swift test --filter DEEPSEEK_liveSmoke
echo "cassette written to $OUT (sanitized: no headers, credential excluded)"
