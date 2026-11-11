#!/usr/bin/env bash
#
# src/cli.sh - ProcPilot command-line interface
# Owner:  Muhammad Shahid Raza
# Provides: main(), show_help()
#
# The CLI parses the user command, validates its arguments and routes the
# request to the module function that owns it (Section 6.6). Sourcing this
# file must not execute any workflow: it only defines functions.

# Internal helper: print a CLI error on standard error.
_cli_error() {
    printf 'procpilot: %s\n' "$*" >&2
}

# Internal helper: print the short usage line on standard error.
_cli_usage() {
    printf 'usage: procpilot.sh COMMAND [ARGUMENTS...]\n' >&2
    printf "Try 'procpilot.sh help' for the full command list.\n" >&2
}

# show_help
# Display the available commands and their usage.
show_help() {
    cat <<'EOF'
ProcPilot - command-line process management tool

Usage:
  procpilot.sh COMMAND [ARGUMENTS...]

Commands:
  run COMMAND [ARGUMENTS...]   Start COMMAND as a managed background process
  list                         List every ProcPilot-managed process
  stop PID                     Stop the managed process identified by PID
  dashboard                    Show the live terminal dashboard
  logs [NUMBER]                Show recent log entries (default: 20 lines)
  help                         Show this help text

Examples:
  procpilot.sh run sleep 60
  procpilot.sh run ping -c 4 127.0.0.1
  procpilot.sh list
  procpilot.sh stop 4242
  procpilot.sh logs 50
EOF
}

# main "$@"
# Receive the command-line arguments, parse the requested command, route it to
# the appropriate module function and handle invalid commands and arguments.
# Returns 0 on success and non-zero on failure.
main() {
    local command

    if (($# == 0)); then
        show_help
        return 0
    fi

    command=$1
    shift

    case $command in
        run)
            if (($# == 0)); then
                _cli_error "run requires a command to execute"
                printf 'usage: procpilot.sh run COMMAND [ARGUMENTS...]\n' >&2
                return 1
            fi
            # start_process() prints only the managed PID on standard output.
            start_process "$@"
            ;;
        list)
            if (($# > 0)); then
                _cli_error "list does not accept arguments"
                _cli_usage
                return 1
            fi
            list_managed_processes
            ;;
        stop)
            if (($# == 0)); then
                _cli_error "stop requires a process PID"
                printf 'usage: procpilot.sh stop PID\n' >&2
                return 1
            fi
            if (($# > 1)); then
                _cli_error "stop accepts exactly one PID"
                printf 'usage: procpilot.sh stop PID\n' >&2
                return 1
            fi
            if [[ ! $1 =~ ^[0-9]+$ ]] || ((10#$1 < 1)); then
                _cli_error "invalid PID '$1': expected a positive integer"
                return 1
            fi
            stop_process "$1"
            ;;
        dashboard)
            if (($# > 0)); then
                _cli_error "dashboard does not accept arguments"
                _cli_usage
                return 1
            fi
            show_dashboard
            ;;
        logs)
            if (($# > 1)); then
                _cli_error "logs accepts at most one NUMBER argument"
                printf 'usage: procpilot.sh logs [NUMBER]\n' >&2
                return 1
            fi
            if (($# == 1)); then
                 if [[ ! $1 =~ ^[0-9]+$ ]] || ((10#$1 < 1)); then
                     _cli_error "invalid NUMBER '$1': expected a positive integer"
                     return 1
                 fi
            fi
            show_logs "$@"
            ;;
        help | -h | --help)
            show_help
            ;;
        *)
            _cli_error "unknown command '$command'"
            _cli_usage
            return 1
            ;;
    esac
}
