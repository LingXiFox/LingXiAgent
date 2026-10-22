#!/bin/zsh
# Records a real MiMo Responses cassette. Requires MIMO_API_KEY in the environment.
#
#   Scripts/mimo-record-responses.sh [output.json]
#
# The recording exercises the same smoke scenarios as the Chat recorder, but with
# protocolKind=responses and an explicit reasoning effort so the digest separates it from
# every Chat exchange.
set -euo pipefail
: "${MIMO_API_KEY:?MIMO_API_KEY must be set in this shell}"
cd "$(dirname "$0")/.."
OUT="${1:-ContractTests/Fixtures/mimo-responses-live.json}"
swift build --build-tests
LINGXI_RUN_REAL_PROVIDER_SMOKE=1 \
LINGXI_MIMO_PROTOCOL=responses \
LINGXI_MIMO_REASONING_EFFORT="${LINGXI_MIMO_REASONING_EFFORT:-medium}" \
LINGXI_RECORD_MIMO_CASSETTE="$PWD/$OUT" \
  swift test --filter MIMO_liveSmoke
test -s "$OUT" || { echo "ERROR: the cassette was not written to $OUT"; exit 1; }
if grep -Eiq "authorization|bearer|api_key|sk-[a-z0-9]{8,}" "$OUT"; then
  echo "ERROR: the cassette contains secret-like text; refusing"; exit 1
fi
echo "Responses cassette written to $OUT (sanitized: no headers, credential excluded)"
