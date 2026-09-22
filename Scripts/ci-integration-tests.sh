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
# read its pipes, and the teardown of that pipe still has a defect open in this repo (see
# AsyncLineReader's Windows branch). While one chunk dies it takes every other suite's results in
# that process with it, which is how twelve unrelated suites went unreported at a time. Running
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
      # Per-thread wait reasons are the closest Windows equivalent of the /proc wchan census used
      # on Linux, and the census is what turned a "hang" into "two cases parked on a pipe read".
      # A wedge whose threads all sit in UserRequest is an await that will never be resumed; one
      # with a thread parked in Executive/LocalAlert is blocked in a kernel object.
      powershell -NoProfile -Command '
$p = @(Get-Process | Where-Object { $_.ProcessName -like "LingXiAgentPackageTests*" })
"test binary census: $($p.Count) process(es)"
$p | ForEach-Object {
  $t = @($_.Threads)
  "  pid=$($_.Id) threads=$($t.Count) handles=$($_.HandleCount) waitReasons=" + (($t | Group-Object { $_.WaitReason } | ForEach-Object { $_.Name + ":" + $_.Count }) -join ",")
}
' 2>&1 | tr -d '\r' | head -20
      ;;
    *)
      local t sc nr fd what
      for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        # wchan only names the kernel wait point. For a thread parked in read(), `syscall`'s first
        # argument is the file descriptor, and resolving it through /proc/PID/fd says which pipe it
        # is -- the difference between "two threads sit in anon_pipe_read" and "this one owns inode
        # 44281", which is what identifies the unread end.
        sc="$(cat "$t/syscall" 2>/dev/null || true)"
        nr="${sc%% *}"
        fd=""
        what=""
        if [ "$nr" = "0" ]; then
          fd="$(printf '%d\n' "$(printf '%s\n' "$sc" | awk '{print $2}')" 2>/dev/null || true)"
          if [ -n "$fd" ]; then
            what=" read-fd=${fd} ($(readlink "/proc/${pid}/fd/${fd}" 2>/dev/null || echo '?'))"
          fi
        fi
        printf 'thread %s wchan=%s state=%s%s\n' \
          "$(basename "$t")" \
          "$(cat "$t/wchan" 2>/dev/null || echo '?')" \
          "$(awk '{print $3}' "$t/stat" 2>/dev/null || echo '?')" \
          "$what"
      done | head -40
      ;;
  esac
}

failed_chunks=()
timed_out_chunks=()
lingering_chunks=()
# Set once the stage has replayed one silently-failing chunk through the test binary itself.
direct_replay_done=""

# A chunk can also die without ever printing a verdict. Because a redirected stdout on Windows is
# block-buffered, the whole tail is lost with the process, so the log shows passing tests and then
# nothing at all. The Application event log is written by the kernel outside that process, so the
# faulting module and exception code survive there, and a process census says whether a previously
# killed chunk left children holding the test binary.
dump_crash_evidence() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      echo "live test processes now: $(ps -W 2>/dev/null | grep -icE 'swift-test|LingXiAgent' | head -1)"
      # Every count is printed by PowerShell, never inferred from a shell exit status: `grep -c`
      # returns 1 when the count is zero, which made the old shell-level fallback announce "no crash
      # event" for a reason that had nothing to do with the event log. A zero now has to mean zero,
      # and an unreadable log has to say it is unreadable rather than look like an absence.
      # Defender is queried because it terminates processes outside the OS crash path: no WER entry,
      # no output, a nonzero exit code -- which is precisely the shape these deaths have.
      powershell -NoProfile -Command '
$since = (Get-Date).AddMinutes(-20)
$crash = @(Get-WinEvent -FilterHashtable @{LogName="Application"; StartTime=$since} -ErrorAction SilentlyContinue | Where-Object { $_.Provider.Name -match "Application Error|Windows Error Reporting|\.NET Runtime" })
"application crash events in the last 20min: $($crash.Count)"
$crash | Select-Object -First 4 | ForEach-Object { "  " + $_.TimeCreated + " [" + $_.Provider.Name + "] " + ($_.Message -replace "\r?\n", " ") }
$dl = Get-WinEvent -ListLog "Microsoft-Windows-Windows Defender/Operational" -ErrorAction SilentlyContinue
if (-not $dl) {
  "defender log: not readable on this runner"
} else {
  $def = @(Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-Windows Defender/Operational"; StartTime=$since; ID=1116,1117} -ErrorAction SilentlyContinue)
  "defender detections in the last 20min: $($def.Count)"
  $def | Select-Object -First 4 | ForEach-Object { "  " + $_.TimeCreated + " " + ($_.Message -replace "\r?\n", " ") }
}
' 2>&1 | tr -d '\r' | head -40
      ;;
  esac
}

executed=0
index=0

# `swift test` returns 1 whatever happened to the binary it launched, so an exit whose status is an
# exception code (0xC0000005) and a voluntary exit(1) look identical through the wrapper -- and on a
# runner image where Windows Error Reporting does not write events, "no crash event" proves nothing
# either. Replaying the same filter through the test binary itself is the only way to read the real
# status without a debugger. It is a probe: its outcome is printed, never used as the verdict.
direct_replay() {
  local index=$1 filter=$2
  local bin probe_log probe_pid waited=0 status candidate
  bin="$(swift build --show-bin-path 2>/dev/null || true)"
  for candidate in "${bin%/}/LingXiAgentPackageTests.xctest" "${bin%/}/LingXiAgentPackageTests.xctest.exe"; do
    [ -f "$candidate" ] && break
  done
  if [ ! -f "$candidate" ]; then
    echo "note: no test binary beside $bin, cannot replay directly"
    return
  fi
  probe_log="$(mktemp)"
  SWIFT_BACKTRACE=enable=yes,demangle=yes,threads=all "$candidate" \
    --testing-library swift-testing --filter "$filter" < /dev/null > "$probe_log" 2>&1 &
  probe_pid=$!
  while kill -0 "$probe_pid" 2>/dev/null; do
    if [ "$waited" -ge 120 ]; then
      echo "-- direct replay still running after ${waited}s: the wedge reproduces through the binary too"
      kill_tree "$probe_pid"
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$probe_pid" 2>/dev/null
  status=$?
  printf -- '-- direct replay of chunk %s: real exit status=%d (0x%08x), %ss\n' "$index" "$status" "$status" "$waited"
  if [ "$status" -ge 3221225472 ] 2>/dev/null; then
    echo "   ^ that is an NTSTATUS exception code, i.e. the process died from a fault, not from exit()"
  fi
  grep -aiE "Fatal error|Crash|Exception|EXC_|Test run with|Backtrace" "$probe_log" | tail -10
  tail -12 "$probe_log"
  rm -f "$probe_log"
}

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
  while kill -0 "$runner" 2>/dev/null; do
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
    # One replay per stage is enough to answer crash-or-not, and it is Windows-only because there
    # the test binary is a plain executable rather than a bundle.
    if [ "$ran" -eq 0 ] && [ -z "$direct_replay_done" ]; then
      case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
          direct_replay_done=yes
          direct_replay "$index" "$filter"
          ;;
      esac
    fi
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
