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
# How long a chunk may stay alive after printing its final summary.
LINGER_GRACE="${LINGXI_CI_LINGER_GRACE:-15}"
# When set, every chunk also writes an xunit report into this directory so the CI
# artifact keeps working even though the suite no longer runs as one invocation.
XUNIT_DIR="${LINGXI_CI_XUNIT_DIR:-}"
# Reports are copied here as they finish and this is what the CI uploads.
ARTIFACT_DIR="${XUNIT_DIR:+${XUNIT_DIR%/}-artifact}"

# Suites listed here run alone. ProviderRateSchedulerTests needs this: its concurrency
# assertion depends on two gateway streams overlapping, and sharing a process with the VCR
# full-stack suites makes that ordering neighbour-dependent (it fails in ~75ms, not by timeout).
ISOLATE_SUITES="${LINGXI_CI_ISOLATE_SUITES:-ProviderRateSchedulerTests}"

SWIFT_TEST=(swift test --skip-build)
# A chunk killed by the watchdog loses its entire block-buffered stdout, which is why a hang
# reports "0 bytes" and nothing can say which test was in flight. Where stdbuf is available the
# child is line-buffered so the log survives the kill; where it is not, run unchanged rather than
# preloading anything into the test process.
line_buffered=()
command -v stdbuf >/dev/null 2>&1 && line_buffered=(stdbuf -oL)
script_start=$(date +%s)

if ! raw_list="$("${SWIFT_TEST[@]}" --list-tests < /dev/null 2>/dev/null)"; then
  echo "error: swift test --list-tests failed"
  exit 1
fi

# swift-testing can mirror its own events into a file as they happen, which survives a watchdog
# kill that destroys the child's block-buffered console output. Ask the installed toolchain
# whether it accepts the option; --help does not list it, so the only real answer is to use it.
event_flag=()
event_probe="$(mktemp)"
if "${SWIFT_TEST[@]}" --list-tests --event-stream-output-path "$event_probe" < /dev/null > /dev/null 2>&1; then
  event_flag=(--event-stream-output-path)
fi
rm -f "$event_probe"

# Keep only the suite portion of Target.Suite/test; some entries carry () suffixes.
suite_counts="$(
  printf '%s\n' "$raw_list" \
    | sed -E 's#/[^/]*$##' \
    | sort | uniq -c | sort -rn
)"

total_tests=$(printf '%s\n' "$raw_list" | grep -c .)
total_suites=$(printf '%s\n' "$suite_counts" | grep -c .)
# swift-testing reports only its own cases: the XCTest ones are discovered above, do run, and
# appear in neither the per-chunk summary nor the xunit report. Reconcile against them by name,
# taken from the classes themselves so a new XCTestCase is counted without editing this.
xctest_suites="$(grep -rhoE 'class +[A-Za-z0-9_]+ *:[[:space:]]*XCTestCase' Tests 2>/dev/null | sed -E 's/class +([A-Za-z0-9_]+) *:.*/\1/' | paste -sd'|' -)"
xctest_cases=0
if [ -n "$xctest_suites" ]; then
  xctest_cases="$(printf '%s\n' "$raw_list" | grep -cE "^LingXiAgentTests\.(${xctest_suites})/" || true)"
fi
echo "Discovered ${total_tests} tests across ${total_suites} suites (${xctest_cases} of them XCTest)."
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
      # $! from Git Bash is an MSYS pid, and taskkill speaks Win32 pids: passing the MSYS one
      # either misses the process entirely or hits an unrelated one that reused the number. The
      # previous chunks' process listing is the proof - ps -W prints the MSYS pid first and the
      # Win32 pid fourth - so resolve through that table before killing. A missed kill leaves an
      # orphaned swift-test holding .build and the chunk's report file, which is how one timeout
      # turns into the next several.
      win_pid="$(ps -W 2>/dev/null | awk -v p="$pid" '$1 == p { print $4; exit }')"
      if [ -n "$win_pid" ]; then
        # The doubled slashes stop MSYS from rewriting the switches into paths.
        taskkill //F //T //PID "$win_pid" > /dev/null 2>&1
      else
        taskkill //F //T //PID "$pid" > /dev/null 2>&1 \
          || taskkill /F /T /PID "$pid" > /dev/null 2>&1
      fi
      ;;
    *)
      pkill -9 -f "LingXiAgentTests" 2>/dev/null
      ;;
  esac
  kill -9 "$pid" 2>/dev/null
}

# The event stream is the same information in machine form and, unlike the console, it is written
# per event to its own file, so a chunk that is killed still says which case it was inside. The
# console glyphs it would otherwise be parsed from are also exactly what a Windows log mangles.
unreported_from_events() {
  local events=$1
  [ -s "$events" ] || return 0
  comm -23 \
    <(grep -a '"kind":"testStarted"' "$events" 2>/dev/null | sed -E 's/.*"testID":"([^"]*)".*/\1/' | grep -a '/' | sort -u) \
    <(grep -a '"kind":"testEnded"' "$events" 2>/dev/null | sed -E 's/.*"testID":"([^"]*)".*/\1/' | sort -u) \
    | paste -sd'|' - | sed 's/|/, /g'
}

# A test that vanishes mid-run leaves no result line, which is how a Windows crash shows up in
# these logs: everything before it passed and the run simply stops. Name the started-but-never
# reported cases so the failing chunk points at the test that died instead of at exit code 1.
unreported_tests() {
  local log=$1
  comm -23 \
    <(grep -aoE '◊ Test .* started\.' "$log" 2>/dev/null \
        | sed -E 's/^◊ Test //; s/ started\.$//; s/^"//; s/"$//' | grep -av '^run$' | sort -u) \
    <(grep -aoE '[√×✘] Test .*(passed|failed|recorded an issue)' "$log" 2>/dev/null \
        | sed -E 's/^[√×✘] Test //; s/ (passed|failed|recorded).*//; s/^"//; s/"$//' | sort -u) \
    | paste -sd'|' - | sed 's/|/, /g'
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
      # child is wedged; the /proc walk below would silently produce nothing there. The test
      # binary is named after the *package*, so match that too or a live child reads as absent.
      echo "note: stack capture is unavailable on Windows runners; listing processes"
      ps -W 2>/dev/null | grep -iE "LingXiAgent|PackageTests|xctest|swift|rg\.exe" | head -30
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
lingering_chunks=()

# A chunk can also die without ever printing a verdict. Because a redirected stdout on Windows is
# block-buffered, the whole tail is lost with the process, so the log shows passing tests and then
# nothing at all. The Application event log is written by the kernel outside that process, so the
# faulting module and exception code survive there, and a process census says whether a previously
# killed chunk left children holding the test binary.
dump_crash_evidence() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      echo "live test processes now: $(ps -W 2>/dev/null | grep -icE 'swift-test|LingXiAgent' || echo 0)"
      powershell -NoProfile -Command 'Get-WinEvent -FilterHashtable @{LogName="Application"; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue | Where-Object { $_.Provider.Name -match "Application Error|Windows Error Reporting|\.NET Runtime" } | Select-Object -First 5 TimeCreated, ProviderName, Message | Format-List' 2>/dev/null \
        | tr -d '\r' | head -40 \
        || echo "note: no crash event was logged, so the test binary exited under its own power"
      ;;
  esac
}

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
  chunk_events="$(mktemp)"
  run_args=("${SWIFT_TEST[@]}" --filter "$filter")
  if [ -n "$XUNIT_DIR" ]; then
    mkdir -p "$XUNIT_DIR"
    run_args+=(--xunit-output "$XUNIT_DIR/test-results-chunk-$index.xml")
  fi
  # Probed rather than assumed: the flag is not in `swift test --help`, and passing one the
  # installed toolchain does not know would fail every chunk in the stage.
  if [ "${#event_flag[@]}" -gt 0 ]; then
    run_args+=(--event-stream-output-path "$chunk_events")
  fi
  # /dev/null on stdin is mandatory, not cosmetic: the stdio transport tests spawn a child
  # that waits for EOF, and under Actions it would otherwise inherit a runner pipe that never
  # closes (the same deadlock < /dev/null was added for in the other stages).
  ${line_buffered[@]+"${line_buffered[@]}"} "${run_args[@]}" < /dev/null > "$chunk_log" 2>&1 &
  runner=$!
  chunk_start=$(date +%s)

  waited=0
  alive=yes
  lingering=no
  done_at=-1
  while kill -0 "$runner" 2>/dev/null; do
    if [ "$waited" -ge "$CHUNK_TIMEOUT" ]; then
      alive=no
      echo "!! Chunk ${index} exceeded ${CHUNK_TIMEOUT}s. Capturing stacks then killing."
      # "Hung" and "only slow" look identical from the exit status, and the difference decides
      # whether to chase a deadlock or raise the budget, so state what the log actually holds:
      # zero bytes with no start marker means the test binary never produced anything at all.
      echo "-- diagnosis: log $(wc -c < "$chunk_log" 2>/dev/null || echo 0) bytes," \
        "$(grep -ac '"kind":"testStarted"' "$chunk_events" 2>/dev/null) started," \
        "$(grep -ac '"kind":"testEnded"' "$chunk_events" 2>/dev/null) finished (event stream)"
      dump_stacks "$runner"
      # The runner is a wrapper; the real test processes are its descendants.
      for child in $(pgrep -P "$runner" 2>/dev/null); do
        dump_stacks "$child"
      done
      kill_tree "$runner"
      sleep 2
      break
    fi
    # Some suites leave a blocking read or an un-joined task behind, so the process prints its
    # final summary and then sits until the watchdog fires: the whole budget burnt, and results
    # already on disk discarded. Harvest them and stop instead.
    if [ "$done_at" -lt 0 ] && grep -qE 'Test run with [0-9]+ tests' "$chunk_log" 2>/dev/null; then
      done_at=$waited
    fi
    if [ "$done_at" -ge 0 ] && [ $((waited - done_at)) -ge "$LINGER_GRACE" ]; then
      lingering=yes
      echo "!! Chunk ${index} completed its run but the process did not exit; harvesting and killing."
      kill_tree "$runner"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$runner" 2>/dev/null
  status=$?
  elapsed=$(( $(date +%s) - chunk_start ))

  # swift-testing exits 0 when a filter matches nothing, so a chunk that silently runs
  # zero tests would otherwise be reported as a pass. Count what actually ran.
  ran="$(grep -oE 'Test run with [0-9]+ test' "$chunk_log" | tail -1 | grep -oE '[0-9]+' || true)"
  ran="${ran:-0}"
  executed=$((executed + ran))

  if [ "$alive" = no ]; then
    timed_out_chunks+=("Chunk ${index}: ${names}")
    victim="$(unreported_from_events "$chunk_events")"
    [ -z "$victim" ] && victim="$(unreported_tests "$chunk_log")"
    [ -n "$victim" ] && echo "-- started but never reported: ${victim}"
    tail -20 "$chunk_log"
    [ "$ran" -eq 0 ] && dump_crash_evidence
  elif [ "$lingering" = yes ]; then
    # A distinct defect from a hung test: the plan finished, so its verdict is trustworthy,
    # but the process never returned. Report both so neither signal is lost.
    lingering_chunks+=("Chunk ${index}: ${names}")
    grep -E 'Test run with [0-9]+ tests' "$chunk_log" | tail -1
    if grep -qE 'Test run with [0-9]+ tests failed' "$chunk_log"; then
      failed_chunks+=("Chunk ${index}: ${names}")
      grep -E "recorded an issue|Expectation failed|Caught error|error:" "$chunk_log" | head -30
    fi
  elif [ "$status" -ne 0 ]; then
    failed_chunks+=("Chunk ${index}: ${names}")
    echo "-- chunk ${index} exit ${status} after ${elapsed}s --"
    silent_victim="$(unreported_from_events "$chunk_events")"
    [ -z "$silent_victim" ] && silent_victim="$(unreported_tests "$chunk_log")"
    [ -n "$silent_victim" ] && echo "!! chunk ${index} started but never reported: ${silent_victim}"
    # No summary at all means the run never reached its own end, which is a different defect from
    # a test that failed and was reported, so say which one this is and bring in the OS evidence.
    [ "$ran" -eq 0 ] && dump_crash_evidence
    grep -E "recorded an issue|Expectation failed|Caught error|error:|Test run with" "$chunk_log" \
      | head -30
    echo "--- chunk ${index} full log ---"
    cat "$chunk_log"
  elif [ "$ran" -eq 0 ]; then
    failed_chunks+=("Chunk ${index} matched no tests: ${names}")
    echo "!! Chunk ${index} ran 0 tests. Filter was: ${filter}"
    tail -20 "$chunk_log"
  else
    printf 'ok  chunk %-3s %4ss  %s tests\n' "$index" "$elapsed" "$ran"
  fi
  if [ -n "$XUNIT_DIR" ]; then
    # swift-testing appends its own suffix to --xunit-output, so the report is named after the
    # chunk rather than exactly as asked for; stage whatever name it actually wrote.
    for report in "$XUNIT_DIR"/test-results-chunk-"$index"*.xml; do
      [ -f "$report" ] || continue
      mkdir -p "$ARTIFACT_DIR"
      cp "$report" "$ARTIFACT_DIR/" 2>/dev/null \
        || echo "note: could not stage chunk ${index}'s report"
    done
  fi
  rm -f "$chunk_log" "$chunk_events"
  echo "::endgroup::"
done

echo
# A chunk matching nothing is already a hard failure above; this aggregate is a cross-check
# against the swift-testing-visible population, since XCTest cases report through neither.
if [ "$((executed + xctest_cases))" -lt "$total_tests" ]; then
  echo "::warning::$((executed + xctest_cases)) tests executed vs ${total_tests} discovered (${executed} swift-testing + ${xctest_cases} XCTest); review per-chunk counts for a suite that ran nothing"
fi
echo "================ Stage 5 summary ================"
echo "wall time:        $(( $(date +%s) - script_start ))s"
echo "chunks run:       ${#chunks[@]}"
echo "tests executed:   ${executed} swift-testing + ${xctest_cases} XCTest / ${total_tests} discovered"
echo "failures:         ${#failed_chunks[@]}"
echo "timeouts (hang):  ${#timed_out_chunks[@]}"
echo "lingering:        ${#lingering_chunks[@]}  (run finished, process would not exit)"
for entry in ${failed_chunks[@]+"${failed_chunks[@]}"}; do echo "  FAILED  $entry"; done
for entry in ${timed_out_chunks[@]+"${timed_out_chunks[@]}"}; do echo "  HUNG    $entry"; done
for entry in ${lingering_chunks[@]+"${lingering_chunks[@]}"}; do echo "  LINGERED  $entry"; done

if [ "${#failed_chunks[@]}" -gt 0 ] || [ "${#timed_out_chunks[@]}" -gt 0 ] \
   || [ "${#lingering_chunks[@]}" -gt 0 ]; then
  exit 1
fi
echo "All chunks passed."
