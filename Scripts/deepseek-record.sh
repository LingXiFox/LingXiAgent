#!/bin/zsh
set -euo pipefail
: "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY must be set in this shell}"
cd "$(dirname "$0")/.."
OUT="${1:-ContractTests/Fixtures/deepseek-responses-live.json}"
swift build --build-tests
LINGXI_RUN_REAL_PROVIDER_SMOKE=1 \
LINGXI_RECORD_DEEPSEEK_CASSETTE="$PWD/$OUT" \
  swift test --filter DEEPSEEK_liveSmoke
test -s "$OUT" || { echo "ERROR: the cassette was not written to $OUT"; exit 1; }
if grep -Eiq "authorization|bearer|api_key|sk-[a-z0-9]{8,}" "$OUT"; then
  echo "ERROR: the cassette contains secret-like text; refusing"; exit 1
fi
echo "cassette written to $OUT (sanitized: no headers, credential excluded)"
