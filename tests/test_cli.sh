#!/usr/bin/env bash
#
# tests/test_cli.sh - Tests for the ProcPilot configuration and CLI modules
# Owner: Muhammad Shahid Raza
#
# Covers: configuration loading, defaults, overrides, validation, CLI routing,
# argument validation, help output and side-effect-free sourcing.
#
# Every check runs inside a throw-away sandbox so that the real state/ and
# logs/ directories are never touched. Usage: bash tests/test_cli.sh

set -u

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX=""
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    if [[ -n $SANDBOX && -d $SANDBOX ]]; then
        rm -rf -- "$SANDBOX"
    fi
}
trap cleanup EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$1"
    if (($# > 1)); then
        printf '      %s\n' "$2"
    fi
}

# Create a fresh sandbox containing the modules under test.
new_sandbox() {
    if [[ -n $SANDBOX && -d $SANDBOX ]]; then
        rm -rf -- "$SANDBOX"
    fi

    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/procpilot-cli-test.XXXXXX")" || {
        printf 'FATAL: unable to create a temporary sandbox\n' >&2
        exit 1
    }

    mkdir -p -- "$SANDBOX/src" "$SANDBOX/config" "$SANDBOX/tests"
    cp -- "$PROJECT_ROOT/src/config.sh" "$SANDBOX/src/config.sh"
    cp -- "$PROJECT_ROOT/src/cli.sh" "$SANDBOX/src/cli.sh"
}

# Write stdin to the sandbox configuration file.
write_config() {
    cat >"$SANDBOX/config/settings.conf"
}

# Run a Bash snippet with the sandbox as the working directory.
sandbox_run() {
    (cd -- "$SANDBOX" && bash -c "$1")
}

# Stub implementations of the functions owned by the other team members.
STUBS='
start_process() { local a; printf "START[%s]" "$#"; for a in "$@"; do printf "<%s>" "$a"; done; printf "\n"; }
stop_process() { printf "STOP[%s]\n" "${1-}"; }
list_managed_processes() { printf "LIST\n"; }
show_dashboard() { printf "DASH\n"; }
show_logs() { printf "LOGS[%s]\n" "${1-}"; }
'

# Report the result of a CLI invocation.
check_cli() {
    local description=$1 expected_status=$2 expected_stdout=$3
    local snippet=$4
    local output status

    output="$(sandbox_run "source ./src/cli.sh; $STUBS
$snippet" 2>&1)"
    status=$?

    if [[ $status -ne $expected_status ]]; then
        fail "$description" "expected exit $expected_status, got $status; output: $output"
        return
    fi

    if [[ -n $expected_stdout && $output != *"$expected_stdout"* ]]; then
        fail "$description" "expected output to contain '$expected_stdout'; got: $output"
        return
    fi

    pass "$description"
}

printf '== Configuration tests ==\n'

# --- 1. load_config sets every shared path and creates the directories. -----
new_sandbox
write_config <<'EOF'
PP_REFRESH_INTERVAL=2
PP_CPU_WARNING_THRESHOLD=80
PP_RAM_WARNING_THRESHOLD=80
EOF

expected_root="$(cd -- "$SANDBOX" && pwd -P)"
actual_paths="$(sandbox_run 'source ./src/config.sh || exit 9
load_config || exit 8
printf "%s\n" "$PP_ROOT_DIR" "$PP_STATE_DIR" "$PP_PROCESSES_DIR" "$PP_LOG_DIR" "$PP_APP_LOG"')"
expected_paths="$(printf '%s\n' \
    "$expected_root" \
    "$expected_root/state" \
    "$expected_root/state/processes" \
    "$expected_root/logs" \
    "$expected_root/logs/procpilot.log")"

if [[ $actual_paths == "$expected_paths" ]]; then
    pass "load_config sets PP_ROOT_DIR and the shared directory paths"
else
    fail "load_config sets PP_ROOT_DIR and the shared directory paths" \
        "expected: $expected_paths | actual: $actual_paths"
fi

for dir in "$SANDBOX/state" "$SANDBOX/state/processes" "$SANDBOX/logs" "$SANDBOX/logs/processes"; do
    if [[ -d $dir ]]; then
        pass "load_config creates ${dir#"$SANDBOX/"}/"
    else
        fail "load_config creates ${dir#"$SANDBOX/"}/"
    fi
done

if [[ -f $SANDBOX/logs/procpilot.log ]]; then
    pass "load_config creates logs/procpilot.log"
else
    fail "load_config creates logs/procpilot.log"
fi

# --- 2. Built-in defaults apply when settings.conf has no overrides. --------
new_sandbox
write_config <<'EOF'
# Only comments here.
EOF

values="$(sandbox_run 'source ./src/config.sh || exit 9
load_config || exit 8
printf "%s %s %s\n" "$PP_REFRESH_INTERVAL" "$PP_CPU_WARNING_THRESHOLD" "$PP_RAM_WARNING_THRESHOLD"')"

if [[ $values == "2 80 80" ]]; then
    pass "load_config applies the default values 2 / 80 / 80"
else
    fail "load_config applies the default values 2 / 80 / 80" "got: $values"
fi

# --- 3. settings.conf overrides defaults (comments, quotes, CRLF, unknown). -
new_sandbox
printf '# overrides\r\nPP_REFRESH_INTERVAL="5"\r\nPP_CPU_WARNING_THRESHOLD=90\r\n\r\nUNKNOWN_KEY=1\r\nPP_RAM_WARNING_THRESHOLD='"'"'70'"'"'\r\n' >"$SANDBOX/config/settings.conf"

values="$(sandbox_run 'source ./src/config.sh || exit 9
load_config || exit 8
printf "%s %s %s\n" "$PP_REFRESH_INTERVAL" "$PP_CPU_WARNING_THRESHOLD" "$PP_RAM_WARNING_THRESHOLD"')"

if [[ $values == "5 90 70" ]]; then
    pass "load_config reads overrides and ignores unknown keys, quotes and CRLF"
else
    fail "load_config reads overrides and ignores unknown keys, quotes and CRLF" "got: $values"
fi

# --- 4. A valid configuration passes validate_config. ----------------------
new_sandbox
write_config <<'EOF'
PP_REFRESH_INTERVAL=2
PP_CPU_WARNING_THRESHOLD=80
PP_RAM_WARNING_THRESHOLD=80
EOF

if sandbox_run 'source ./src/config.sh; load_config; validate_config' >/dev/null 2>&1; then
    pass "validate_config accepts the default configuration"
else
    fail "validate_config accepts the default configuration"
fi

# --- 5. Invalid configurations fail validate_config. ----------------------
run_invalid_case() {
    local description=$1 content=$2
    new_sandbox
    printf '%s\n' "$content" >"$SANDBOX/config/settings.conf"

    if sandbox_run 'source ./src/config.sh; load_config; validate_config' >/dev/null 2>&1; then
        fail "$description" "validate_config unexpectedly succeeded"
    else
        pass "$description"
    fi
}

run_invalid_case "validate_config rejects a CPU threshold of 0" \
    'PP_CPU_WARNING_THRESHOLD=0'
run_invalid_case "validate_config rejects a CPU threshold above 100" \
    'PP_CPU_WARNING_THRESHOLD=101'
run_invalid_case "validate_config rejects a non-numeric CPU threshold" \
    'PP_CPU_WARNING_THRESHOLD=high'
run_invalid_case "validate_config rejects a RAM threshold of 101" \
    'PP_RAM_WARNING_THRESHOLD=101'
run_invalid_case "validate_config rejects a refresh interval of 0" \
    'PP_REFRESH_INTERVAL=0'
run_invalid_case "validate_config rejects a non-numeric refresh interval" \
    'PP_REFRESH_INTERVAL=often'
run_invalid_case "validate_config rejects an empty value" \
    'PP_REFRESH_INTERVAL='

# --- 6. validate_config fails when load_config was never called. -----------
new_sandbox
if sandbox_run 'source ./src/config.sh; validate_config' >/dev/null 2>&1; then
    fail "validate_config fails when the configuration is not loaded"
else
    pass "validate_config fails when the configuration is not loaded"
fi

printf '\n== CLI tests ==\n'

# --- 7. Sourcing the CLI must not execute anything. ------------------------
new_sandbox
output="$(sandbox_run 'source ./src/cli.sh')"
status=$?
if [[ $status -eq 0 && -z $output ]]; then
    pass "sourcing src/cli.sh has no side effects"
else
    fail "sourcing src/cli.sh has no side effects" "exit $status, output: $output"
fi

# --- 8. help and no-argument invocations show the help text. --------------
check_cli "help prints the command list" 0 "run COMMAND" 'main help'
check_cli "no arguments print the help text" 0 "Usage:" 'main'

output="$(sandbox_run "source ./src/cli.sh; $STUBS
main help" 2>&1)"
if [[ $output == *"stop PID"* && $output == *"logs [NUMBER]"* && $output == *"dashboard"* ]]; then
    pass "show_help lists every documented command"
else
    fail "show_help lists every documented command" "got: $output"
fi

# --- 9. Command routing. -------------------------------------------------
check_cli "run routes to start_process" 0 "START[3]<echo><hello><world>" 'main run echo hello world'
check_cli "run preserves quoted argument boundaries" 0 "START[2]<a b><c>" 'main run "a b" c'
check_cli "list routes to list_managed_processes" 0 "LIST" 'main list'
check_cli "stop routes to stop_process" 0 "STOP[4242]" 'main stop 4242'
check_cli "dashboard routes to show_dashboard" 0 "DASH" 'main dashboard'
check_cli "logs without NUMBER routes to show_logs" 0 "LOGS[]" 'main logs'
check_cli "logs passes the requested line count" 0 "LOGS[50]" 'main logs 50'

# --- 10. Invalid commands and arguments are rejected. ---------------------
check_cli "an unknown command fails" 1 "unknown command" 'main frobnicate'
check_cli "run without a command fails" 1 "run requires a command" 'main run'
check_cli "list with an argument fails" 1 "list does not accept arguments" 'main list extra'
check_cli "stop without a PID fails" 1 "stop requires a process PID" 'main stop'
check_cli "stop with a non-numeric PID fails" 1 "invalid PID" 'main stop abc'
check_cli "stop with two PIDs fails" 1 "exactly one PID" 'main stop 1 2'
check_cli "dashboard with an argument fails" 1 "dashboard does not accept arguments" 'main dashboard now'
check_cli "logs with a non-numeric count fails" 1 "invalid NUMBER" 'main logs ten'
check_cli "logs with too many arguments fails" 1 "at most one NUMBER" 'main logs 1 2'

# A rejected command must never call the module function behind it.
new_sandbox
output="$(sandbox_run "source ./src/cli.sh; $STUBS
main run" 2>/dev/null)"
if [[ -z $output ]]; then
    pass "a rejected run does not call start_process"
else
    fail "a rejected run does not call start_process" "got: $output"
fi

printf '\n== Summary ==\n'
printf 'Passed: %d\n' "$PASS_COUNT"
printf 'Failed: %d\n' "$FAIL_COUNT"

if ((FAIL_COUNT > 0)); then
    exit 1
fi

exit 0
