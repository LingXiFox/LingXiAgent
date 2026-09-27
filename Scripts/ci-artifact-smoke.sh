#!/usr/bin/env bash
# ==============================================================================
#  Packaged-artifact smoke (goal §9): run what the release actually ships
#
#  A source-tree build proves the code compiles; it does not prove the archive
#  contains a self-contained product. This extracts a release artifact the way a
#  user would and runs the entry points from there, so a missing bundle, a lost
#  executable bit, or a CoreHost that is only findable because the build tree
#  happens to sit next to it shows up as a failed gate instead of an install
#  report.
#
#  usage: ci-artifact-smoke.sh <archive> [exe-suffix]
# ==============================================================================
set -uo pipefail

ARCHIVE="${1:?usage: ci-artifact-smoke.sh <archive> [exe-suffix]}"
EXE="${2-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/lingxi-artifact-smoke-$$")"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0
check() { # <label> <command...>
  local label="$1"; shift
  if "$@" </dev/null >"$WORK_DIR/check.log" 2>&1; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    sed -n '1,8p' "$WORK_DIR/check.log" | sed 's/^/       /'
    failures=$((failures + 1))
  fi
}

echo "== extracting $(basename "$ARCHIVE") =="
case "$ARCHIVE" in
  *.zip)
    command -v unzip >/dev/null 2>&1 || { echo "::error::unzip is required for a .zip artifact"; exit 1; }
    unzip -q "$ARCHIVE" -d "$WORK_DIR/root" ;;
  *.tar.gz|*.tgz)
    tar -xzf "$ARCHIVE" -C "$WORK_DIR" 2>"$WORK_DIR/tar.err" || { cat "$WORK_DIR/tar.err"; exit 1; } ;;
  *) echo "::error::unsupported artifact type: $ARCHIVE"; exit 1 ;;
esac
# The zip keeps a top-level folder, the tarballs are built with `-C staging .`, so the
# payload sits at the root. Try both before concluding the archive is wrong.
ROOT="$WORK_DIR/root"
[ -e "$ROOT/lingxiagent$EXE" ] || ROOT="$WORK_DIR"
if [ ! -e "$ROOT/lingxiagent$EXE" ]; then
  for candidate in "$WORK_DIR"/*/; do
    [ -e "$candidate/lingxiagent$EXE" ] && ROOT="${candidate%/}" && break
  done
fi
if [ ! -e "$ROOT/lingxiagent$EXE" ]; then
  echo "::error::no lingxiagent$EXE in the extracted artifact: $(ls "$WORK_DIR" | tr '\n' ' ')"
  exit 1
fi
BIN="$ROOT/lingxiagent$EXE"

echo "== entry points present and runnable =="
# The package ships three user-facing entry points; lingxiagent-ops is an internal helper and is
# not in every archive, so its absence is reported rather than failed.
for name in lingxiagent LingXiCoreHost LingXiTUI; do
  if [ ! -e "$ROOT/$name$EXE" ]; then
    echo "FAIL $name$EXE is missing from the artifact"
    failures=$((failures + 1))
  fi
done
[ -e "$ROOT/lingxiagent-ops$EXE" ] || echo "note: lingxiagent-ops$EXE is not in this artifact"
check "lingxiagent --version"     "$BIN" --version
check "lingxiagent --help"        "$BIN" --help
[ -e "$ROOT/LingXiTUI$EXE" ] && check "LingXiTUI --help" "$ROOT/LingXiTUI$EXE" --help
[ -e "$ROOT/lingxiagent-ops$EXE" ] && check "lingxiagent-ops --smoke" "$ROOT/lingxiagent-ops$EXE" --smoke

if [ "${OS-}" != "Windows_NT" ]; then
  # An archive built on a filesystem without the exec bit, or a `tar` that dropped it,
  # installs a product that cannot start. The Windows zip carries no mode at all.
  for name in lingxiagent LingXiCoreHost LingXiTUI; do
    if [ -e "$ROOT/$name$EXE" ] && [ ! -x "$ROOT/$name$EXE" ]; then
      echo "FAIL $name$EXE lost its executable bit"
      failures=$((failures + 1))
    fi
  done
fi

echo "== resources =="
# CoreHost is found by sibling lookup, and the WebUI assets come from the resource
# bundle: both resolve differently in a build tree than in a flat release folder,
# which is the whole reason this stage exists.
if ! find "$ROOT" -name 'index.html' -print -quit | grep -q .; then
  echo "FAIL no WebUI assets (index.html) in the artifact"
  failures=$((failures + 1))
else
  echo "ok   WebUI assets present"
fi

echo "== serve from the extracted artifact =="
# Same probe as the per-platform Stage 6: bind loopback, answer over HTTP, serve an
# asset, and leave no CoreHost child behind.
if bash "$SCRIPT_DIR/ci-serve-smoke.sh" "$ROOT" "$EXE" </dev/null; then
  echo "ok   serve smoke from packaged artifact"
else
  echo "FAIL serve smoke from packaged artifact"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures packaged-artifact check(s) failed"
  exit 1
fi
echo "Packaged artifact smoke passed."
