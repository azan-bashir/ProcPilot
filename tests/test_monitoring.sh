#!/bin/bash
# tests/test_monitoring.sh
# Shaheer — Process Monitoring and Resource Management
#
# Covers:
#   refresh_process_state
#   get_process_info
#   get_process_counts
#   get_system_resources
#   check_resources
#
# Usage: bash tests/test_monitoring.sh   (from project root)
#
# Safe to run repeatedly: everything happens in a temp sandbox,
# so the real state/ and logs/ dirs are never touched.

set -u

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_SCRIPT_DIR/.." && pwd)"

TESTS_PASSED=0
TESTS_FAILED=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

assert_eq() {
    local desc="$1" exp="$2" act="$3"
    if [[ "$exp" == "$act" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$exp', got '$act')"
    fi
}

assert_nonzero() {
    local desc="$1"; shift
    "$@" >/dev/null 2>&1
    local rc=$?
    if (( rc != 0 )); then pass "$desc"; else fail "$desc (expected nonzero rc)"; fi
}

assert_zero() {
    local desc="$1"; shift
    "$@" >/dev/null 2>&1
    local rc=$?
    if (( rc == 0 )); then pass "$desc"; else fail "$desc (expected 0 rc, got $rc)"; fi
}

assert_nonempty() {
    local desc="$1" val="$2"
    if [[ -n "$val" ]]; then pass "$desc"; else fail "$desc (expected non-empty)"; fi
}

assert_empty() {
    local desc="$1" val="$2"
    if [[ -z "$val" ]]; then pass "$desc"; else fail "$desc (expected empty, got '$val')"; fi
}

TEST_TMP="$(mktemp -d -t procpilot-monitor-test.XXXXXX)" || exit 1
RUNNING_PID=""
RUNNING2=""

cleanup() {
    [[ -n "$RUNNING_PID" ]] && { kill "$RUNNING_PID" 2>/dev/null; wait "$RUNNING_PID" 2>/dev/null; }
    [[ -n "$RUNNING2"   ]] && { kill "$RUNNING2"   2>/dev/null; wait "$RUNNING2"   2>/dev/null; }
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mkdir -p "$TEST_TMP/state/processes" "$TEST_TMP/logs"

cat > "$TEST_TMP/config.sh" <<EOF
PP_ROOT_DIR="$TEST_TMP"
PP_STATE_DIR="$TEST_TMP/state"
PP_PROCESSES_DIR="$TEST_TMP/state/processes"
PP_LOG_DIR="$TEST_TMP/logs"
PP_APP_LOG="$TEST_TMP/logs/procpilot.log"
PP_CPU_WARNING_THRESHOLD=80
PP_RAM_WARNING_THRESHOLD=80
PP_REFRESH_INTERVAL=2
EOF

cd "$TEST_TMP" || exit 1

# Load temporary test configuration before modules
source "$TEST_TMP/config.sh"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/src/monitor.sh"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/src/resource_manager.sh"

make_state() {
    local pid="$1" status="$2" code="$3" stop="$4" cmd="$5"
    local dir="$PP_PROCESSES_DIR/$pid"
    mkdir -p "$dir"
    printf '%s\n' "$pid"    > "$dir/pid.txt"
    printf '%s\n' "$cmd"    > "$dir/command.txt"
    printf '%s\n' "$status" > "$dir/status.txt"
    printf '%s\n' "$code"   > "$dir/exit_code.txt"
    [[ "$stop" == "1" ]] && touch "$dir/stop_requested.txt"
    return 0
}

reset_processes() { rm -rf "$PP_PROCESSES_DIR"/* 2>/dev/null; true; }

echo
echo "=== refresh_process_state ==="

# 1) live process -> running
sleep 30 & RUNNING_PID=$!
make_state "$RUNNING_PID" running "" 0 "sleep 30"
assert_zero "refresh running: returns 0" refresh_process_state "$RUNNING_PID"
assert_eq   "refresh running: status"    "running" "$PP_PROCESS_STATUS"
kill "$RUNNING_PID" 2>/dev/null; wait "$RUNNING_PID" 2>/dev/null; RUNNING_PID=""

# 2) exit 0 -> completed
bash -c 'exit 0' & pid=$!; wait "$pid"
make_state "$pid" running "0" 0 "bash -c 'exit 0'"
assert_zero "refresh completed: returns 0" refresh_process_state "$pid"
assert_eq   "refresh completed: status"    "completed" "$PP_PROCESS_STATUS"

# 3) exit 1 -> failed
bash -c 'exit 1' & pid=$!; wait "$pid" 2>/dev/null
make_state "$pid" running "1" 0 "bash -c 'exit 1'"
refresh_process_state "$pid" >/dev/null 2>&1
assert_eq   "refresh failed: status"       "failed" "$PP_PROCESS_STATUS"

# 4) stop_requested + exited -> stopped
bash -c 'sleep 5' & pid=$!
make_state "$pid" running "143" 1 "bash -c 'sleep 5'"
touch "$PP_PROCESSES_DIR/$pid/stop_requested.txt"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
refresh_process_state "$pid" >/dev/null 2>&1
assert_eq   "refresh stopped: status"      "stopped" "$PP_PROCESS_STATUS"

# 5) invalid inputs return nonzero
assert_nonzero "refresh empty PID returns nonzero" refresh_process_state ""
assert_nonzero "refresh abc PID returns nonzero"   refresh_process_state "abc"
assert_nonzero "refresh 0 PID returns nonzero"     refresh_process_state "0"

# 6) missing state dir returns nonzero
assert_nonzero "refresh missing state dir returns nonzero" refresh_process_state "999990"

# 7) pid.txt must match directory name
mkdir -p "$PP_PROCESSES_DIR/999988"
printf '999987\n' > "$PP_PROCESSES_DIR/999988/pid.txt"
assert_nonzero "refresh pid.txt mismatch returns nonzero" refresh_process_state "999988"

# 8) refresh persists status back to status.txt
sleep 30 & RUNNING_PID=$!
make_state "$RUNNING_PID" "bogus" "" 0 "sleep 30"
refresh_process_state "$RUNNING_PID" >/dev/null 2>&1
on_disk=$(<"$PP_PROCESSES_DIR/$RUNNING_PID/status.txt")
assert_eq   "refresh persists status to status.txt" "running" "$on_disk"
kill "$RUNNING_PID" 2>/dev/null; wait "$RUNNING_PID" 2>/dev/null; RUNNING_PID=""

echo
echo "=== get_process_info ==="

reset_processes

# live process
sleep 30 & RUNNING_PID=$!
make_state "$RUNNING_PID" running "" 0 "sleep 30"
assert_zero "info running: returns 0" get_process_info "$RUNNING_PID"
assert_eq   "info running: PID"       "$RUNNING_PID" "$PP_PROCESS_PID"
assert_eq   "info running: status"    "running"      "$PP_PROCESS_STATUS"
[[ "$PP_PROCESS_CPU" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    && pass "info running: CPU numeric ($PP_PROCESS_CPU)" \
    || fail "info running: CPU numeric ($PP_PROCESS_CPU)"
[[ "$PP_PROCESS_MEM" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    && pass "info running: MEM numeric ($PP_PROCESS_MEM)" \
    || fail "info running: MEM numeric ($PP_PROCESS_MEM)"
assert_nonempty "info running: command set" "$PP_PROCESS_COMMAND"
kill "$RUNNING_PID" 2>/dev/null; wait "$RUNNING_PID" 2>/dev/null; RUNNING_PID=""

# completed process
bash -c 'exit 0' & pid=$!; wait "$pid"
make_state "$pid" completed "0" 0 "deadproc --flag arg1"
assert_zero "info completed: returns 0" get_process_info "$pid"
assert_eq   "info completed: status"   "completed" "$PP_PROCESS_STATUS"
assert_eq   "info completed: command"  "deadproc --flag arg1" "$PP_PROCESS_COMMAND"
assert_eq   "info completed: CPU zero" "0" "$PP_PROCESS_CPU"
assert_eq   "info completed: MEM zero" "0" "$PP_PROCESS_MEM"

# failed process
bash -c 'exit 1' & pid=$!; wait "$pid" 2>/dev/null
make_state "$pid" failed "1" 0 "failproc"
get_process_info "$pid" >/dev/null 2>&1
assert_eq "info failed: status" "failed" "$PP_PROCESS_STATUS"

# invalid input
assert_nonzero "info invalid PID returns nonzero"       get_process_info "abc"
assert_nonzero "info missing state dir returns nonzero" get_process_info "999989"

echo
echo "=== get_process_counts ==="

reset_processes

# completed x1
bash -c 'exit 0' & pid=$!; wait "$pid"
make_state "$pid" completed "0" 0 "done1"

# failed x1
bash -c 'exit 1' & pid=$!; wait "$pid" 2>/dev/null
make_state "$pid" failed "1" 0 "fail1"

# stopped x1
sleep 5 & pid=$!
make_state "$pid" stopped "143" 1 "stop1"
touch "$PP_PROCESSES_DIR/$pid/stop_requested.txt"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# running x2
sleep 30 & RUNNING_PID=$!
make_state "$RUNNING_PID" running "" 0 "sleep 30"
sleep 30 & RUNNING2=$!
make_state "$RUNNING2" running "" 0 "sleep 30"

assert_zero "counts: returns 0"      get_process_counts
assert_eq   "counts: running"        "2" "$PP_RUNNING_COUNT"
assert_eq   "counts: completed"      "1" "$PP_COMPLETED_COUNT"
assert_eq   "counts: failed"         "1" "$PP_FAILED_COUNT"
assert_eq   "counts: stopped"        "1" "$PP_STOPPED_COUNT"

kill "$RUNNING_PID" "$RUNNING2" 2>/dev/null
wait "$RUNNING_PID" 2>/dev/null
wait "$RUNNING2" 2>/dev/null
RUNNING_PID=""; RUNNING2=""

# empty directory
reset_processes
get_process_counts >/dev/null 2>&1
assert_eq "counts empty: running"   "0" "$PP_RUNNING_COUNT"
assert_eq "counts empty: completed" "0" "$PP_COMPLETED_COUNT"
assert_eq "counts empty: failed"    "0" "$PP_FAILED_COUNT"
assert_eq "counts empty: stopped"   "0" "$PP_STOPPED_COUNT"

echo
echo "=== get_system_resources ==="

assert_zero "sys: resource collection returns 0" get_system_resources
assert_nonempty "sys: CPU set"         "$PP_SYSTEM_CPU"
assert_nonempty "sys: RAM total set"   "$PP_SYSTEM_RAM_TOTAL"
assert_nonempty "sys: RAM used set"    "$PP_SYSTEM_RAM_USED"
assert_nonempty "sys: RAM percent set" "$PP_SYSTEM_RAM_PERCENT"

(( PP_SYSTEM_RAM_TOTAL > 0 )) \
    && pass "sys: RAM total > 0 (${PP_SYSTEM_RAM_TOTAL} MB)" \
    || fail "sys: RAM total > 0 (${PP_SYSTEM_RAM_TOTAL})"
(( PP_SYSTEM_RAM_USED >= 0 )) \
    && pass "sys: RAM used >= 0 (${PP_SYSTEM_RAM_USED} MB)" \
    || fail "sys: RAM used >= 0 (${PP_SYSTEM_RAM_USED} MB)"
(( PP_SYSTEM_CPU >= 0 && PP_SYSTEM_CPU <= 100 )) \
    && pass "sys: CPU in 0..100 (${PP_SYSTEM_CPU}%)" \
    || fail "sys: CPU in 0..100 (${PP_SYSTEM_CPU})"
(( PP_SYSTEM_RAM_PERCENT >= 0 && PP_SYSTEM_RAM_PERCENT <= 100 )) \
    && pass "sys: RAM% in 0..100 (${PP_SYSTEM_RAM_PERCENT}%)" \
    || fail "sys: RAM% in 0..100 (${PP_SYSTEM_RAM_PERCENT})"

echo
echo "=== check_resources ==="

# Under threshold
PP_CPU_WARNING_THRESHOLD=101
PP_RAM_WARNING_THRESHOLD=101
assert_zero "check: returns 0 under threshold" check_resources
assert_empty "check: warning empty when under threshold" "$PP_RESOURCE_WARNING"

# Over threshold
PP_CPU_WARNING_THRESHOLD=0
PP_RAM_WARNING_THRESHOLD=0
assert_zero "check: returns 0 over threshold" check_resources
assert_nonempty "check: warning set when over threshold" "$PP_RESOURCE_WARNING"

# Restore defaults
PP_CPU_WARNING_THRESHOLD=80
PP_RAM_WARNING_THRESHOLD=80

echo
echo "================================"
printf "Passed: %d   Failed: %d\n" "$TESTS_PASSED" "$TESTS_FAILED"
echo "================================"

(( TESTS_FAILED == 0 ))
