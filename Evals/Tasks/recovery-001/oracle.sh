#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify Provider rate and retry test suite passes
swift test --filter ProviderRateSchedulerTests > /dev/null 2>&1
exit 0
