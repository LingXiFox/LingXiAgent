#!/usr/bin/env bash
# ==============================================================================
#  🦊 LingXiAgent Integration Test Runner (CI Stage 5)
#
#  swift-testing launches every discovered test case in a process at once, which
#  starves the cooperative thread pool until background work stops being scheduled
#  entirely. On CI runners that manifests as a total hang, so the full-suite run is
#  split into bounded chunks and each chunk gets its own watchdog.
#
#  Every chunk reports, so a single CI pass maps all hanging chunks at once instead
#  of exposing one per iteration.
# ==============================================================================

set -uo pipefail

# Measured: in-process concurrency is what breaks these tests, not wall-clock speed.
# 60 per chunk still reproduces the interference; 12 is deterministic locally. CI runners
# have fewer cores, so the same chunk size is more contended there, not less.
CHUNK_SIZE="${LINGXI_CI_CHUNK_SIZE:-12}"
CHUNK_TIMEOUT="${LINGXI_CI_CHUNK_TIMEOUT:-150}"
# When set, every chunk also writes an xunit report into this directory so the CI
# artifact keeps working even though the suite no longer runs as one invocation.
XUNIT_DIR="${LINGXI_CI_XUNIT_DIR:-}"

# Suites listed here run alone. ProviderRateSchedulerTests needs this: its concurrency
# assertion depends on two gateway streams overlapping, and sharing a process with the VCR
# full-stack suites makes that ordering neighbour-dependent (it fails in ~75ms, not by timeout).
ISOLATE_SUITES="${LINGXI_CI_ISOLATE_SUITES:-ProviderRateSchedulerTests}"

SWIFT_TEST=(swift test --skip-build)
script_start=$(date +%s)

if ! raw_list="$("${SWIFT_TEST[@]}" --list-tests < /dev/null 2>/dev/null)"; then
  echo "error: swift test --list-tests failed"
  exit 1
fi

# Keep only the suite portion of Target.Suite/test; some entries carry () suffixes.
suite_counts="$(
  printf '%s\n' "$raw_list" \
    | sed -E 's#/[^/]*$##' \
    | sort | uniq -c | sort -rn
)"

total_tests=$(printf '%s\n' "$raw_list" | grep -c .)
total_suites=$(printf '%s\n' "$suite_counts" | grep -c .)
echo "Discovered ${total_tests} tests across ${total_suites} suites."
echo "Chunk size ${CHUNK_SIZE}, per-chunk timeout ${CHUNK_TIMEOUT}s."

escape_regex() {
  printf '%s\n' "$1" | sed -E 's/[][\.()*+?{}|^$]/\\&/g'
}

chunks=()
buffer=""
buffer_count=0

should_isolate() {
  local name="$1" entry
  local short="${name##*.}"
  for entry in ${ISOLATE_SUITES//,/ }; do
    [ "$short" = "$entry" ] && return 0
  done
  return 1
}

while read -r count suite; do
  [ -z "${suite:-}" ] && continue
  if should_isolate "$suite"; then
    chunks+=("$suite")
    continue
  fi
  if [ -z "$buffer" ]; then
    buffer="$suite"
  else
    buffer="$buffer"$'\n'"$suite"
  fi
  buffer_count=$((buffer_count + count))
  if [ "$buffer_count" -ge "$CHUNK_SIZE" ]; then
    chunks+=("$buffer")
    buffer=""
    buffer_count=0
  fi
done <<< "$suite_counts"
if [ -n "$buffer" ]; then
  chunks+=("$buffer")
fi
if [ "${#chunks[@]}" -eq 0 ]; then
  echo "error: no tests discovered, refusing to report success"
  exit 1
fi
echo "Planned ${#chunks[@]} chunks."

kill_tree() {
  local pid=$1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      # Git Bash kill() does not reach the Win32 children of the runner, and pkill may not
      # exist there at all. taskkill /T walks the process tree; the doubled slashes stop MSYS
      # from rewriting the switches into paths.
      taskkill //F //T //PID "$pid" > /dev/null 2>&1 \
        || taskkill /F /T /PID "$pid" > /dev/null 2>&1
      ;;
    *)
      pkill -9 -f "LingXiAgentTests" 2>/dev/null
      ;;
  esac
  kill -9 "$pid" 2>/dev/null
}

dump_stacks() {
  local pid=$1
  case "$(uname -s)" in
    Darwin)
      # Keep the deep frames: the leaf call is the whole point of capturing this.
      sample "$pid" 2 -mayDie 2>/dev/null \
        | awk '/^[[:space:]]*[0-9]+ Thread_/{p=1} p{print}' \
        | sed -E 's/ \(in [^)]*\)//; s/ \+ [0-9]+$//; s/^[[:space:]]+//' \
        | head -200
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      # No portable userspace stack dumper exists on Git Bash, so record the process tree
      # instead. Combined with the chunk name in the line above, that still identifies which
      # child is wedged; the /proc walk below would silently produce nothing there.
      echo "note: stack capture is unavailable on Windows runners; listing processes"
      ps -W 2>/dev/null | grep -iE "LingXiAgentTests|swift|rg\.exe" | head -30
      ;;
    *)
      local t
      for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        printf 'thread %s wchan=%s state=%s\n' \
          "$(basename "$t")" \
          "$(cat "$t/wchan" 2>/dev/null || echo '?')" \
          "$(awk '{print $3}' "$t/stat" 2>/dev/null || echo '?')"
      done | head -40
      ;;
  esac
}

failed_chunks=()
timed_out_chunks=()
executed=0
index=0
for chunk in "${chunks[@]}"; do
  index=$((index + 1))
  # Trailing "/" pins a suite exactly: matching is a regex search, so without it
  # "FooTests" would also swallow "FooTestsExtra".
  filter="$(
    printf '%s\n' "$chunk" | while read -r suite; do
      [ -n "$suite" ] && escape_regex "${suite}/"
    done | paste -sd'|' -
  )"
  names="$(printf '%s\n' "$chunk" | sed -E 's/^LingXiAgentTests\.//' | paste -sd' ' -)"
  echo "::group::Chunk ${index}/${#chunks[@]} :: ${names}"

  chunk_log="$(mktemp)"
  run_args=("${SWIFT_TEST[@]}" --filter "$filter")
  if [ -n "$XUNIT_DIR" ]; then
    mkdir -p "$XUNIT_DIR"
    run_args+=(--xunit-output "$XUNIT_DIR/test-results-chunk-$index.xml")
  fi
  # /dev/null on stdin is mandatory, not cosmetic: the stdio transport tests spawn a child
  # that waits for EOF, and under Actions it would otherwise inherit a runner pipe that never
  # closes (the same deadlock < /dev/null was added for in the other stages).
  "${run_args[@]}" < /dev/null > "$chunk_log" 2>&1 &
  runner=$!
  chunk_start=$(date +%s)

  waited=0
  alive=yes
  while kill -0 "$runner" 2>/dev/null; do
    if [ "$waited" -ge "$CHUNK_TIMEOUT" ]; then
      alive=no
      echo "!! Chunk ${index} exceeded ${CHUNK_TIMEOUT}s. Capturing stacks then killing."
      dump_stacks "$runner"
      # The runner is a wrapper; the real test processes are its descendants.
      for child in $(pgrep -P "$runner" 2>/dev/null); do
        dump_stacks "$child"
      done
      kill_tree "$runner"
      sleep 2
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  [ "$alive" = yes ] && wait "$runner"
  status=$?
  elapsed=$(( $(date +%s) - chunk_start ))

  # swift-testing exits 0 when a filter matches nothing, so a chunk that silently runs
  # zero tests would otherwise be reported as a pass. Count what actually ran.
  ran="$(grep -oE 'Test run with [0-9]+ test' "$chunk_log" | tail -1 | grep -oE '[0-9]+' || true)"
  ran="${ran:-0}"
  executed=$((executed + ran))

  if [ "$alive" = no ]; then
    timed_out_chunks+=("Chunk ${index}: ${names}")
    tail -20 "$chunk_log"
  elif [ "$status" -ne 0 ]; then
    failed_chunks+=("Chunk ${index}: ${names}")
    echo "-- chunk ${index} exit ${status} after ${elapsed}s --"
    grep -E "recorded an issue|Expectation failed|Caught error|error:|Test run with" "$chunk_log" \
      | head -30
  elif [ "$ran" -eq 0 ]; then
    failed_chunks+=("Chunk ${index} matched no tests: ${names}")
    echo "!! Chunk ${index} ran 0 tests. Filter was: ${filter}"
    tail -20 "$chunk_log"
  else
    printf 'ok  chunk %-3s %4ss  %s tests\n' "$index" "$elapsed" "$ran"
  fi
  rm -f "$chunk_log"
  echo "::endgroup::"
done

echo
# A chunk matching nothing is already a hard failure above; this aggregate is only a
# cross-check, and the two counters legitimately differ for parameterized cases.
if [ "$executed" -lt "$total_tests" ]; then
  echo "::warning::${executed} tests executed vs ${total_tests} discovered; review per-chunk counts for a suite that ran nothing"
fi
echo "================ Stage 5 summary ================"
echo "wall time:        $(( $(date +%s) - script_start ))s"
echo "chunks run:       ${#chunks[@]}"
echo "tests executed:   ${executed} / ${total_tests} discovered"
echo "failures:         ${#failed_chunks[@]}"
echo "timeouts (hang):  ${#timed_out_chunks[@]}"
for entry in ${failed_chunks[@]+"${failed_chunks[@]}"}; do echo "  FAILED  $entry"; done
for entry in ${timed_out_chunks[@]+"${timed_out_chunks[@]}"}; do echo "  HUNG    $entry"; done

if [ "${#failed_chunks[@]}" -gt 0 ] || [ "${#timed_out_chunks[@]}" -gt 0 ]; then
  exit 1
fi
echo "All chunks passed."
