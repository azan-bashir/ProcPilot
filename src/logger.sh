#!/bin/bash
# =============================================================================
# ProcPilot - src/logger.sh
# Owner : Abdul Rehman (Dashboard, Logging and Reporting)
#
# Shared application logger used by every ProcPilot module.
#
# Public functions (fixed contract, spec section 10):
#   write_log LEVEL MESSAGE   Append one timestamped entry to PP_APP_LOG.
#   show_logs [NUMBER]        Print the last NUMBER entries (default 20).
#
# Reads (owned by Shahid, set by load_config):
#   PP_APP_LOG                Main application log file path.
#
# Log entry format (one entry per line):
#   [YYYY-MM-DD HH:MM:SS] [LEVEL] message
#
# This file only defines functions. Sourcing it does not run anything.
# =============================================================================

# Default number of lines shown by show_logs when NUMBER is not given.
# Private to this module (not a shared contract variable).
_PP_LOG_DEFAULT_LINES=20

# -----------------------------------------------------------------------------
# write_log LEVEL MESSAGE
#
# LEVEL   : INFO, WARNING or ERROR (case-insensitive; stored in uppercase).
# MESSAGE : Text of the entry. If the caller passes several words without
#           quoting them, they are joined with single spaces.
#
# Newlines and tabs inside MESSAGE are replaced with spaces so that every
# entry stays on exactly one line (show_logs counts entries by line).
#
# Returns 0 on success, 1 on invalid arguments, 2 if the log cannot be written.
# Errors are reported on standard error, never on standard output, so callers
# such as start_process() can keep their stdout clean.
# -----------------------------------------------------------------------------
write_log() {
    local level="${1:-}"
    local raw_level="${1:-}"
    local message
    local timestamp
    local log_dir

    if [ "$#" -lt 2 ]; then
        printf 'write_log: usage: write_log LEVEL MESSAGE\n' >&2
        return 1
    fi

    shift
    message="$*"

    # Normalise and validate the level.
    level="${level^^}"
    case "$level" in
        INFO|WARNING|ERROR) ;;
        *)
            printf 'write_log: invalid level "%s" (expected INFO, WARNING or ERROR)\n' "$raw_level" >&2
            return 1
            ;;
    esac

    if [ -z "$message" ]; then
        printf 'write_log: MESSAGE must not be empty\n' >&2
        return 1
    fi

    if [ -z "${PP_APP_LOG:-}" ]; then
        printf 'write_log: PP_APP_LOG is not set (was load_config called?)\n' >&2
        return 2
    fi

    # Keep each entry on a single line.
    message="${message//$'\r'/ }"
    message="${message//$'\n'/ }"
    message="${message//$'\t'/ }"

    # load_config normally creates the log directory; create it if missing so
    # that logging never fails just because the directory was removed.
    log_dir="$(dirname -- "$PP_APP_LOG")"
    if [ ! -d "$log_dir" ]; then
        if ! mkdir -p -- "$log_dir" 2>/dev/null; then
            printf 'write_log: cannot create log directory "%s"\n' "$log_dir" >&2
            return 2
        fi
    fi

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # A single short append is atomic on Linux, so concurrent ProcPilot
    # processes can log safely without corrupting each other's lines.
    if ! printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$PP_APP_LOG" 2>/dev/null; then
        printf 'write_log: cannot write to "%s"\n' "$PP_APP_LOG" >&2
        return 2
    fi

    return 0
}

# -----------------------------------------------------------------------------
# show_logs [NUMBER]
#
# Displays the most recent application log entries.
# NUMBER : positive whole number of entries to show (default 20).
#
# When standard output is a terminal, WARNING entries are shown in yellow and
# ERROR entries in red (set NO_COLOR=1 to disable). Output sent to a file or a
# pipe is always plain text.
#
# Returns 0 on success (including "no entries yet"), 1 on invalid arguments,
# 2 if the log file exists but cannot be read.
# -----------------------------------------------------------------------------
show_logs() {
    local number="${1:-$_PP_LOG_DEFAULT_LINES}"

    if [ "$#" -gt 1 ]; then
        printf 'Usage: logs [NUMBER]\n' >&2
        return 1
    fi

    # Accept only positive whole numbers (leading zeros are stripped).
    if ! [[ "$number" =~ ^[0-9]+$ ]] || [ "$((10#$number))" -lt 1 ]; then
        printf 'logs: NUMBER must be a positive whole number, got "%s"\n' "$number" >&2
        return 1
    fi
    number="$((10#$number))"

    if [ -z "${PP_APP_LOG:-}" ]; then
        printf 'logs: PP_APP_LOG is not set (was load_config called?)\n' >&2
        return 2
    fi
    if [ ! -e "$PP_APP_LOG" ]; then
        printf 'No log entries yet.\n'
        return 0
    fi

    if [ ! -r "$PP_APP_LOG" ]; then
        printf 'logs: cannot read "%s"\n' "$PP_APP_LOG" >&2
        return 2
    fi

    if [ ! -s "$PP_APP_LOG" ]; then
        printf 'No log entries yet.\n'
        return 0
    fi

    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        if ! tail -n "$number" -- "$PP_APP_LOG" | awk '
            / \[ERROR\] /   { printf "\033[31m%s\033[0m\n", $0; next }
            / \[WARNING\] / { printf "\033[33m%s\033[0m\n", $0; next }
                            { print }'
        then
            printf 'logs: failed to read log entries\n' >&2
            return 2
        fi
    else
        if ! tail -n "$number" -- "$PP_APP_LOG"; then
            printf 'logs: failed to read log entries\n' >&2
            return 2
        fi
    fi

    return 0
}
