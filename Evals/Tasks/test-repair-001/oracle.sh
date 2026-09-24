#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify ProviderRateSchedulerTests pass
swift test --filter ProviderRateSchedulerTests > /dev/null 2>&1
exit 0
