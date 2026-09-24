#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify configuration store unit tests pass
swift test --filter ConfigurationStoreTests > /dev/null 2>&1
exit 0
