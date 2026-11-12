#!/bin/bash
# =============================================================================
# ProcPilot - tests/test_dashboard_logging.sh
# Owner : Abdul Rehman (Dashboard and logging tests, spec section 13)
#
# Covers: log writing, log display, dashboard rendering, process table,
#         counters, warnings, refresh interval and clean CTRL+C exit.
#
# The module is tested on its own (spec rule 11): Shaheer's monitoring
# functions are replaced by small stubs below, and the PP_* settings are set
# the same way load_config would set them, inside a temporary directory.
# Nothing in the real state/ or logs/ folders is touched.
#
# Usage:  bash tests/test_dashboard_logging.sh
# Exit :  0 if every test passes, 1 otherwise.
# =============================================================================

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$TEST_DIR")"

# shellcheck source=../src/logger.sh
source "$PROJECT_DIR/src/logger.sh"
# shellcheck source=../src/dashboard.sh
source "$PROJECT_DIR/src/dashboard.sh"

# -----------------------------------------------------------------------------
# Tiny test framework
# -----------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS  %s\n' "$1"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  SKIP  %s (%s)\n' "$1" "$2"; }
fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '  FAIL  %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '        %s\n' "$2"
    fi
}

assert_eq() {           # assert_eq EXPECTED ACTUAL NAME
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}
assert_contains() {     # assert_contains TEXT NEEDLE NAME
    if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "missing [$2]"; fi
}
assert_not_contains() { # assert_not_contains TEXT NEEDLE NAME
    if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected [$2]"; fi
}
assert_match() {        # assert_match TEXT REGEX NAME
    if [[ "$1" =~ $2 ]]; then pass "$3"; else fail "$3" "[$1] does not match /$2/"; fi
}
assert_ge() {           # assert_ge MIN ACTUAL NAME
    if [ "$2" -ge "$1" ]; then pass "$3"; else fail "$3" "expected >= $1, got $2"; fi
}
assert_between() {      # assert_between MIN MAX ACTUAL NAME
    if [ "$3" -ge "$1" ] && [ "$3" -le "$2" ]; then pass "$4"; else fail "$4" "expected $1..$2, got $3"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# -----------------------------------------------------------------------------
# Test environment (what load_config would normally provide)
# -----------------------------------------------------------------------------
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/procpilot_test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
ENV_NUMBER=0

setup_env() {
    ENV_NUMBER=$((ENV_NUMBER + 1))
    PP_ROOT_DIR="$TMP_ROOT/project$ENV_NUMBER"
    PP_STATE_DIR="$PP_ROOT_DIR/state"
    PP_PROCESSES_DIR="$PP_STATE_DIR/processes"
    PP_LOG_DIR="$PP_ROOT_DIR/logs"
    PP_APP_LOG="$PP_LOG_DIR/procpilot.log"
    PP_REFRESH_INTERVAL=2
    PP_CPU_WARNING_THRESHOLD=80
    PP_RAM_WARNING_THRESHOLD=80
    mkdir -p "$PP_PROCESSES_DIR" "$PP_LOG_DIR/processes"

    STUB_SYSTEM_CPU="37.5"
    STUB_RAM_USED="2048"
    STUB_RAM_TOTAL="8192"
    STUB_RAM_PERCENT="25.0"
    STUB_WARNING=""
    STUB_INFO_FAILS_FOR=""
    CALLS_SYSTEM=0
    CALLS_CHECK=0
    CALLS_COUNTS=0
    CALLS_INFO=""
    CALLS_REFRESH=""
}

# fake_process PID STATUS CPU MEM COMMAND [ARGS...]
# Creates a state directory like Azan's start_process would.
fake_process() {
    local pid="$1" status="$2" cpu="$3" mem="$4"
    local dir="$PP_PROCESSES_DIR/$pid"
    shift 4
    mkdir -p "$dir"
    printf '%s\n' "$*" > "$dir/command.txt"
    printf '%s\n' "$status" > "$dir/status.txt"
    printf '%s\n' "$pid" > "$dir/pid.txt"
    # Test-only values used by the get_process_info stub.
    printf '%s\n' "$cpu" > "$dir/stub_cpu"
    printf '%s\n' "$mem" > "$dir/stub_mem"
}

# -----------------------------------------------------------------------------
# Stubs for Shaheer's functions (same names, same output variables).
# They also print noise to stdout/stderr to prove the dashboard keeps its
# screen clean.
# -----------------------------------------------------------------------------
get_system_resources() {
    CALLS_SYSTEM=$((CALLS_SYSTEM + 1))
    PP_SYSTEM_CPU="$STUB_SYSTEM_CPU"
    PP_SYSTEM_RAM_USED="$STUB_RAM_USED"
    PP_SYSTEM_RAM_TOTAL="$STUB_RAM_TOTAL"
    PP_SYSTEM_RAM_PERCENT="$STUB_RAM_PERCENT"
    echo "STUB-NOISE-STDOUT"
    echo "STUB-NOISE-STDERR" >&2
    return 0
}

check_resources() {
    CALLS_CHECK=$((CALLS_CHECK + 1))
    get_system_resources
    PP_RESOURCE_WARNING="$STUB_WARNING"
    [ -z "$PP_RESOURCE_WARNING" ]
}

get_process_counts() {
    local dir status
    CALLS_COUNTS=$((CALLS_COUNTS + 1))
    PP_RUNNING_COUNT=0
    PP_COMPLETED_COUNT=0
    PP_FAILED_COUNT=0
    PP_STOPPED_COUNT=0
    for dir in "$PP_PROCESSES_DIR"/*/; do
        [ -f "$dir/status.txt" ] || continue
        status="$(<"$dir/status.txt")"
        case "$status" in
            running)   PP_RUNNING_COUNT=$((PP_RUNNING_COUNT + 1)) ;;
            completed) PP_COMPLETED_COUNT=$((PP_COMPLETED_COUNT + 1)) ;;
            failed)    PP_FAILED_COUNT=$((PP_FAILED_COUNT + 1)) ;;
            stopped)   PP_STOPPED_COUNT=$((PP_STOPPED_COUNT + 1)) ;;
        esac
    done
    return 0
}

get_process_info() {
    local pid="$1"
    local dir="$PP_PROCESSES_DIR/$pid"
    CALLS_INFO="$CALLS_INFO $pid"
    if [ "$pid" = "$STUB_INFO_FAILS_FOR" ] || [ ! -d "$dir" ]; then
        return 1
    fi
    PP_PROCESS_PID="$pid"
    PP_PROCESS_COMMAND="$(<"$dir/command.txt")"
    PP_PROCESS_STATUS="$(<"$dir/status.txt")"
    PP_PROCESS_CPU="$(<"$dir/stub_cpu")"
    PP_PROCESS_MEM="$(<"$dir/stub_mem")"
    echo "STUB-NOISE-STDOUT"
    return 0
}

refresh_process_state() {
    CALLS_REFRESH="$CALLS_REFRESH $1"
    return 0
}

# =============================================================================
section "write_log"
# =============================================================================
setup_env

out="$(write_log INFO "Process started" 2>&1)"
rc=$?
assert_eq 0 "$rc" "write_log INFO returns 0"
assert_eq "" "$out" "write_log prints nothing to stdout/stderr on success"
last="$(tail -n 1 "$PP_APP_LOG")"
assert_match "$last" '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[INFO\] Process started$' \
    "entry has timestamp, level and message"

write_log WARNING "CPU high"
assert_match "$(tail -n 1 "$PP_APP_LOG")" '\[WARNING\] CPU high$' "WARNING level accepted"
write_log ERROR "Could not stop process"
assert_match "$(tail -n 1 "$PP_APP_LOG")" '\[ERROR\] Could not stop process$' "ERROR level accepted"
write_log info "lowercase level"
assert_match "$(tail -n 1 "$PP_APP_LOG")" '\[INFO\] lowercase level$' "lowercase level stored as INFO"

assert_eq 4 "$(wc -l < "$PP_APP_LOG")" "entries are appended, not overwritten"

before="$(wc -l < "$PP_APP_LOG")"
err="$(write_log DEBUG "nope" 2>&1 >/dev/null)"
rc=$?
assert_eq 1 "$rc" "invalid level returns 1"
assert_contains "$err" "invalid level" "invalid level reports an error on stderr"
assert_eq "$before" "$(wc -l < "$PP_APP_LOG")" "invalid level writes nothing"

write_log INFO 2>/dev/null
assert_eq 1 "$?" "missing message returns 1"
write_log INFO "" 2>/dev/null
assert_eq 1 "$?" "empty message returns 1"

write_log INFO "line one
line two"
assert_match "$(tail -n 1 "$PP_APP_LOG")" '\[INFO\] line one line two$' "multi-line message kept on one line"

write_log INFO 'cost 100% \n $HOME "quoted" `tick`'
assert_contains "$(tail -n 1 "$PP_APP_LOG")" 'cost 100% \n $HOME "quoted" `tick`' \
    "special characters stored literally"

# shellcheck disable=SC2086
write_log INFO Started process 42
assert_match "$(tail -n 1 "$PP_APP_LOG")" '\[INFO\] Started process 42$' "unquoted words are joined"

rm -rf -- "$PP_LOG_DIR"
write_log INFO "after removing log dir"
assert_eq 0 "$?" "write_log recreates a missing log directory"
assert_contains "$(cat "$PP_APP_LOG")" "after removing log dir" "entry written after recreating directory"

saved_log="$PP_APP_LOG"
unset PP_APP_LOG
out="$(write_log INFO "no log path" 2>/dev/null)"
rc=$?
assert_eq 2 "$rc" "write_log returns 2 when PP_APP_LOG is not set"
assert_eq "" "$out" "write_log keeps stdout clean on failure"
PP_APP_LOG="$saved_log"

# =============================================================================
section "show_logs"
# =============================================================================
setup_env

out="$(show_logs)"
assert_eq 0 "$?" "show_logs on a missing log returns 0"
assert_eq "No log entries yet." "$out" "show_logs explains when there is no log yet"

for i in $(seq 1 30); do
    write_log INFO "entry $i"
done

out="$(show_logs)"
assert_eq 20 "$(printf '%s\n' "$out" | wc -l)" "default shows 20 lines"
assert_contains "$(printf '%s\n' "$out" | head -n 1)" "entry 11" "default starts at the 20th-last entry"
assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "entry 30" "default ends at the newest entry"

out="$(show_logs 5)"
assert_eq 5 "$(printf '%s\n' "$out" | wc -l)" "show_logs 5 shows 5 lines"
assert_contains "$(printf '%s\n' "$out" | head -n 1)" "entry 26" "show_logs 5 shows the 5 newest entries"

out="$(show_logs 007)"
assert_eq 7 "$(printf '%s\n' "$out" | wc -l)" "leading zeros accepted (007 -> 7)"

out="$(show_logs 500)"
assert_eq 30 "$(printf '%s\n' "$out" | wc -l)" "NUMBER larger than the log shows everything"

for bad in abc 0 -3 2.5 ""; do
    show_logs "$bad" >/dev/null 2>&1
    rc=$?
    if [ -z "$bad" ]; then
        # An explicitly empty argument falls back to the default.
        assert_eq 0 "$rc" "show_logs '' uses the default"
    else
        assert_eq 1 "$rc" "show_logs rejects '$bad'"
    fi
done

show_logs 5 6 >/dev/null 2>&1
assert_eq 1 "$?" "show_logs rejects extra arguments"

write_log ERROR "boom"
out="$(show_logs 1)"
assert_not_contains "$out" $'\033' "no colour codes when output is not a terminal"

# =============================================================================
section "render_dashboard"
# =============================================================================
setup_env
fake_process 1000 running   12.5 3.25 sleep 300
fake_process 99   completed 0    0.1  echo "hello world"
fake_process 1500 failed    0.0  0.0  ls /does-not-exist
fake_process 2000 stopped   0.0  1    python3 -m http.server 8080
mkdir -p "$PP_PROCESSES_DIR/not-a-pid"

render_dashboard > "$TMP_ROOT/render.out" 2> "$TMP_ROOT/render.err"
rc=$?
screen="$(cat "$TMP_ROOT/render.out")"

assert_eq 0 "$rc" "render_dashboard returns 0"
assert_contains "$screen" "ProcPilot Dashboard" "header is shown"
assert_match "$screen" 'CPU +\[\|+ +\] +37\.5%' "system CPU usage and bar shown"
assert_match "$screen" 'RAM +\[\|+ +\] +25\.0% +used 2048 of 8192' "system RAM usage, used and total shown"
assert_contains "$screen" "Processes: 4 total, 1 running, 1 completed, 1 failed, 1 stopped" \
    "running/completed/failed/stopped counters shown"
assert_match "$screen" 'PID +CPU% +MEM% +STATUS +COMMAND' "process table header shown"
assert_match "$screen" '1000 +12\.5 +3\.2 +running +sleep 300' "running process row (PID, CPU, MEM, status, command)"
assert_match "$screen" '99 +0\.0 +0\.1 +completed +echo hello world' "completed process row"
assert_match "$screen" '1500 +0\.0 +0\.0 +failed +ls /does-not-exist' "failed process row"
assert_match "$screen" '2000 +0\.0 +1\.0 +stopped +python3 -m http.server 8080' "stopped process row"
assert_contains "$screen" "Warnings: none" "no warning shown when PP_RESOURCE_WARNING is empty"
assert_not_contains "$screen" "not-a-pid" "non-numeric directories are ignored"
assert_not_contains "$screen" "STUB-NOISE" "output of monitoring functions does not leak onto the screen"
assert_not_contains "$screen" $'\033' "plain text (no escape codes) when not on a terminal"

order="$(grep -oE '^ *[0-9]+ ' "$TMP_ROOT/render.out" | tr -d ' ' | tr '\n' ' ')"
assert_eq "99 1000 1500 2000 " "$order" "processes sorted by PID"

assert_ge 1 "$CALLS_SYSTEM" "get_system_resources called"
assert_eq 1 "$CALLS_COUNTS" "get_process_counts called once per render"
assert_eq 1 "$CALLS_CHECK" "check_resources called once per render"
assert_eq " 99 1000 1500 2000" "$CALLS_INFO" "get_process_info called once for every managed PID"
assert_eq " 99 1000 1500 2000" "$CALLS_REFRESH" "refresh_process_state called for every managed PID"

# Warnings
STUB_WARNING="CPU usage 92% is above the 80% threshold"
screen="$(render_dashboard 2>/dev/null)"
assert_contains "$screen" "WARNING: CPU usage 92% is above the 80% threshold" "resource warning shown"
assert_not_contains "$screen" "Warnings: none" "'Warnings: none' hidden while a warning is active"

STUB_WARNING="CPU usage 92% is above the 80% threshold
RAM usage 85% is above the 80% threshold"
screen="$(render_dashboard 2>/dev/null)"
assert_contains "$screen" "WARNING: CPU usage 92%" "first of several warnings shown"
assert_contains "$screen" "WARNING: RAM usage 85%" "second of several warnings shown"
STUB_WARNING=""

# Unavailable process information must not show the previous process's data
STUB_INFO_FAILS_FOR=1500
screen="$(render_dashboard 2>/dev/null)"
assert_match "$screen" '1500 +- +- +unknown +\(process information unavailable\)' \
    "row marked unavailable when get_process_info fails"
assert_match "$screen" '2000 +0\.0 +1\.0 +stopped' "next row still correct after a failure"
STUB_INFO_FAILS_FOR=""

# Non-numeric values from monitoring
STUB_SYSTEM_CPU=""
STUB_RAM_PERCENT="abc"
screen="$(render_dashboard 2>/dev/null)"
assert_match "$screen" 'CPU +\[ +\] +N/A%' "missing CPU value shown as N/A"
assert_match "$screen" 'RAM +\[ +\] +N/A%' "invalid RAM value shown as N/A"
STUB_SYSTEM_CPU="37.5"
STUB_RAM_PERCENT="25.0"

# Long command is kept complete in a plain snapshot
long_cmd="bash -c $(printf 'x%.0s' $(seq 1 150))"
fake_process 3000 running 1 1 "$long_cmd"
screen="$(render_dashboard 2>/dev/null)"
assert_contains "$screen" "$long_cmd" "long command shown in full outside live mode"
rm -rf -- "${PP_PROCESSES_DIR:?}/3000"

# Empty state
setup_env
screen="$(render_dashboard 2>/dev/null)"
assert_contains "$screen" "No managed processes" "empty-state message when nothing is managed"
assert_contains "$screen" "Processes: 0 total, 0 running, 0 completed, 0 failed, 0 stopped" "zero counters shown"

# Missing state directory (before the first run) is not an error
rm -rf -- "$PP_STATE_DIR"
render_dashboard >/dev/null 2>&1
assert_eq 0 "$?" "render works when the processes directory does not exist yet"
mkdir -p "$PP_PROCESSES_DIR"

# Arguments / missing dependencies
render_dashboard extra >/dev/null 2>&1
assert_eq 1 "$?" "render_dashboard rejects arguments"

err="$( (unset -f get_process_info; render_dashboard) 2>&1 >/dev/null )"
assert_contains "$err" "get_process_info" "missing monitoring function reported by name"
( unset -f get_process_info; render_dashboard >/dev/null 2>&1 )
assert_eq 1 "$?" "render_dashboard returns 1 when a monitoring function is missing"

# =============================================================================
section "show_dashboard (refresh loop and CTRL+C)"
# =============================================================================

# start_dashboard_bg OUT ERR RESULT
# Runs show_dashboard as a background job in its own process group, so that
# SIGINT can be delivered to it exactly like pressing CTRL+C in a terminal.
start_dashboard_bg() {
    set -m
    (
        show_dashboard > "$1" 2> "$2" < /dev/null
        printf 'rc=%s\n' "$?" > "$3"
        printf 'trap=%s\n' "$(trap -p INT)" >> "$3"
    ) &
    BG_PID=$!
    set +m
}

send_ctrl_c() {
    kill -INT -- "-$BG_PID" 2>/dev/null
    wait "$BG_PID" 2>/dev/null
}

# Refresh every 1 second for ~3.5 seconds, then CTRL+C
setup_env
fake_process 4242 running 5 1 sleep 1000
PP_REFRESH_INTERVAL=1
start_dashboard_bg "$TMP_ROOT/loop.out" "$TMP_ROOT/loop.err" "$TMP_ROOT/loop.res"
sleep 3.5
send_ctrl_c

frames="$(grep -c 'ProcPilot Dashboard |' "$TMP_ROOT/loop.out")"
assert_between 3 5 "$frames" "dashboard refreshes at the configured interval (1s -> ~4 frames in 3.5s)"
assert_contains "$(cat "$TMP_ROOT/loop.out")" "4242" "managed process visible in live output"
assert_contains "$(cat "$TMP_ROOT/loop.res")" "rc=0" "CTRL+C exits with status 0"
assert_eq "trap=" "$(grep '^trap=' "$TMP_ROOT/loop.res")" "CTRL+C handler removed after exit"
assert_contains "$(cat "$TMP_ROOT/loop.out")" "ProcPilot dashboard closed." "goodbye message printed"
assert_contains "$(cat "$PP_APP_LOG")" "[INFO] Dashboard opened (refresh interval: 1s)" "dashboard start logged"
assert_contains "$(cat "$PP_APP_LOG")" "[INFO] Dashboard closed by user" "dashboard exit logged"
assert_eq "" "$(cat "$TMP_ROOT/loop.err")" "nothing printed to stderr during a normal run"

# Default interval is 2 seconds
setup_env
start_dashboard_bg "$TMP_ROOT/def.out" "$TMP_ROOT/def.err" "$TMP_ROOT/def.res"
sleep 4.5
send_ctrl_c
frames="$(grep -c 'ProcPilot Dashboard |' "$TMP_ROOT/def.out")"
assert_between 2 3 "$frames" "default refresh interval is 2 seconds (~3 frames in 4.5s)"
assert_contains "$(cat "$TMP_ROOT/def.out")" "refresh: 2s" "interval shown in header"

# SIGTERM is also handled cleanly
setup_env
PP_REFRESH_INTERVAL=1
start_dashboard_bg "$TMP_ROOT/term.out" "$TMP_ROOT/term.err" "$TMP_ROOT/term.res"
sleep 1.5
kill -TERM -- "-$BG_PID" 2>/dev/null
wait "$BG_PID" 2>/dev/null
assert_contains "$(cat "$TMP_ROOT/term.res")" "rc=0" "SIGTERM exits cleanly with status 0"

# Time spent rendering is subtracted from the wait
setup_env
PP_REFRESH_INTERVAL=1
STUB_SLOW_SECONDS=0.7
use_slow_stub() {
    get_system_resources() {
        sleep "$STUB_SLOW_SECONDS"
        PP_SYSTEM_CPU=10 PP_SYSTEM_RAM_USED=1 PP_SYSTEM_RAM_TOTAL=2 PP_SYSTEM_RAM_PERCENT=50
    }
}
set -m
(
    use_slow_stub
    check_resources() { 
        get_system_resources
        PP_RESOURCE_WARNING="" 
    }
    show_dashboard > "$TMP_ROOT/slow.out" 2>/dev/null < /dev/null
) &
BG_PID=$!
set +m
sleep 4.5
send_ctrl_c
frames="$(grep -c 'ProcPilot Dashboard |' "$TMP_ROOT/slow.out")"
assert_ge 4 "$frames" "slow monitoring does not stretch the refresh interval (>=4 frames in 4.5s)"

# Warning is logged once when it appears and once when it clears
setup_env
PP_REFRESH_INTERVAL=0.3
STUB_WARNING="RAM usage 91% is above the 80% threshold"
set -m
(
    # Warning for the first ~1s, then it clears.
    end_at=$(( ${EPOCHREALTIME//[!0-9]/} + 1000000 ))
    check_resources() {
        get_system_resources
        if [ "${EPOCHREALTIME//[!0-9]/}" -lt "$end_at" ]; then
            PP_RESOURCE_WARNING="$STUB_WARNING"
        else
            PP_RESOURCE_WARNING=""
        fi
    }
    show_dashboard > /dev/null 2>&1 < /dev/null
) &
BG_PID=$!
set +m
sleep 2.2
send_ctrl_c
assert_eq 1 "$(grep -c '\[WARNING\] Dashboard resource warning: RAM usage 91%' "$PP_APP_LOG")" \
    "resource warning logged once, not on every refresh"
assert_eq 1 "$(grep -c 'back below warning thresholds' "$PP_APP_LOG")" "warning clearing logged once"

# Invalid configuration
setup_env
for bad in abc 0 -1 1.5.2; do
    PP_REFRESH_INTERVAL="$bad"
    show_dashboard > /dev/null 2>&1 < /dev/null
    assert_eq 1 "$?" "show_dashboard rejects PP_REFRESH_INTERVAL='$bad'"
done
assert_contains "$(cat "$PP_APP_LOG")" "[ERROR] Dashboard not started" "invalid interval logged as ERROR"
PP_REFRESH_INTERVAL=2

show_dashboard extra > /dev/null 2>&1 < /dev/null
assert_eq 1 "$?" "show_dashboard rejects arguments"

( unset -f check_resources; show_dashboard > /dev/null 2>&1 < /dev/null )
assert_eq 1 "$?" "show_dashboard refuses to start when a monitoring function is missing"

# =============================================================================
section "Live terminal (real CTRL+C through a pseudo-terminal)"
# =============================================================================
if command -v python3 >/dev/null 2>&1; then
    setup_env
    fake_process 5151 running 2 1 sleep 1000
    cat > "$TMP_ROOT/pty_run.sh" <<EOF
source "$PROJECT_DIR/src/logger.sh"
source "$PROJECT_DIR/src/dashboard.sh"
$(declare -f get_system_resources check_resources get_process_counts get_process_info refresh_process_state)
PP_PROCESSES_DIR="$PP_PROCESSES_DIR"
PP_APP_LOG="$PP_APP_LOG"
PP_REFRESH_INTERVAL=1
PP_CPU_WARNING_THRESHOLD=80
PP_RAM_WARNING_THRESHOLD=80
STUB_SYSTEM_CPU=91 STUB_RAM_USED=10 STUB_RAM_TOTAL=20 STUB_RAM_PERCENT=50 STUB_WARNING=""
show_dashboard
echo "EXIT_STATUS=\$?"
stty -a | grep -o ' echo ' >/dev/null && echo "ECHO_RESTORED"
EOF
    pty_out="$(python3 - "$TMP_ROOT/pty_run.sh" <<'PYEOF'
import os, pty, sys, time, select, struct, fcntl, termios
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm"
    os.execvp("bash", ["bash", sys.argv[1]])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
buf = b""
def pump(seconds):
    global buf
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            buf += data
pump(2.5)
os.write(fd, b"\x03")          # CTRL+C, exactly like the keyboard
pump(2.0)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.stdout.write(buf.decode("utf-8", "replace"))
PYEOF
)"
    assert_contains "$pty_out" $'\033[?1049h' "live mode switches to the alternate screen"
    assert_contains "$pty_out" $'\033[?25l' "cursor hidden while running"
    assert_contains "$pty_out" "5151" "process shown on the live screen"
    assert_contains "$pty_out" $'\033[31m[' "CPU bar shown in red above the threshold"
    assert_contains "$pty_out" $'\033[?25h\033[?1049l' "CTRL+C restores cursor and normal screen"
    assert_contains "$pty_out" "EXIT_STATUS=0" "CTRL+C in a real terminal returns 0"
    assert_contains "$pty_out" "ECHO_RESTORED" "terminal echo restored after exit"
    assert_not_contains "$pty_out" "^C" "no stray ^C printed on exit"
else
    skip "real terminal CTRL+C test" "python3 not installed"
fi

# =============================================================================
printf '\nResult: %d passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
