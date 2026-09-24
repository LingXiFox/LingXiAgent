#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify Migration tests pass
swift test --filter PersistenceTests > /dev/null 2>&1
exit 0
