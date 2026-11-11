#!/usr/bin/env bash
#
# src/config.sh - ProcPilot configuration module
# Owner:  Muhammad Shahid Raza
# Provides: load_config(), validate_config()
#
# Global variables owned and initialised by this file (Section 9.1):
#   PP_ROOT_DIR, PP_STATE_DIR, PP_PROCESSES_DIR, PP_LOG_DIR, PP_APP_LOG,
#   PP_REFRESH_INTERVAL, PP_CPU_WARNING_THRESHOLD, PP_RAM_WARNING_THRESHOLD
#
# Sourcing this file must not execute any workflow: it only defines functions.
# This module is sourced before src/logger.sh, so it reports errors directly on
# standard error instead of using write_log().

# Internal helper: print a configuration error on standard error.
_config_error() {
    printf 'procpilot: %s\n' "$*" >&2
}

# Internal helper: return 0 when the argument is an unsigned decimal integer.
_config_is_uint() {
    [[ ${1-} =~ ^[0-9]+$ ]]
}

# Internal helper: strip leading and trailing whitespace from the value given
# as the second argument and store the result in the variable named by the
# first argument. Nothing is echoed, so spaces inside values survive.
_config_trim() {
    local value=${2-}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf -v "$1" '%s' "$value"
}

# Internal helper: set the built-in default configuration values.
_config_defaults() {
    PP_REFRESH_INTERVAL=2
    PP_CPU_WARNING_THRESHOLD=80
    PP_RAM_WARNING_THRESHOLD=80
}

# load_config
# Identify the project root, set the shared directory paths, load defaults,
# read config/settings.conf, and create the required directories.
# Returns 0 on success and non-zero on failure.
load_config() {
    local module_dir config_file line key value trimmed

    module_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
        _config_error "unable to determine the configuration module directory"
        return 1
    }

    PP_ROOT_DIR="$(cd -- "$module_dir/.." && pwd)" || {
        _config_error "unable to determine the project root directory"
        return 1
    }

    # Shared directory paths, all derived from the project root so that no
    # personal absolute path is ever hard-coded.
    PP_STATE_DIR="$PP_ROOT_DIR/state"
    PP_PROCESSES_DIR="$PP_STATE_DIR/processes"
    PP_LOG_DIR="$PP_ROOT_DIR/logs"
    PP_APP_LOG="$PP_LOG_DIR/procpilot.log"

    # Built-in defaults, applied before the user configuration.
    _config_defaults

    config_file="$PP_ROOT_DIR/config/settings.conf"
    if [[ -r "$config_file" ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            # Tolerate configuration files saved with CRLF line endings.
            line=${line%$'\r'}
            _config_trim trimmed "$line"
            line=$trimmed

            # Skip blank lines and comments.
            [[ -z $line || $line == \#* ]] && continue

            # Only KEY=VALUE assignments are meaningful.
            [[ $line == *=* ]] || continue

            _config_trim trimmed "${line%%=*}"
            key=$trimmed
            _config_trim trimmed "${line#*=}"
            value=$trimmed

            # Remove one pair of matching surrounding quotes, if present.
            case $value in
                \"*\")
                    value=${value#\"}
                    value=${value%\"}
                    ;;
                \'*\')
                    value=${value#\'}
                    value=${value%\'}
                    ;;
            esac

            # Only the documented settings may be overridden. Paths always come
            # from load_config(), and unknown keys are ignored so that a stale
            # or unrelated configuration file can never inject commands.
            case $key in
                PP_REFRESH_INTERVAL | PP_CPU_WARNING_THRESHOLD | PP_RAM_WARNING_THRESHOLD)
                    printf -v "$key" '%s' "$value"
                    ;;
            esac
        done <"$config_file"
    fi

    # Required directories and the shared application log.
    if ! mkdir -p -- "$PP_STATE_DIR" "$PP_PROCESSES_DIR" "$PP_LOG_DIR/processes"; then
        _config_error "unable to create the ProcPilot directories under $PP_ROOT_DIR"
        return 1
    fi

    if [[ ! -e $PP_APP_LOG ]]; then
        if ! : >"$PP_APP_LOG"; then
            _config_error "unable to create the application log file $PP_APP_LOG"
            return 1
        fi
    fi

    return 0
}

# validate_config
# Validate the CPU threshold, the RAM threshold and the dashboard refresh
# interval. Returns 0 when the configuration is valid and non-zero otherwise.
validate_config() {
    local status=0

    if [[ -z ${PP_ROOT_DIR-} ]]; then
        _config_error "configuration is not loaded: PP_ROOT_DIR is not set"
        return 1
    fi

    if ! _config_is_uint "${PP_CPU_WARNING_THRESHOLD-}"; then
        _config_error "PP_CPU_WARNING_THRESHOLD must be an integer between 1 and 100 (got '${PP_CPU_WARNING_THRESHOLD-}')"
        status=1
    elif ((10#$PP_CPU_WARNING_THRESHOLD < 1 || 10#$PP_CPU_WARNING_THRESHOLD > 100)); then
        _config_error "PP_CPU_WARNING_THRESHOLD must be between 1 and 100 (got $PP_CPU_WARNING_THRESHOLD)"
        status=1
    fi

    if ! _config_is_uint "${PP_RAM_WARNING_THRESHOLD-}"; then
        _config_error "PP_RAM_WARNING_THRESHOLD must be an integer between 1 and 100 (got '${PP_RAM_WARNING_THRESHOLD-}')"
        status=1
    elif ((10#$PP_RAM_WARNING_THRESHOLD < 1 || 10#$PP_RAM_WARNING_THRESHOLD > 100)); then
        _config_error "PP_RAM_WARNING_THRESHOLD must be between 1 and 100 (got $PP_RAM_WARNING_THRESHOLD)"
        status=1
    fi

    if ! _config_is_uint "${PP_REFRESH_INTERVAL-}"; then
        _config_error "PP_REFRESH_INTERVAL must be a positive integer number of seconds (got '${PP_REFRESH_INTERVAL-}')"
        status=1
    elif ((10#$PP_REFRESH_INTERVAL < 1)); then
        _config_error "PP_REFRESH_INTERVAL must be at least 1 second (got $PP_REFRESH_INTERVAL)"
        status=1
    fi

    return "$status"
}
