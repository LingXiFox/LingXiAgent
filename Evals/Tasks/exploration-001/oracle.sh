#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify PlatformPipeHandle protocol conformance tests pass
swift test --filter PlatformConformanceHarness > /dev/null 2>&1
exit 0
