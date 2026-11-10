
#!/usr/bin/env bash

# Stop a ProcPilot-managed process
stop_process() {

    # Check PID input
    if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+$ ]]; then
        printf 'Error: Provide a valid process PID.\n' >&2
        return 1
    fi

    local process_pid="$1"

    # Identify project paths
    local project_root="${PP_ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
    local processes_dir="${PP_PROCESSES_DIR:-$project_root/state/processes}"
    local state_dir="$processes_dir/$process_pid"

    # Verify that this is a managed process
    if [[ ! -f "$state_dir/pid.txt" ]]; then
        printf 'Error: Process is not managed by ProcPilot.\n' >&2
        return 1
    fi

    local saved_pid
    saved_pid="$(cat "$state_dir/pid.txt")"

    if [[ "$saved_pid" != "$process_pid" ]]; then
        printf 'Error: PID verification failed.\n' >&2
        return 1
    fi

    # Check process status
    local status
    status="$(cat "$state_dir/status.txt" 2>/dev/null)"

    if [[ "$status" != "running" ]]; then
        printf 'Error: Process is not running.\n' >&2
        return 1
    fi

    # Request the runner to stop the process
    if ! touch "$state_dir/stop_requested.txt"; then
        printf 'Error: Could not send stop request.\n' >&2
        return 1
    fi

    printf 'Stop request sent for PID %s.\n' "$process_pid"
    return 0
}


# Display all ProcPilot-managed processes
list_managed_processes() {

    # Identify project paths
    local project_root="${PP_ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
    local processes_dir="${PP_PROCESSES_DIR:-$project_root/state/processes}"

    if [[ ! -d "$processes_dir" ]]; then
        printf 'No managed processes found.\n'
        return 0
    fi

    printf '%-12s %-12s %s\n' "PID" "STATUS" "COMMAND"

    local state_dir
    local process_pid
    local status
    local command

    for state_dir in "$processes_dir"/*; do

        [[ -d "$state_dir" ]] || continue
        [[ -f "$state_dir/pid.txt" ]] || continue

        process_pid="$(cat "$state_dir/pid.txt" 2>/dev/null)"
        status="$(cat "$state_dir/status.txt" 2>/dev/null)"
        command="$(cat "$state_dir/command.txt" 2>/dev/null)"

        printf '%-12s %-12s %s\n' \
            "$process_pid" "$status" "$command"

    done

    return 0
}
