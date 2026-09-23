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
# Budget for the single retry of a chunk the watchdog killed. Short on purpose: a chunk that
# needs it is either about to finish or is wedged for good, and the difference is the point.
RETRY_TIMEOUT="${LINGXI_CI_RETRY_TIMEOUT:-90}"
# Windows ships a timeout.exe with unrelated semantics, and Git Bash may resolve either one.
# Only bound the retry when the GNU behaviour is actually there, so a name clash costs a retry
# and never a failed stage.
if timeout --version >/dev/null 2>&1; then TIMEOUT_CMD=(timeout -k 5 "$RETRY_TIMEOUT"); else TIMEOUT_CMD=(); fi
# Convergence proof for the stdio/pipe family: N consecutive clean passes over exactly those suites,
# bounded per round so a hang names itself instead of eating the step timeout. Off by default; a
# workflow_dispatch input turns it on, because one green Stage 5 never proved stability -- Linux
# lost the same MCPCLITests case eight rounds running before poll() explained it.
STRESS_ROUNDS="${LINGXI_CI_STRESS_ROUNDS:-0}"
STRESS_ROUND_TIMEOUT="${LINGXI_CI_STRESS_ROUND_TIMEOUT:-300}"
STRESS_SUITES="MCPCLITests MCPRuntimeTests IPCPeerRobustnessTests NonProviderLatencyRepairTests PlatformBuildGateTests ToolRuntimeTests BackgroundCommandTests VNextProductionIntegrationTests LingXiClientVNextTests Round6SystemAuditTests Round14SystemAuditTests"
# When set, every chunk also writes an xunit report into this directory so the CI
# artifact keeps working even though the suite no longer runs as one invocation.
XUNIT_DIR="${LINGXI_CI_XUNIT_DIR:-}"
# Reports are copied here as they finish and this is what the CI uploads.
ARTIFACT_DIR="${XUNIT_DIR:+${XUNIT_DIR%/}-artifact}"

# Suites listed here run alone, for two different reasons.
#
# ProviderRateSchedulerTests needs it for correctness: its concurrency assertion depends on two
# gateway streams overlapping, and sharing a process with the VCR full-stack suites makes that
# ordering neighbour-dependent (it fails in ~75ms, not by timeout).
#
# The rest need it for attribution and containment. Each of them has been named by the event
# stream as the case in flight when a Windows chunk stopped reporting -- they spawn a child and
# read its pipes, and that teardown is where the open defects have lived. While one chunk dies it
# takes every other suite's results in that process with it, which is how twelve unrelated suites
# went unreported at a time. Running
# them alone cannot fix the defect, but it says which suite died and leaves the others to report.
ISOLATE_SUITES="${LINGXI_CI_ISOLATE_SUITES:-ProviderRateSchedulerTests LingXiClientVNextTests VNextProductionIntegrationTests ProtocolVNextFrozenContractTests Round6SystemAuditTests Round14SystemAuditTests AuthCLITests ResumeCLITests OAuthStrategyTests CodingToolScenarioTests AgentBehaviorTests ApplicationChangeSetTests ModelSelectionAndTurnExecutionFixTests}"

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
# A filter matching nothing still emits runStarted/runEnded, so this asks the two questions that
# actually matter: does the installed toolchain take the option, and can the test binary write the
# path it is given (Git Bash hands out /tmp names a native Windows child may not resolve).
if "${SWIFT_TEST[@]}" --filter 'LingxiProbeNoSuchSuite/' --event-stream-output-path "$event_probe" \
     < /dev/null > /dev/null 2>&1 && [ -s "$event_probe" ]; then
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

# Direct and indirect children of a pid, bounded by depth. Used to attribute a blocked pipe inode
# to the descendant that still holds its other end.
descendants() {
  local parent=$1 depth=$2 kid
  [ "$depth" -gt 0 ] || return 0
  for kid in $(pgrep -P "$parent" 2>/dev/null); do
    printf '%s\n' "$kid"
    descendants "$kid" $((depth - 1))
  done
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
    *)
      local t sc nr rawfd fd what held link fdpath tgt owner tree_pid links
      held="$(mktemp)"
      for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        # wchan only names the kernel wait point. For a thread parked in read(), `syscall`'s first
        # argument is the file descriptor, and resolving it through /proc/PID/fd says which pipe it
        # is -- the difference between "two threads sit in anon_pipe_read" and "this one owns inode
        # 44281", which is what identifies the unread end.
        sc="$(tr -s '[:space:]' ' ' < "$t/syscall" 2>/dev/null || true)"
        nr="$(printf '%s\n' "$sc" | awk '{print $1}')"
        rawfd="$(printf '%s\n' "$sc" | awk '{print $2}')"
        fd=""
        case "$nr" in
          0|17|19)
            # Only a real hex token converts: `printf '%d' 1b` yields 0 with an error on stderr,
            # which would have been read as "this thread is parked on stdin".
            case "$rawfd" in
              0x*) fd="$(printf '%d\n' "$rawfd" 2>/dev/null || true)" ;;
            esac
            ;;
        esac
        what=" syscall[${sc:-unreadable}]"
        if [ -n "$fd" ]; then
          link="$(readlink "/proc/${pid}/fd/${fd}" 2>/dev/null || echo '?')"
          what="$what -> fd=$fd ($link)"
          case "$link" in pipe:*) printf '%s\n' "$link" >> "$held" ;; esac
        fi
        printf 'thread %s wchan=%s state=%s%s\n' \
          "$(basename "$t")" \
          "$(cat "$t/wchan" 2>/dev/null || echo '?')" \
          "$(awk '{print $3}' "$t/stat" 2>/dev/null || echo '?')" \
          "$what"
      done | head -40
      # Naming the inode only pays off if the next round says who still holds its other end open:
      # a reader parked on a pipe whose writer is a descendant that outlived its parent is a
      # different defect from one parked on a pipe nobody will ever write to again. Only real
      # descendants are consulted -- a name pattern would match unrelated processes on the runner.
      # Which process holds which descriptor of the blocked pipes, across the whole runner and not
      # just the descendant tree: a child that outlived its parent is reparented away and invisible
      # to a pgrep -P walk, and it is exactly the kind of holder that keeps a pipe from ever
      # reporting EOF. The fd numbers are printed because a read end and a write end look identical
      # as an inode -- the test process "holding" the pipe may only be the blocked reader itself.
      for inode in $(sort -u "$held" 2>/dev/null); do
        printf 'holders of %s:\n' "$inode"
        for fdpath in /proc/[0-9]*/fd/*; do
          [ -e "$fdpath" ] || continue
          tgt="$(readlink "$fdpath" 2>/dev/null || true)"
          if [ "$tgt" = "$inode" ]; then
            owner="${fdpath#/proc/}"; owner="${owner%%/*}"
            printf '   pid %s (%s) fd %s\n' "$owner" \
              "$(ps -o comm= -p "$owner" 2>/dev/null | tr -d '\n' || echo '?')" "${fdpath##*/}"
          fi
        done 2>/dev/null | head -12
      done
      # /proc/PID/task/*/syscall needs ptrace, and yama restricts that to direct children, so from
      # the harness the test binary is off-limits (every line reads "unreadable"). /proc/PID/fd is
      # owner-readable without any ptrace grant, so list the pipes the whole tree still holds open:
      # "two readers parked" only becomes an explanation once it names the other end of the pipe.
      for tree_pid in "$pid" $(descendants "$pid" 3); do
        links="$(ls -l "/proc/$tree_pid/fd" 2>/dev/null | grep -oE 'pipe:\[[0-9]+\]' | sort -u | tr '\n' ' ')"
        [ -n "$links" ] && printf 'pid %s holds %s (%s)\n' "$tree_pid" "$links" \
          "$(ps -o comm= -p "$tree_pid" 2>/dev/null | tr -d '\n' || echo '?')"
      done | head -30
      rm -f "$held"
      ;;
  esac
}

# Crash forensics and telemetry across platforms (WER on Windows, DiagnosticReports on macOS, dmesg on Linux)
dump_crash_evidence() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      echo "-- crash evidence (Windows) --"
      echo "live test processes now: $(ps -W 2>/dev/null | grep -icE 'swift-test|LingXi' || echo 0)"
      for dump_dir in /d/a/_temp/dumps "$LOCALAPPDATA/CrashDumps" "$TEMP/dumps"; do
        if [ -d "$dump_dir" ]; then
          dumps="$(ls -t "$dump_dir" 2>/dev/null | head -5)"
          if [ -n "$dumps" ]; then
            printf 'crash dumps present in %s: %s\n' "$dump_dir" "$dumps"
          fi
        fi
      done
      powershell -NoProfile -Command 'Get-WinEvent -FilterHashtable @{LogName="Application"; StartTime=(Get-Date).AddMinutes(-15)} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match "Application Error|Windows Error Reporting|\.NET Runtime" } | Select-Object -First 5 TimeCreated, ProviderName, Message | Format-List' 2>/dev/null \
        | tr -d '\r' | head -40 \
        || echo "note: no crash event was logged"
      ;;
    Darwin)
      echo "-- crash evidence (macOS) --"
      reports="$(ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -iE 'swift|LingXi' | head -3)"
      if [ -n "$reports" ]; then
        echo "recent crash reports found:"
        for rep in $reports; do
          echo "=== ~/Library/Logs/DiagnosticReports/$rep ==="
          head -n 25 ~/Library/Logs/DiagnosticReports/"$rep" 2>/dev/null || true
        done
      else
        echo "no DiagnosticReports found for swift/LingXi"
      fi
      ;;
    Linux)
      echo "-- crash evidence (Linux) --"
      dmesg -T 2>/dev/null | grep -iE 'segfault|trap|killed process' | tail -10 || true
      ;;
  esac
}

failed_chunks=()
timed_out_chunks=()
lingering_chunks=()
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
  names="$(printf '%s\n' "$chunk" | sed -E 's/^[A-Za-z0-9_]+(Contract)?Tests\.//; s/^LingXiAgentTests\.//' | paste -sd' ' -)"
  expected_for_chunk=0
  while read -r suite_name; do
    [ -z "$suite_name" ] && continue
    suite_cnt="$(printf '%s\n' "$suite_counts" | awk -v s="$suite_name" '$2 == s { print $1 }')"
    expected_for_chunk=$((expected_for_chunk + ${suite_cnt:-0}))
  done <<< "$chunk"

  STDIO_PER_TEST_TIMEOUT="${LINGXI_CI_STDIO_PER_TEST_TIMEOUT:-30}"
  is_stdio_chunk=no
  case "$names" in
    *ClientVNext*|*VNextProduction*|*Round6*|*Round14*)
      is_stdio_chunk=yes
      ;;
  esac

  echo "::group::Chunk ${index}/${#chunks[@]} (expected ${expected_for_chunk} tests) :: ${names}"

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
  # Ask the Swift runtime for a backtrace on a fatal signal, so the kill below can leave one
  # behind: wchan says a thread is parked in a pipe read, only a stack says which case parked it.
  SWIFT_BACKTRACE=enable=yes,demangle=yes,threads=all \
    ${line_buffered[@]+"${line_buffered[@]}"} "${run_args[@]}" < /dev/null > "$chunk_log" 2>&1 &
  runner=$!
  chunk_start=$(date +%s)

  waited=0
  alive=yes
  lingering=no
  done_at=-1
  last_activity=$waited
  last_ended_count=0
  while kill -0 "$runner" 2>/dev/null; do
    current_ended=0
    if [ -s "$chunk_events" ]; then
      current_ended="$(grep -ac '"kind":"testEnded"' "$chunk_events" 2>/dev/null || echo 0)"
    fi
    if [ "$current_ended" -ne "$last_ended_count" ]; then
      last_activity=$waited
      last_ended_count=$current_ended
    fi

    # For stdio chunks, enforce per-test timeout
    if [ "$is_stdio_chunk" = yes ] && [ $((waited - last_activity)) -ge "$STDIO_PER_TEST_TIMEOUT" ]; then
      alive=no
      echo "!! Chunk ${index} (stdio suite: ${names}) per-test timeout exceeded (${STDIO_PER_TEST_TIMEOUT}s on a single test). Capturing stacks then killing."
      timed_out_test="$(unreported_from_events "$chunk_events")"
      [ -n "$timed_out_test" ] && echo "-- wedged test in flight: ${timed_out_test}"
      dump_stacks "$runner"
      children="$(pgrep -P "$runner" 2>/dev/null)"
      for child in $children; do
        dump_stacks "$child"
      done
      kill_tree "$runner"
      break
    fi

    if [ "$waited" -ge "$CHUNK_TIMEOUT" ]; then
      alive=no
      echo "!! Chunk ${index} exceeded ${CHUNK_TIMEOUT}s. Capturing stacks then killing."
      # "Hung" and "only slow" look identical from the exit status, and the difference decides
      # whether to chase a deadlock or raise the budget, so state what the log actually holds:
      # zero bytes with no start marker means the test binary never produced anything at all.
      echo "-- diagnosis: log $(wc -c < "$chunk_log" 2>/dev/null || echo 0) bytes," \
        "$(grep -ac '"kind":"testStarted"' "$chunk_events" || true) started," \
        "$(grep -ac '"kind":"testEnded"' "$chunk_events" || true) finished (event stream)"
      dump_stacks "$runner"
      # The runner is a wrapper; the real test processes are its descendants.
      children="$(pgrep -P "$runner" 2>/dev/null)"
      for child in $children; do
        dump_stacks "$child"
      done
      # Ask for runtime backtraces before anything dies: wchan only says a thread is parked in a
      # pipe read, a stack says which await put it there. QUIT is a Swift backtrace signal, and it
      # is a foreign concept on Windows, so this stays on the platforms that can answer -- and it
      # reports whether it produced anything, so a next round can decide if it earns its keep.
      # A killed chunk would otherwise delete the results of every case that was in flight. Run
      # the same filter once more with a short budget: if it finishes, the coverage is recovered,
      # and if it wedges again the answer is that the deadlock is inherent to those cases rather
      # than something a neighbour left behind -- which is the distinction the whole Windows
      # backlog rests on and nothing else here can establish.
      echo "-- retrying the chunk once with a ${RETRY_TIMEOUT}s budget"
      retry_log="$(mktemp)"
      retry_events="$(mktemp)"
      retry_args=("${SWIFT_TEST[@]}" --filter "$filter" --event-stream-output-path "$retry_events")
      if [ -n "$XUNIT_DIR" ]; then
        retry_args+=(--xunit-output "$XUNIT_DIR/test-results-chunk-$index-retry.xml")
      fi
      ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} ${line_buffered[@]+"${line_buffered[@]}"} "${retry_args[@]}" < /dev/null > "$retry_log" 2>&1
      retry_ran="$(grep -oE 'Test run with [0-9]+ test' "$retry_log" | tail -1 | grep -oE '[0-9]+' || true)"
      if [ -n "${retry_ran:-}" ]; then
        executed=$((executed + retry_ran))
        echo "-- retry completed: $retry_ran tests reported on the second attempt"
        grep -oE '[√×✘] Test run with [0-9]+ tests.*' "$retry_log" | tail -1
        for report in "$XUNIT_DIR"/test-results-chunk-"$index"-retry*.xml; do
          [ -f "$report" ] || continue
          mkdir -p "$ARTIFACT_DIR"
          cp "$report" "$ARTIFACT_DIR/" 2>/dev/null || true
        done
      else
        echo "-- retry also produced no verdict: the wedge reproduces without its neighbours"
        unreported_from_events "$retry_events" | sed 's/^/   still in flight: /'
      fi
      rm -f "$retry_log" "$retry_events"
      case "$(uname -s)" in
        Darwin|Linux)
          bytes_before_backtrace="$(wc -c < "$chunk_log" 2>/dev/null || echo 0)"
          kill -QUIT "$runner" 2>/dev/null
          for child in $children; do
            kill -QUIT "$child" 2>/dev/null
          done
          sleep 3
          if grep -q "Backtrace" "$chunk_log" 2>/dev/null; then
            printf "%s\n" "-- runtime backtraces appended after the last log dump:"; tail -c +"$((bytes_before_backtrace + 1))" "$chunk_log" 2>/dev/null | head -120
          else
            echo "-- no runtime backtrace produced; the Swift crash handler did not answer QUIT"
          fi
          ;;
      esac
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

  # Count what actually ran: swift-testing tests from events or log, plus any XCTest cases
  st_ran=0
  if [ -s "$chunk_events" ]; then
    st_ran="$(grep -a '"kind":"testEnded"' "$chunk_events" 2>/dev/null | grep '"testID":' | grep '/' | wc -l | tr -d ' ' || echo 0)"
  fi
  if [ "${st_ran:-0}" -eq 0 ]; then
    st_ran="$(grep -oE 'Test run with [0-9]+ test' "$chunk_log" | tail -1 | grep -oE '[0-9]+' || echo 0)"
  fi
  xct_ran="$(grep -oE 'Executed [0-9]+ test' "$chunk_log" | tail -1 | grep -oE '[0-9]+' || echo 0)"
  ran=$(( ${st_ran:-0} + ${xct_ran:-0} ))
  executed=$((executed + ran))

  # Compute issue/failure count
  failed_in_chunk=0
  if [ -s "$chunk_events" ]; then
    failed_in_chunk="$(grep -ac '"kind":"issueRecorded"' "$chunk_events" 2>/dev/null || echo 0)"
  fi
  if [ "$failed_in_chunk" -eq 0 ] && grep -qE 'Test run with [0-9]+ tests failed' "$chunk_log" 2>/dev/null; then
    failed_in_chunk=1
  fi
  if grep -qE 'Executed [0-9]+ tests?, with [1-9][0-9]* failure' "$chunk_log" 2>/dev/null; then
    failed_in_chunk=$((failed_in_chunk + 1))
  fi

  chunk_verdict="passed"
  if [ "$alive" = no ]; then
    chunk_verdict="hang"
  elif [ "$lingering" = yes ]; then
    chunk_verdict="lingered"
  elif [ "$status" -ne 0 ] || [ "$failed_in_chunk" -gt 0 ]; then
    chunk_verdict="failed"
  elif [ "$ran" -lt "$expected_for_chunk" ]; then
    chunk_verdict="deficit"
  fi

  json_report_file="test-results-chunk-${index}.json"
  if [ -n "$XUNIT_DIR" ]; then
    json_report_file="$XUNIT_DIR/test-results-chunk-${index}.json"
  fi
  cat > "$json_report_file" <<EOF
{
  "chunk": ${index},
  "total_chunks": ${#chunks[@]},
  "suites": $(printf '%s\n' "$names" | awk '{printf "["; for(i=1;i<=NF;i++){printf "\"%s\"%s", $i, (i==NF?"":", ")}; printf "]\n"}'),
  "filter": "${filter}",
  "expected_tests": ${expected_for_chunk},
  "executed_tests": ${ran},
  "passed_tests": $((ran - failed_in_chunk > 0 ? ran - failed_in_chunk : 0)),
  "failed_tests": ${failed_in_chunk},
  "exit_code": ${status},
  "elapsed_seconds": ${elapsed},
  "status": "${chunk_verdict}",
  "timed_out": $([ "$alive" = no ] && echo true || echo false),
  "lingered": $([ "$lingering" = yes ] && echo true || echo false)
}
EOF

  if [ "$alive" = no ]; then
    timed_out_chunks+=("Chunk ${index}: ${names}")
    victim="$(unreported_from_events "$chunk_events")"
    [ -z "$victim" ] && victim="$(unreported_tests "$chunk_log")"
    [ -n "$victim" ] && echo "-- started but never reported: ${victim}"
    tail -20 "$chunk_log"
    dump_crash_evidence
  elif [ "$lingering" = yes ]; then
    # A distinct defect from a hung test: the plan finished, so its verdict is trustworthy,
    # but the process never returned. Report both so neither signal is lost.
    lingering_chunks+=("Chunk ${index}: ${names}")
    grep -E 'Test run with [0-9]+ tests' "$chunk_log" | tail -1
    if [ "$status" -ne 0 ] || grep -qE 'Test run with [0-9]+ tests failed' "$chunk_log"; then
      failed_chunks+=("Chunk ${index}: ${names}")
      grep -E "recorded an issue|Expectation failed|Caught error|error:" "$chunk_log" | head -30
    fi
    dump_crash_evidence
  elif [ "$status" -ne 0 ]; then
    failed_chunks+=("Chunk ${index} (exit ${status}): ${names}")
    echo "-- chunk ${index} exit ${status} after ${elapsed}s --"
    silent_victim="$(unreported_from_events "$chunk_events")"
    [ -z "$silent_victim" ] && silent_victim="$(unreported_tests "$chunk_log")"
    [ -n "$silent_victim" ] && echo "!! chunk ${index} started but never reported: ${silent_victim}"
    grep -E "recorded an issue|Expectation failed|Caught error|error:|Test run with" "$chunk_log" \
      | head -30
    echo "--- chunk ${index} full log ---"
    cat "$chunk_log"
    dump_crash_evidence
  elif [ "$ran" -lt "$expected_for_chunk" ]; then
    # Test count conservation violation (e.g. silent exit or partial test run)
    failed_chunks+=("Chunk ${index} execution count deficit (${ran}/${expected_for_chunk} executed): ${names}")
    echo "::error::Chunk ${index} failed conservation: expected ${expected_for_chunk} tests from list-tests, but only executed ${ran} tests"
    silent_victim="$(unreported_from_events "$chunk_events")"
    [ -z "$silent_victim" ] && silent_victim="$(unreported_tests "$chunk_log")"
    [ -n "$silent_victim" ] && echo "!! tests started but never reported or missing: ${silent_victim}"
    tail -30 "$chunk_log"
    dump_crash_evidence
  elif [ "$ran" -eq 0 ]; then
    failed_chunks+=("Chunk ${index} matched no tests: ${names}")
    echo "!! Chunk ${index} ran 0 tests. Filter was: ${filter}"
    tail -20 "$chunk_log"
    dump_crash_evidence
  else
    printf 'ok  chunk %-3s %4ss  %s/%s tests\n' "$index" "$elapsed" "$ran" "$expected_for_chunk"
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
    for json_rep in "$XUNIT_DIR"/test-results-chunk-"$index"*.json; do
      [ -f "$json_rep" ] || continue
      mkdir -p "$ARTIFACT_DIR"
      cp "$json_rep" "$ARTIFACT_DIR/" 2>/dev/null || true
    done
    # The xunit report only exists for a chunk that finished, so it cannot describe a hang or a
    # death. The event stream does: it records every case that started, which is what lets a chunk
    # be triaged after the run instead of only from the lines this script happened to print.
    if [ -s "$chunk_events" ] && [ -d "$ARTIFACT_DIR" ]; then
      cp "$chunk_events" "$ARTIFACT_DIR/events-chunk-$index.jsonl" 2>/dev/null \
        || echo "note: could not stage chunk ${index}'s event stream"
    fi
  fi
  rm -f "$chunk_log" "$chunk_events"
  echo "::endgroup::"
done

if [ "$STRESS_ROUNDS" -gt 0 ] 2>/dev/null; then
  # Group the stress family exactly the way the chunk plan does: a suite in ISOLATE_SUITES gets an
  # invocation of its own. Cramming them together -- which is what the first version of this dial
  # did -- reproduces the interference that chunking exists to prevent, so a red round would have
  # said nothing about stability.
  stress_groups=()
  stress_shared=""
  for suite in $STRESS_SUITES; do
    case " $ISOLATE_SUITES " in
      *" $suite "*) stress_groups+=("$suite") ;;
      *) stress_shared="$stress_shared $suite" ;;
    esac
  done
  [ -n "${stress_shared# }" ] && stress_groups+=("${stress_shared# }")

  echo
  echo "================ Stress: ${STRESS_ROUNDS} passes over ${#stress_groups[@]} groups ================"
  stress_round=0
  stress_failed=0
  stress_timed_out=0
  while [ "$stress_round" -lt "$STRESS_ROUNDS" ]; do
    stress_round=$((stress_round + 1))
    for group in "${stress_groups[@]}"; do
      stress_filter="$(printf '%s/\n' $group | paste -sd'|' -)"
      stress_log="$(mktemp)"
      stress_events="$(mktemp)"
      # The event stream is what makes a hung group diagnosable rather than just red: it names the
      # case that was in flight, which is the first question a stress failure raises.
      "${SWIFT_TEST[@]}" --filter "$stress_filter" --event-stream-output-path "$stress_events" \
        < /dev/null > "$stress_log" 2>&1 &
      stress_pid=$!
      stress_waited=0
      while kill -0 "$stress_pid" 2>/dev/null; do
        if [ "$stress_waited" -ge "$STRESS_ROUND_TIMEOUT" ]; then
          printf '  round %s [%s]: HUNG past %ss\n' "$stress_round" "$group" "$STRESS_ROUND_TIMEOUT"
          kill_tree "$stress_pid"
          stress_failed=1
          stress_timed_out=$((stress_timed_out + 1))
          break
        fi
        sleep 5
        stress_waited=$((stress_waited + 5))
      done
      wait "$stress_pid" 2>/dev/null
      stress_status=$?
      stress_ran="$(grep -oE 'Test run with [0-9]+ test' "$stress_log" | tail -1 | grep -oE '[0-9]+' || true)"
      if [ "$stress_status" -ne 0 ]; then
        stress_failed=1
        printf '  round %s [%s]: exit %s after %ss\n' "$stress_round" "$group" "$stress_status" "$stress_waited"
        grep -aE "recorded an issue|Expectation failed|Caught error|error:" "$stress_log" | head -8
        stress_victim="$(unreported_from_events "$stress_events")"
        [ -n "$stress_victim" ] && echo "    started but never reported: ${stress_victim}"
        tail -6 "$stress_log"
      else
        printf '  round %s [%s]: ok, %s tests in %ss\n' "$stress_round" "$group" "${stress_ran:-?}" "$stress_waited"
      fi
      rm -f "$stress_log" "$stress_events"
    done
  done
  echo "stress: ${stress_round} rounds, ${stress_timed_out} hung, verdict $([ "$stress_failed" -eq 0 ] && echo stable || echo UNSTABLE)"
  if [ "$stress_failed" -ne 0 ]; then
    echo "::error::the stress family did not pass ${STRESS_ROUNDS} consecutive rounds"
    exit 1
  fi
fi

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
