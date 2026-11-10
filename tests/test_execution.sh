
#!/usr/bin/env bash

# ProcPilot Execution Tests

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$PROJECT_ROOT/src/executor.sh"
source "$PROJECT_ROOT/src/manager.sh"

PASSED=0
FAILED=0

pass() {
    echo "PASS: $1"
    ((PASSED++))
}

fail() {
    echo "FAIL: $1"
    ((FAILED++))
}

echo "Starting ProcPilot execution tests..."
echo

# Test 1: Start a valid process
pid="$(start_process sleep 3)"

if [[ "$pid" =~ ^[0-9]+$ ]] && [[ -f "$PROJECT_ROOT/state/processes/$pid/pid.txt" ]]; then
    pass "Valid process starts"
else
    fail "Valid process starts"
fi

# Test 2: Check running status
status="$(cat "$PROJECT_ROOT/state/processes/$pid/status.txt")"

if [[ "$status" == "running" ]]; then
    pass "Process runs in background"
else
    fail "Process runs in background"
fi

# Test 3: Wait for completion
for ((i=0; i<30; i++)); do
    status="$(cat "$PROJECT_ROOT/state/processes/$pid/status.txt")"
    [[ "$status" != "running" ]] && break
    sleep 0.2
done

if [[ "$status" == "completed" ]]; then
    pass "Process completes successfully"
else
    fail "Process completes successfully"
fi

# Test 4: Start and stop a managed process
stop_pid="$(start_process sleep 30)"

if stop_process "$stop_pid" >/dev/null 2>&1; then
    for ((i=0; i<30; i++)); do
        status="$(cat "$PROJECT_ROOT/state/processes/$stop_pid/status.txt")"
        [[ "$status" == "stopped" ]] && break
        sleep 0.2
    done

    if [[ "$status" == "stopped" ]]; then
        pass "Managed process stops"
    else
        fail "Managed process stops"
    fi
else
    fail "Stop request accepted"
fi

# Test 5: Reject invalid command
if start_process invalid_command_xyz >/dev/null 2>&1; then
    fail "Invalid command rejected"
else
    pass "Invalid command rejected"
fi

# Test 6: Reject unmanaged PID
if stop_process 1 >/dev/null 2>&1; then
    fail "Unmanaged PID rejected"
else
    pass "Unmanaged PID rejected"
fi

echo
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"

[[ "$FAILED" -eq 0 ]]
# Test 7: List managed processes
list_output="$(list_managed_processes)"

if [[ "$list_output" == *"$pid"* ]]; then
    pass "Managed processes are listed"
else
    fail "Managed processes are listed"
fi

echo
echo "Tests passed: $PASSED"
echo "Tests failed: $FAILED"

[[ "$FAILED" -eq 0 ]]