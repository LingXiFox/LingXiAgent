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
LOG="serve-smoke-$PORT.log"

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
  LOG="serve-smoke-$PORT.log"
  "$BIN_PATH/lingxiagent$EXE" serve --no-browser --port "$PORT" > "$LOG" 2>&1 &
  pid=$!

  ready=0
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi          # it died on the way up
    if probe "http://127.0.0.1:$PORT/api/state"; then
      ready=1
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
  if pgrep -f "LingXiCoreHost$EXE" >/dev/null 2>&1; then
    echo "::error::a CoreHost child outlived serve"
    pgrep -fal "LingXiCoreHost$EXE" || true
    exit 1
  fi
fi

rm -f serve-smoke-*.log
echo "serve smoke passed"
