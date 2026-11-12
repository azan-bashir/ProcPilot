#!/bin/bash
# =============================================================================
# ProcPilot - src/dashboard.sh
# Owner : Abdul Rehman (Dashboard, Logging and Reporting)
#
# Live terminal dashboard inspired by the Linux `top` command.
#
# Public functions (fixed contract, spec section 10):
#   show_dashboard     Run the live loop; redraw every PP_REFRESH_INTERVAL
#                      seconds; exit cleanly on CTRL+C (or the q key).
#   render_dashboard   Draw one complete dashboard screen.
#
# This module does NOT measure anything itself. All data comes from
# Shaheer's monitoring functions, which are called directly (never through
# command substitution) so that the global variables they set are kept:
#   get_system_resources -> PP_SYSTEM_CPU, PP_SYSTEM_RAM_USED,
#                           PP_SYSTEM_RAM_TOTAL, PP_SYSTEM_RAM_PERCENT
#   check_resources      -> PP_RESOURCE_WARNING
#   get_process_counts   -> PP_RUNNING_COUNT, PP_COMPLETED_COUNT,
#                           PP_FAILED_COUNT, PP_STOPPED_COUNT
#   get_process_info PID -> PP_PROCESS_PID, PP_PROCESS_COMMAND,
#                           PP_PROCESS_CPU, PP_PROCESS_MEM, PP_PROCESS_STATUS
#   refresh_process_state PID (optional, used when available)
#
# Configuration read (owned by Shahid, set by load_config):
#   PP_PROCESSES_DIR, PP_REFRESH_INTERVAL,
#   PP_CPU_WARNING_THRESHOLD, PP_RAM_WARNING_THRESHOLD
#
# Logging: uses write_log from src/logger.sh.
#
# Names starting with _pp_dash_ / _PP_DASH_ are private to this file.
# This file only defines functions. Sourcing it does not run anything.
# =============================================================================

# Width of the CPU / RAM usage bars, in characters.
_PP_DASH_BAR_WIDTH=30

# Width of the columns printed before COMMAND in the process table:
# PID(7) + 2 + CPU%(6) + 2 + MEM%(6) + 2 + STATUS(10) + 2
_PP_DASH_TABLE_PREFIX_WIDTH=37

# -----------------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------------

# _pp_dash_check_deps FUNCTION...
# Returns 1 (with a message on stderr) if any required function is missing
# or if the configuration has not been loaded.
_pp_dash_check_deps() {
    local fn
    local -a missing=()

    for fn in "$@"; do
        declare -F "$fn" >/dev/null 2>&1 || missing+=("$fn")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'dashboard: required function(s) not loaded: %s\n' "${missing[*]}" >&2
        return 1
    fi

    if [ -z "${PP_PROCESSES_DIR:-}" ]; then
        printf 'dashboard: PP_PROCESSES_DIR is not set (was load_config called?)\n' >&2
        return 1
    fi

    return 0
}

# _pp_dash_clean_number VAR VALUE
# Stores VALUE in VAR as a plain decimal number (e.g. "12.5") or an empty
# string if VALUE is not numeric. Accepts "12,5", " 12.5 " and "12.5%".
_pp_dash_clean_number() {
    local value="${2:-}"

    value="${value//[[:space:]]/}"
    value="${value%\%}"
    value="${value/,/.}"

    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf -v "$1" '%s' "$value"
    else
        printf -v "$1" '%s' ""
    fi
}

# _pp_dash_fmt_pct VAR VALUE
# Stores VALUE formatted as "%5.1f" (e.g. " 12.5") in VAR, or "  N/A".
_pp_dash_fmt_pct() {
    local number

    _pp_dash_clean_number number "${2:-}"
    if [ -n "$number" ]; then
        LC_NUMERIC=C printf -v "$1" '%5.1f' "$number"
    else
        printf -v "$1" '%5s' 'N/A'
    fi
}

# _pp_dash_bar VAR PERCENT
# Stores a usage bar such as "[|||||||                       ]" in VAR.
_pp_dash_bar() {
    local number filled empty bar_fill bar_empty
    local width="$_PP_DASH_BAR_WIDTH"

    _pp_dash_clean_number number "${2:-}"
    number="${number%%.*}"
    [ -n "$number" ] || number=0
    number="$((10#$number))"
    [ "$number" -gt 100 ] && number=100

    filled=$(( number * width / 100 ))
    empty=$(( width - filled ))

    printf -v bar_fill '%*s' "$filled" ''
    printf -v bar_empty '%*s' "$empty" ''
    printf -v "$1" '[%s%s]' "${bar_fill// /|}" "$bar_empty"
}

# _pp_dash_level_color PERCENT THRESHOLD
# Prints nothing; sets _PP_DASH_COLOR to red when PERCENT >= THRESHOLD,
# yellow when PERCENT >= 75% of THRESHOLD, green otherwise.
_pp_dash_level_color() {
    local pct threshold

    _pp_dash_clean_number pct "${1:-}"
    _pp_dash_clean_number threshold "${2:-}"
    pct="${pct%%.*}"
    threshold="${threshold%%.*}"

    if [ -z "$pct" ] || [ -z "$threshold" ]; then
        _PP_DASH_COLOR=""
    elif [ "$((10#$pct))" -ge "$((10#$threshold))" ]; then
        _PP_DASH_COLOR="$_PP_DASH_C_RED"
    elif [ "$((10#$pct * 4))" -ge "$((10#$threshold * 3))" ]; then
        _PP_DASH_COLOR="$_PP_DASH_C_YELLOW"
    else
        _PP_DASH_COLOR="$_PP_DASH_C_GREEN"
    fi
}

# _pp_dash_status_color STATUS -> sets _PP_DASH_COLOR
_pp_dash_status_color() {
    case "${1:-}" in
        running)   _PP_DASH_COLOR="$_PP_DASH_C_GREEN" ;;
        completed) _PP_DASH_COLOR="$_PP_DASH_C_CYAN" ;;
        failed)    _PP_DASH_COLOR="$_PP_DASH_C_RED" ;;
        stopped)   _PP_DASH_COLOR="$_PP_DASH_C_YELLOW" ;;
        *)         _PP_DASH_COLOR="" ;;
    esac
}

# _pp_dash_setup_colors
# Enables ANSI colours only when stdout is a terminal, NO_COLOR is unset
# and TERM is not "dumb". Output to files and pipes stays plain text.
_pp_dash_setup_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
        _PP_DASH_C_RESET=$'\033[0m'
        _PP_DASH_C_BOLD=$'\033[1m'
        _PP_DASH_C_DIM=$'\033[2m'
        _PP_DASH_C_REV=$'\033[7m'
        _PP_DASH_C_RED=$'\033[31m'
        _PP_DASH_C_GREEN=$'\033[32m'
        _PP_DASH_C_YELLOW=$'\033[33m'
        _PP_DASH_C_CYAN=$'\033[36m'
    else
        _PP_DASH_C_RESET=""
        _PP_DASH_C_BOLD=""
        _PP_DASH_C_DIM=""
        _PP_DASH_C_REV=""
        _PP_DASH_C_RED=""
        _PP_DASH_C_GREEN=""
        _PP_DASH_C_YELLOW=""
        _PP_DASH_C_CYAN=""
    fi
    _PP_DASH_COLOR=""
}

# _pp_dash_term_size
# Sets _PP_DASH_ROWS and _PP_DASH_COLS from the terminal (default 24x80).
_pp_dash_term_size() {
    local size rows="" cols=""

    size="$(stty size 2>/dev/null)"
    if [[ "$size" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
        rows="${BASH_REMATCH[1]}"
        cols="${BASH_REMATCH[2]}"
    fi
    if ! [[ "$rows" =~ ^[1-9][0-9]*$ ]] || ! [[ "$cols" =~ ^[1-9][0-9]*$ ]]; then
        rows="$(tput lines 2>/dev/null)"
        cols="$(tput cols 2>/dev/null)"
    fi
    [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows="${LINES:-24}"
    [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols="${COLUMNS:-80}"
    [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows=24
    [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols=80

    _PP_DASH_ROWS="$rows"
    _PP_DASH_COLS="$cols"
}

# _pp_dash_emit PLAIN [COLORED]
# Appends one line to the frame being built (_PP_DASH_FRAME).
# In live mode a line wider than the terminal is cut to fit; the plain
# version is used in that case so colour codes are never cut in half.
_pp_dash_emit() {
    local plain="${1-}"
    local colored="${2-$1}"

    if [ "${_PP_DASH_LIVE:-0}" = "1" ] && [ "${#plain}" -gt "$_PP_DASH_COLS" ]; then
        _PP_DASH_FRAME+=("${plain:0:$_PP_DASH_COLS}")
    else
        _PP_DASH_FRAME+=("$colored")
    fi
}

# _pp_dash_now_us
# Sets _PP_DASH_NOW_US to the current time in microseconds, or "" if the
# shell cannot provide it (bash < 5). EPOCHREALTIME is used so no extra
# process is started on every refresh.
_pp_dash_now_us() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        _PP_DASH_NOW_US="${EPOCHREALTIME//[!0-9]/}"
    else
        _PP_DASH_NOW_US=""
    fi
}

# _pp_dash_track_warning
# Writes the resource warning to the application log when it first appears
# and an INFO entry when it clears, instead of logging it on every refresh.
_pp_dash_track_warning() {
    local current="${PP_RESOURCE_WARNING:-}"

    if [ -n "$current" ] && [ -z "$_PP_DASH_LAST_WARNING" ]; then
        write_log WARNING "Dashboard resource warning: $current"
    elif [ -z "$current" ] && [ -n "$_PP_DASH_LAST_WARNING" ]; then
        write_log INFO "Dashboard: resource usage back below warning thresholds"
    fi
    _PP_DASH_LAST_WARNING="$current"
}

# -----------------------------------------------------------------------------
# render_dashboard
#
# Renders one complete dashboard screen:
#   1. enumerates every managed process directory under PP_PROCESSES_DIR
#   2. refreshes each process state (refresh_process_state, if available)
#   3. calls get_system_resources, get_process_counts and check_resources
#   4. calls get_process_info PID for each managed process
#   5. prints system CPU/RAM, status counts, warnings and the process table
#
# When called by show_dashboard on a terminal, the screen is redrawn in
# place (no flicker) and the table is cut to fit the window. When called on
# its own, or with output redirected, it prints one plain-text snapshot.
#
# Returns 0 on success, 1 if a required function or setting is missing.
# -----------------------------------------------------------------------------
render_dashboard() {
    local pid dir line i
    local -a pids=()
    local cpu_fmt ram_fmt cpu_bar ram_bar
    local row_cpu row_mem row_status row_cmd row_pid_clean
    local cmd_width shown hidden max_rows
    local header warning_line colored_line now
    local -a warning_lines=()
    local running completed failed stopped total
    local ram_used ram_total

    if [ "$#" -ne 0 ]; then
        printf 'Usage: render_dashboard\n' >&2
        return 1
    fi

    _pp_dash_check_deps get_system_resources check_resources \
        get_process_counts get_process_info || return 1

    _pp_dash_setup_colors
    _PP_DASH_FRAME=()
    if [ "${_PP_DASH_LIVE:-0}" = "1" ]; then
        _pp_dash_term_size
    else
        _PP_DASH_ROWS=0
        _PP_DASH_COLS=0
    fi

    # --- 1. Enumerate managed process directories (numeric names only) ----
    if [ -d "$PP_PROCESSES_DIR" ]; then
        for dir in "$PP_PROCESSES_DIR"/*; do
            [ -d "$dir" ] || continue
            pid="${dir##*/}"
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            pids+=("$pid")
        done
    fi
    if [ "${#pids[@]}" -gt 1 ]; then
        mapfile -t pids < <(printf '%s\n' "${pids[@]}" | sort -n)
    fi
    total="${#pids[@]}"

    # --- 2. Bring every status up to date before counting ----------------
    if declare -F refresh_process_state >/dev/null 2>&1; then
        for pid in "${pids[@]}"; do
            refresh_process_state "$pid" >/dev/null 2>&1 || true
        done
    fi

    # --- 3. System resources, counts and warnings (Shaheer's functions) --
    # Called directly so the global output variables are preserved.
    # Their own output is discarded so it cannot break the screen layout.
    get_process_counts >/dev/null 2>&1 || true
    # check_resources returns non-zero when a threshold is exceeded; that is
    # not an error here, the message is read from PP_RESOURCE_WARNING.
    check_resources >/dev/null 2>&1 || true

    # --- Header -----------------------------------------------------------
    printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
    printf -v header 'ProcPilot Dashboard | %s | refresh: %ss' \
        "$now" "${PP_REFRESH_INTERVAL:-2}"
    if [ "${_PP_DASH_LIVE:-0}" = "1" ]; then
        header+=" | CTRL+C or q to quit"
    fi
    _pp_dash_emit "$header" "${_PP_DASH_C_BOLD}${header}${_PP_DASH_C_RESET}"
    _pp_dash_emit ""

    # System CPU
    _pp_dash_fmt_pct cpu_fmt "${PP_SYSTEM_CPU:-}"
    _pp_dash_bar cpu_bar "${PP_SYSTEM_CPU:-}"
    _pp_dash_level_color "${PP_SYSTEM_CPU:-}" "${PP_CPU_WARNING_THRESHOLD:-}"
    line="CPU  ${cpu_bar} ${cpu_fmt}%"
    _pp_dash_emit "$line" "CPU  ${_PP_DASH_COLOR}${cpu_bar}${_PP_DASH_C_RESET} ${cpu_fmt}%"

    # System RAM (units are whatever get_system_resources reports)
    _pp_dash_fmt_pct ram_fmt "${PP_SYSTEM_RAM_PERCENT:-}"
    _pp_dash_bar ram_bar "${PP_SYSTEM_RAM_PERCENT:-}"
    _pp_dash_level_color "${PP_SYSTEM_RAM_PERCENT:-}" "${PP_RAM_WARNING_THRESHOLD:-}"
    ram_used="${PP_SYSTEM_RAM_USED:-N/A}"
    ram_total="${PP_SYSTEM_RAM_TOTAL:-N/A}"
    line="RAM  ${ram_bar} ${ram_fmt}%   used ${ram_used} of ${ram_total}"
    _pp_dash_emit "$line" \
        "RAM  ${_PP_DASH_COLOR}${ram_bar}${_PP_DASH_C_RESET} ${ram_fmt}%   used ${ram_used} of ${ram_total}"

    # Status counts
    running="${PP_RUNNING_COUNT:-0}"
    completed="${PP_COMPLETED_COUNT:-0}"
    failed="${PP_FAILED_COUNT:-0}"
    stopped="${PP_STOPPED_COUNT:-0}"
    line="Processes: ${total} total, ${running} running, ${completed} completed, ${failed} failed, ${stopped} stopped"
    _pp_dash_emit "$line" "Processes: ${_PP_DASH_C_BOLD}${total}${_PP_DASH_C_RESET} total, ${_PP_DASH_C_GREEN}${running} running${_PP_DASH_C_RESET}, ${_PP_DASH_C_CYAN}${completed} completed${_PP_DASH_C_RESET}, ${_PP_DASH_C_RED}${failed} failed${_PP_DASH_C_RESET}, ${_PP_DASH_C_YELLOW}${stopped} stopped${_PP_DASH_C_RESET}"

    # Resource warnings (one line per warning if several are reported)
    if [ -n "${PP_RESOURCE_WARNING:-}" ]; then
        mapfile -t warning_lines <<< "$PP_RESOURCE_WARNING"
        for warning_line in "${warning_lines[@]}"; do
            [ -n "$warning_line" ] || continue
            line="WARNING: ${warning_line}"
            _pp_dash_emit "$line" "${_PP_DASH_C_BOLD}${_PP_DASH_C_RED}${line}${_PP_DASH_C_RESET}"
        done
    else
        line="Warnings: none"
        _pp_dash_emit "$line" "${_PP_DASH_C_DIM}${line}${_PP_DASH_C_RESET}"
    fi
    _pp_dash_emit ""

    # --- Process table ----------------------------------------------------
    printf -v line '%7s  %6s  %6s  %-10s  %s' 'PID' 'CPU%' 'MEM%' 'STATUS' 'COMMAND'
    if [ "${_PP_DASH_LIVE:-0}" = "1" ] && [ "${#line}" -lt "$_PP_DASH_COLS" ]; then
        printf -v line '%-*s' "$_PP_DASH_COLS" "$line"
    fi
    _pp_dash_emit "$line" "${_PP_DASH_C_REV}${line}${_PP_DASH_C_RESET}"

    if [ "$total" -eq 0 ]; then
        line="  No managed processes. Start one with: ./procpilot.sh run COMMAND [ARGUMENTS...]"
        _pp_dash_emit "$line" "${_PP_DASH_C_DIM}${line}${_PP_DASH_C_RESET}"
    fi

    # In live mode, keep the frame inside the window like `top` does.
    max_rows="$total"
    if [ "${_PP_DASH_LIVE:-0}" = "1" ]; then
        max_rows=$(( _PP_DASH_ROWS - ${#_PP_DASH_FRAME[@]} ))
        if [ "$total" -gt "$max_rows" ]; then
            max_rows=$(( max_rows - 1 ))   # leave room for the "more" line
        fi
        [ "$max_rows" -lt 0 ] && max_rows=0
        cmd_width=$(( _PP_DASH_COLS - _PP_DASH_TABLE_PREFIX_WIDTH ))
        [ "$cmd_width" -lt 10 ] && cmd_width=10
    fi

    shown=0
    for pid in "${pids[@]}"; do
        [ "$shown" -lt "$max_rows" ] || break

        if get_process_info "$pid" >/dev/null 2>&1; then
            row_pid_clean="${PP_PROCESS_PID:-}"
            row_pid_clean="${row_pid_clean//[[:space:]]/}"
        else
            row_pid_clean=""
        fi

        # Only trust the output variables if they describe this PID;
        # otherwise they still hold the previous process's values.
        if [ "$row_pid_clean" = "$pid" ]; then
            _pp_dash_fmt_pct row_cpu "${PP_PROCESS_CPU:-}"
            _pp_dash_fmt_pct row_mem "${PP_PROCESS_MEM:-}"
            row_status="${PP_PROCESS_STATUS:-unknown}"
            row_status="${row_status//[[:space:]]/}"
            [ -n "$row_status" ] || row_status="unknown"
            row_cmd="${PP_PROCESS_COMMAND:-}"
        else
            printf -v row_cpu '%5s' '-'
            printf -v row_mem '%5s' '-'
            row_status="unknown"
            row_cmd="(process information unavailable)"
        fi

        # Commands are shown on a single line.
        row_cmd="${row_cmd//$'\n'/ }"
        row_cmd="${row_cmd//$'\r'/ }"
        row_cmd="${row_cmd//$'\t'/ }"
        if [ "${_PP_DASH_LIVE:-0}" = "1" ] && [ "${#row_cmd}" -gt "$cmd_width" ]; then
            row_cmd="${row_cmd:0:$((cmd_width - 3))}..."
        fi

        _pp_dash_status_color "$row_status"
        printf -v line '%7s  %6s  %6s  %-10s  %s' "$pid" "$row_cpu" "$row_mem" "$row_status" "$row_cmd"
        printf -v colored_line '%7s  %6s  %6s  %s%-10s%s  %s' \
            "$pid" "$row_cpu" "$row_mem" "$_PP_DASH_COLOR" "$row_status" "$_PP_DASH_C_RESET" "$row_cmd"
        _pp_dash_emit "$line" "$colored_line"
        shown=$(( shown + 1 ))
    done

    hidden=$(( total - shown ))
    if [ "$hidden" -gt 0 ]; then
        line="  ... ${hidden} more process(es) not shown - enlarge the terminal to see them"
        _pp_dash_emit "$line" "${_PP_DASH_C_DIM}${line}${_PP_DASH_C_RESET}"
    fi

    # --- Output -------------------------------------------------------------
    if [ "${_PP_DASH_LIVE:-0}" = "1" ]; then
        # Move to the top-left corner, overwrite each line, clear what is
        # left of the previous frame. No trailing newline, so the screen
        # never scrolls.
        printf '\033[H'
        for (( i = 0; i < ${#_PP_DASH_FRAME[@]}; i++ )); do
            if [ "$i" -gt 0 ]; then
                printf '\n'
            fi
            printf '%s\033[K' "${_PP_DASH_FRAME[$i]}"
        done
        printf '\033[J'
    else
        printf '%s\n' "${_PP_DASH_FRAME[@]}"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# show_dashboard
#
# Runs the live dashboard:
#   * calls render_dashboard every PP_REFRESH_INTERVAL seconds (default 2);
#     the time spent rendering is subtracted from the wait, so the screen
#     really updates once per interval
#   * CTRL+C (or the q key) exits cleanly: the terminal is restored
#     (cursor, echo, main screen), the signal trap is removed and the
#     function returns 0
#   * any other key refreshes immediately
#   * logs when the dashboard opens/closes and when a resource warning
#     appears or clears
#
# Returns 0 on a normal exit, 1 on invalid configuration or missing modules.
# -----------------------------------------------------------------------------
show_dashboard() {
    local interval="${PP_REFRESH_INTERVAL:-2}"
    local interval_us start_us elapsed_us wait_us wait_s
    local key
    local use_keys=0
    local saved_stty=""
    local rc=0

    if [ "$#" -ne 0 ]; then
        printf 'Usage: dashboard\n' >&2
        return 1
    fi

    _pp_dash_check_deps get_system_resources check_resources \
        get_process_counts get_process_info write_log || return 1

    # Refresh interval: positive number of seconds (whole or decimal).
    if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf 'dashboard: invalid PP_REFRESH_INTERVAL "%s"\n' "$interval" >&2
        write_log ERROR "Dashboard not started: invalid PP_REFRESH_INTERVAL '$interval'"
        return 1
    fi
    interval_us="$(awk -v i="$interval" 'BEGIN { printf "%d", i * 1000000 }')"
    if ! [[ "$interval_us" =~ ^[0-9]+$ ]] || [ "$interval_us" -le 0 ]; then
        printf 'dashboard: PP_REFRESH_INTERVAL must be greater than 0\n' >&2
        write_log ERROR "Dashboard not started: PP_REFRESH_INTERVAL must be greater than 0"
        return 1
    fi

    _PP_DASH_RUNNING=1
    _PP_DASH_LAST_WARNING=""
    _PP_DASH_LIVE=0
    [ -t 1 ] && _PP_DASH_LIVE=1
    [ -t 0 ] && use_keys=1

    # CTRL+C / termination only ask the loop to stop; cleanup happens below,
    # so the terminal is always restored.
    trap '_PP_DASH_RUNNING=0' INT TERM HUP

    if [ "$_PP_DASH_LIVE" -eq 1 ]; then
        # Alternate screen (like top), hide cursor, clear once.
        printf '\033[?1049h\033[?25l\033[2J'
    fi
    if [ "$use_keys" -eq 1 ]; then
        saved_stty="$(stty -g 2>/dev/null)"
        stty -echo 2>/dev/null || true
    fi

    write_log INFO "Dashboard opened (refresh interval: ${interval}s)"

    while [ "$_PP_DASH_RUNNING" -eq 1 ]; do
        _pp_dash_now_us
        start_us="$_PP_DASH_NOW_US"

        if ! render_dashboard; then
            rc=1
            break
        fi
        if [ "$_PP_DASH_LIVE" -eq 0 ]; then
            printf '\n'   # blank line between plain-text snapshots
        fi

        _pp_dash_track_warning
        [ "$_PP_DASH_RUNNING" -eq 1 ] || break

        # Wait for the rest of the interval.
        wait_us="$interval_us"
        _pp_dash_now_us
        if [ -n "$start_us" ] && [ -n "$_PP_DASH_NOW_US" ]; then
            elapsed_us=$(( _PP_DASH_NOW_US - start_us ))
            wait_us=$(( interval_us - elapsed_us ))
        fi
        [ "$wait_us" -lt 100000 ] && wait_us=100000
        printf -v wait_s '%d.%06d' "$(( wait_us / 1000000 ))" "$(( wait_us % 1000000 ))"

        if [ "$use_keys" -eq 1 ]; then
            key=""
            read -r -s -n 1 -t "$wait_s" key || true
            case "$key" in
                q|Q) _PP_DASH_RUNNING=0 ;;
            esac
        else
            sleep "$wait_s" || true
        fi
    done

    # --- Clean exit -------------------------------------------------------
    trap - INT TERM HUP
    if [ -n "$saved_stty" ]; then
        stty "$saved_stty" 2>/dev/null || true
    fi
    if [ "$_PP_DASH_LIVE" -eq 1 ]; then
        printf '\033[?25h\033[?1049l'   # show cursor, back to normal screen
    fi
    _PP_DASH_LIVE=0
    _PP_DASH_RUNNING=0

    if [ "$rc" -eq 0 ]; then
        write_log INFO "Dashboard closed by user"
        printf 'ProcPilot dashboard closed.\n'
    else
        write_log ERROR "Dashboard stopped because rendering failed"
    fi

    return "$rc"
}
