#!/usr/bin/env bash

# 1. Receive information from executor
state_dir="$1"
process_log="$2"
shift 2

if [[ $# -lt 1 ]]; then
    printf 'Error: No command provided.\n' >&2
    exit 1
fi

# 2. Identify process information
supervisor_pid=$BASHPID
processes_dir="$(dirname -- "$state_dir")"

# 3. Prepare log directory
if ! mkdir -p "$(dirname -- "$process_log")"; then
    printf 'Error: Could not create log directory.\n' >&2
    exit 1
fi

# 4. Start the actual command in background
"$@" >> "$process_log" 2>&1 &
process_pid=$!

# 5. Save both PIDs
printf '%s\n' "$process_pid" > "$state_dir/pid.txt"
printf '%s\n' "$supervisor_pid" > "$state_dir/supervisor_pid.txt"

# 6. Rename temporary state directory using actual PID
final_state_dir="$processes_dir/$process_pid"

if [[ -e "$final_state_dir" ]]; then
    kill "$process_pid" 2>/dev/null || true
    wait "$process_pid" 2>/dev/null
    printf 'failed\n' > "$state_dir/status.txt"
    exit 1
fi

if ! mv -- "$state_dir" "$final_state_dir"; then
    kill "$process_pid" 2>/dev/null || true
    wait "$process_pid" 2>/dev/null
    exit 1
fi

state_dir="$final_state_dir"

# 7. Monitor the actual process
while kill -0 "$process_pid" 2>/dev/null; do

    # Check whether user requested termination
    if [[ -f "$state_dir/stop_requested.txt" ]]; then
        kill -TERM "$process_pid" 2>/dev/null || true

        wait "$process_pid"
        exit_code=$?

        printf '%s\n' "$exit_code" > "$state_dir/exit_code.txt"
        printf 'stopped\n' > "$state_dir/status.txt"
        exit 0
    fi

    sleep 0.2
done

# 8. Collect final exit code
wait "$process_pid"
exit_code=$?

printf '%s\n' "$exit_code" > "$state_dir/exit_code.txt"

# 9. Update final process status
if [[ "$exit_code" -eq 0 ]]; then
    printf 'completed\n' > "$state_dir/status.txt"
else
    printf 'failed\n' > "$state_dir/status.txt"
fi

exit 0
