start_process() {
    # 1. Validate input
    if [[ $# -lt 1 ]]; then
        printf 'Error: No command provided.\n' >&2
        return 1
    fi

    local command="$1"
    shift

    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Error: Command not found: %s\n' "$command" >&2
        return 127
    fi

    # 2. Identify project paths
    local project_root="${PP_ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
    local processes_dir="${PP_PROCESSES_DIR:-$project_root/state/processes}"
    local log_dir="${PP_LOG_DIR:-$project_root/logs}"
    local runner_path="$project_root/process_runner.sh"

    # 3. Check runner script
    if [[ ! -f "$runner_path" ]]; then
        printf 'Error: process_runner.sh not found.\n' >&2
        return 1
    fi

    # 4. Create required directories
    if ! mkdir -p "$processes_dir" "$log_dir/processes"; then
        printf 'Error: Could not create process directories.\n' >&2
        return 1
    fi

    # 5. Create a temporary state directory (initial information store krne k liye )
    local state_dir="$processes_dir/.starting_${BASHPID}_${RANDOM}"

    if ! mkdir -p "$state_dir"; then
        printf 'Error: Could not create temporary state directory.\n' >&2
        return 1
    fi

    # 6. Prepare process log path(save each process output )
    local process_log="$log_dir/processes/process_${BASHPID}_${RANDOM}.log"

    # 7. Save initial metadata
    printf '%q ' "$command" "$@" > "$state_dir/command.txt"
    printf '\n' >> "$state_dir/command.txt"

    date --iso-8601=seconds > "$state_dir/started_at.txt"
    printf 'running\n' > "$state_dir/status.txt"
    printf '%s\n' "$process_log" > "$state_dir/log_path.txt"
    

    # 8. Start the runner in background
    bash "$runner_path" "$state_dir" "$process_log" "$command" "$@" \
        >/dev/null 2>&1 &

    local supervisor_pid=$!

    # 9. Wait for runner to publish the actual command PID
    local process_pid=""
    local pid_file=""
    local attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
        for pid_file in "$processes_dir"/*/supervisor_pid.txt; do
            [[ -f "$pid_file" ]] || continue

            if [[ "$(cat "$pid_file")" == "$supervisor_pid" ]]; then
                process_pid="$(cat "${pid_file%/*}/pid.txt" 2>/dev/null)"
                break 2
            fi
        done

        sleep 0.1
    done

    # 10. Handle startup failure
    if [[ ! "$process_pid" =~ ^[0-9]+$ ]]; then
        printf 'Error: Could not obtain process PID.\n' >&2
        kill "$supervisor_pid" 2>/dev/null || true
        return 1
    fi

    # 11. Print only the actual command PID
    printf '%s\n' "$process_pid"
    return 0
}