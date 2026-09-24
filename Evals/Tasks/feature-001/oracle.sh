#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify ProtocolFeature and RuntimeCapabilities test passes
swift test --filter ProtocolVersionContractTests > /dev/null 2>&1
exit 0
