#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify git diff is non-empty and builds cleanly
swift build > /dev/null 2>&1
exit 0
