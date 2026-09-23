#!/usr/bin/env zsh
set -euo pipefail

# Scripts/license-matrix.zsh
# Validates or updates LICENSE-MATRIX.md against Package.swift targets.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_FILE="$REPO_ROOT/Package.swift"
MATRIX_FILE="$REPO_ROOT/LICENSE-MATRIX.md"

if [[ ! -f "$PACKAGE_FILE" || ! -f "$MATRIX_FILE" ]]; then
    echo "[-] Required files not found in $REPO_ROOT" >&2
    exit 1
fi

# Extract target names from Package.swift
package_targets=($(perl -0777 -ne 'while (/\.(?:executableTarget|testTarget|target|systemLibrary|plugin)\(\s*(?:\/\*[^*]*\*\/\s*)*name:\s*"([^"]+)"/g) { print "$1\n"; }' "$PACKAGE_FILE" | sort -u))

# Extract target names from LICENSE-MATRIX.md under ## SPM targets
matrix_targets=($(perl -ne 'if (/^## SPM targets/) { $in=1; next } if ($in && /^## /) { last } if ($in && /^\|\s*`([^`]+)`\s*\|/) { print "$1\n" unless $1 =~ /Target/i }' "$MATRIX_FILE" | sort -u))

echo "[*] Found ${#package_targets[@]} targets in Package.swift"
echo "[*] Found ${#matrix_targets[@]} targets in LICENSE-MATRIX.md"

missing=()
for t in "${package_targets[@]}"; do
    if [[ ! " ${matrix_targets[*]} " =~ " ${t} " ]]; then
        missing+=("$t")
    fi
done

stale=()
for m in "${matrix_targets[@]}"; do
    if [[ ! " ${package_targets[*]} " =~ " ${m} " ]]; then
        stale+=("$m")
    fi
done

has_error=0
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[-] ERROR: Targets defined in Package.swift but missing in LICENSE-MATRIX.md:" >&2
    for t in "${missing[@]}"; do
        echo "    + $t" >&2
    done
    has_error=1
fi

if [[ ${#stale[@]} -gt 0 ]]; then
    echo "[-] ERROR: Targets defined in LICENSE-MATRIX.md but absent in Package.swift:" >&2
    for s in "${stale[@]}"; do
        echo "    - $s" >&2
    done
    has_error=1
fi

if [[ $has_error -eq 1 ]]; then
    echo "[-] License matrix check FAILED. Please update LICENSE-MATRIX.md." >&2
    exit 1
fi

echo "[+] License matrix is in sync with Package.swift (${#package_targets[@]} targets verified)."
exit 0
