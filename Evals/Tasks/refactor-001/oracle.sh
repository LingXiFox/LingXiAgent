#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify session behavioral tests pass
swift test --filter AgentSessionTests > /dev/null 2>&1
exit 0
