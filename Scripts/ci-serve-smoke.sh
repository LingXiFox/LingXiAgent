#!/usr/bin/env bash
# ==============================================================================
#  Release smoke for `lingxiagent serve` (all three gates run this same script)
#
#  The shipped binary has to boot the real Core, answer over loopback, serve its
#  own static assets, and stop on a termination request without leaving a CoreHost
#  child behind. Anything short of that is a release defect, not a dev-machine detail.
# ==============================================================================
set -euo pipefail

BIN_PATH="${1:?usage: ci-serve-smoke.sh <swift-bin-path> [exe-suffix]}"
EXE="${2-}"
PORT=$(( (RANDOM % 20000) + 20000 ))
# Logs go to a scratch directory, never the working tree: the Linux gate runs Stage 6 as an
# unprivileged user against a root-owned workspace, and a failed redirect there looks exactly like
# "serve did not answer" -- which is what it reported, with the child never even starting.
WORK_DIR="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/lingxi-serve-smoke-$$")"
mkdir -p "$WORK_DIR" 2>/dev/null || { echo "::error::cannot create a scratch directory ($WORK_DIR)"; exit 1; }
LOG="$WORK_DIR/serve.log"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

attempt=0
# The Linux gate runs inside a slim container where curl is not guaranteed. Probing with a
# missing client looks exactly like a server that never binds, so say which tool answered the
# call -- or that nothing could -- before blaming the server.
probe() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -H 'X-LingXi-Client: ci' "$url" -o /dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" <<'PY'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"X-LingXi-Client": "ci"})
sys.exit(0 if urllib.request.urlopen(req, timeout=3).status == 200 else 1)
PY
  else
    echo "::error::no HTTP client (curl or python3) is available to probe serve" >&2
    return 2
  fi
}

for candidate in "$PORT" $(( (RANDOM % 20000) + 20000 )) $(( (RANDOM % 20000) + 20000 )); do
  attempt=$((attempt + 1))
  PORT="$candidate"
  "$BIN_PATH/lingxiagent$EXE" serve --no-browser --port "$PORT" > "$LOG" 2>&1 &
  pid=$!

  ready=0
  # Bounded by elapsed seconds only. `kill -0 $pid` is not a liveness test that works here: under
  # Git Bash the pid of a Windows .exe launched in the background is not always the process that is
  # answering, so a failed `kill -0` ended this loop on the first probe and reported a server that
  # was perfectly healthy -- Windows `serve` binds ~5s after start, and every attempt was being cut
  # short at t<2s. Slowness is now measured and printed rather than mistaken for death.
  started_at=$(date +%s)
  while [ $(( $(date +%s) - started_at )) -lt 45 ]; do
    if probe "http://127.0.0.1:$PORT/api/state"; then
      ready=1
      echo "serve answered on port $PORT after $(( $(date +%s) - started_at ))s"
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] && break

  # A Windows runner reserves whole dynamic-port ranges for Hyper-V, so one refused bind proves
  # nothing: retry elsewhere before concluding the server is broken.
  alive=yes
  kill -0 "$pid" 2>/dev/null || alive=no
  echo "-- attempt $attempt on port $PORT did not answer; process alive: $alive; $(command -v curl >/dev/null 2>&1 && echo 'probe: curl' || (command -v python3 >/dev/null 2>&1 && echo 'probe: python3' || echo 'probe: NONE'))"
  kill -TERM "$pid" 2>/dev/null || true
  # Stop first, then print: a live process has not flushed its redirected output, which is why an
  # earlier failure looked like an empty log rather than a bind refusal.
  wait "$pid" 2>/dev/null || true
  echo "-- serve output (attempt $attempt, $(wc -c < "$LOG" 2>/dev/null || echo 0) bytes) --"
  cat "$LOG" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    echo "::error::serve ignored the termination request on port $PORT"
    exit 1
  fi
done

if [ "${ready:-0}" != 1 ]; then
  echo "::error::serve did not answer on any of the tried ports (last: 127.0.0.1:$PORT)"
  exit 1
fi

# The asset path is what makes the WebUI usable without a dev server: index plus the
# state endpoint, both from the packaged binary.
probe "http://127.0.0.1:$PORT/"
probe "http://127.0.0.1:$PORT/js/state.js"

# LINGXI_EXPECTED_ASSET_MARKER is set by the packaged-artifact smoke after it has stamped a
# marker into the extracted copy of an asset. Requiring the marker in the response is what
# separates "the package serves its own assets" from "the binary found the build tree it was
# compiled in" -- the second one works on every CI runner and on no user's machine.
if [ -n "${LINGXI_EXPECTED_ASSET_MARKER:-}" ]; then
  body=""
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsS -H 'X-LingXi-Client: ci' "http://127.0.0.1:$PORT/js/state.js" 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    body="$(python3 -c 'import sys,urllib.request;req=urllib.request.Request(sys.argv[1],headers={"X-LingXi-Client":"ci"});print(urllib.request.urlopen(req,timeout=5).read().decode("utf-8","replace"))' "http://127.0.0.1:$PORT/js/state.js" 2>/dev/null || true)"
  fi
  case "$body" in
    *"$LINGXI_EXPECTED_ASSET_MARKER"*)
      echo "the served assets are the ones inside this package" ;;
    *)
      echo "::error::serve answered without the marker stamped into the packaged asset: the bytes came from outside this package"
      exit 1 ;;
  esac
fi
echo "serve answered on port $PORT and served its assets"

kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 10); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$pid" 2>/dev/null; then
  echo "::error::serve ignored the termination request; the CoreHost child would be orphaned"
  exit 1
fi

if command -v pgrep >/dev/null 2>&1; then
  # `-x` matches the process *name*; `-f` searches command lines, which also hits any shell whose
  # argv merely mentions LingXiCoreHost -- the build command that produced it, the ssh line that
  # carried this script. That reads exactly like an orphan that never existed.
  if pgrep -x "LingXiCoreHost$EXE" >/dev/null 2>&1; then
    echo "::error::a CoreHost child outlived serve"
    pgrep -xl "LingXiCoreHost$EXE" || true
    exit 1
  fi
fi

echo "serve smoke passed"
