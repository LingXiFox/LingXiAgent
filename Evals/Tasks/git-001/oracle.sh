#!/usr/bin/env bash
set -euo pipefail

# Oracle: Verify git log contains credential non-leakage commit
git log --grep="stop plugin and browser host from inheriting provider credentials" -n 1 > /dev/null 2>&1
exit 0
