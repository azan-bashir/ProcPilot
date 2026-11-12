
#!/bin/bash

_monitor_write_status()
{
    local state_dir="$1" status="$2" tmp

    tmp="$state_dir/.status.tmp.$$"

    printf '%s\n' "$status" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    mv -f "$tmp" "$state_dir/status.txt" || {
        rm -f "$tmp"
        return 1
    }
}

refresh_process_state()
{
    local pid="$1"
    local state_dir="$PP_PROCESSES_DIR/$1"
    local ps_state exit_code status

    PP_PROCESS_PID="$pid"
    PP_PROCESS_STATUS=""

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1

    [[ -d "$state_dir" ]] || return 1
    [[ -f "$state_dir/pid.txt" ]] || return 1
    [[ "$(< "$state_dir/pid.txt")" == "$pid" ]] || return 1

    ps_state=$(ps -o stat= -p "$pid" 2>/dev/null)

    if [[ -n "$ps_state" && "$ps_state" != Z* && "$ps_state" != X* ]]; then
        status="running"
    else
        [[ -f "$state_dir/exit_code.txt" ]] || return 1

        exit_code=$(< "$state_dir/exit_code.txt")

        [[ "$exit_code" =~ ^[0-9]+$ ]] || return 1

        if [[ -f "$state_dir/stop_requested.txt" ]]; then
            status="stopped"
        elif (( 10#$exit_code == 0 )); then
            status="completed"
        else
            status="failed"
        fi
    fi

    _monitor_write_status "$state_dir" "$status" || return 1

    PP_PROCESS_STATUS="$status"

    return 0
}

PP_PROCESS_PID=""
PP_PROCESS_CPU=""
PP_PROCESS_MEM=""
PP_PROCESS_STATUS=""
PP_PROCESS_COMMAND=""

get_process_info()
{
    local pid="$1" state_dir line ps_pid

    PP_PROCESS_PID="$pid"
    PP_PROCESS_CPU=0
    PP_PROCESS_MEM=0
    PP_PROCESS_STATUS=""
    PP_PROCESS_COMMAND=""

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1

    state_dir="$PP_PROCESSES_DIR/$pid"

    [[ -d "$state_dir" ]] || return 1
    [[ -f "$state_dir/pid.txt" ]] || return 1
    [[ "$(< "$state_dir/pid.txt")" == "$pid" ]] || return 1

    refresh_process_state "$pid" >/dev/null 2>&1 || true

    if [[ -z "$PP_PROCESS_STATUS" && -f "$state_dir/status.txt" ]]; then
        PP_PROCESS_STATUS=$(< "$state_dir/status.txt")
    fi

    if [[ -f "$state_dir/command.txt" ]]; then
        PP_PROCESS_COMMAND=$(< "$state_dir/command.txt")
    fi

    if [[ "$PP_PROCESS_STATUS" == "running" ]]; then
        line=$(ps -p "$pid" -o pid=,%cpu=,%mem= 2>/dev/null)

        if [[ -n "$line" ]]; then
            read -r ps_pid PP_PROCESS_CPU PP_PROCESS_MEM <<< "$line"
        fi
    fi

    return 0
}

PP_RUNNING_COUNT=0
PP_COMPLETED_COUNT=0
PP_FAILED_COUNT=0
PP_STOPPED_COUNT=0

get_process_counts()
{
    local state_dir status

    PP_RUNNING_COUNT=0
    PP_COMPLETED_COUNT=0
    PP_FAILED_COUNT=0
    PP_STOPPED_COUNT=0

    for state_dir in "$PP_PROCESSES_DIR"/*; do
        [[ -d "$state_dir" ]] || continue

        if refresh_process_state "${state_dir##*/}" >/dev/null; then
            status="$PP_PROCESS_STATUS"
        else
            status=$(< "$state_dir/status.txt" 2>/dev/null)
        fi

        case "$status" in
            completed)
                (( PP_COMPLETED_COUNT+=1 ))
                ;;
            failed)
                (( PP_FAILED_COUNT+=1 ))
                ;;
            running)
                (( PP_RUNNING_COUNT+=1 ))
                ;;
            stopped)
                (( PP_STOPPED_COUNT+=1 ))
                ;;
        esac
    done

    return 0
}
