#!/bin/bash
#
# procpilot.sh - ProcPilot main entry point
# Owner: Muhammad Shahid Raza (integration)
#
# Sources every module, loads and validates the configuration, then hands the
# user arguments to the CLI router. This is the integration code fixed by the
# team specification (Section 6.7) and must not be changed without approval.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/src/config.sh"
source "$SCRIPT_DIR/src/logger.sh"
source "$SCRIPT_DIR/src/resource_manager.sh"
source "$SCRIPT_DIR/src/executor.sh"
source "$SCRIPT_DIR/src/manager.sh"
source "$SCRIPT_DIR/src/monitor.sh"
source "$SCRIPT_DIR/src/dashboard.sh"
source "$SCRIPT_DIR/src/cli.sh"

load_config || exit 1
validate_config || exit 1

main "$@"
