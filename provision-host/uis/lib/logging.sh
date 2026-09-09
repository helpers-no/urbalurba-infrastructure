#!/bin/bash
# logging.sh - UIS Logging Utilities
#
# Provides colored output functions for consistent logging across UIS scripts.
#
# Usage:
#   source /path/to/logging.sh
#   log_info "Starting deployment..."
#   log_success "Deployment complete"
#   log_warn "Service may need restart"
#   log_error "Deployment failed"

# Guard against multiple sourcing
[[ -n "${_UIS_LOGGING_LOADED:-}" ]] && return 0
_UIS_LOGGING_LOADED=1

# Colors
readonly LOG_RED='\033[0;31m'
readonly LOG_GREEN='\033[0;32m'
readonly LOG_YELLOW='\033[0;33m'
readonly LOG_BLUE='\033[0;34m'
readonly LOG_BOLD='\033[1m'
readonly LOG_NC='\033[0m'  # No Color

# 🔴 DIAGNOSTICS GO TO STDERR. STDOUT IS DATA.
#
# `log_error` always did; the rest wrote to STDOUT, and that silently broke the
# `--json` contract. `configure postgresql --json` on an existing database emits
# a rotation warning through log_warn, so the captured "JSON" was
#
#     ⚠ Password for 'atlast' was rotated. …
#     {"status":"already_configured", …}
#
# `_json_field` survived the parse (the #367 fix holding) but read an empty
# status, so the `*)` branch reported a SUCCESSFUL configure as a failure and
# `template install` aborted before writing its record. imac hit it on exactly
# the re-install-after-remove path they were asked to measure (urb-agents#481).
#
# ⚠️ I introduced that warning in 1.6.27, using log_warn for one line and an
# explicit `>&2` for the next — two halves of one message on two streams. The
# real defect was older and wider: ANY log_info/log_warn/log_success on a
# --json path corrupts it, and there was nothing to stop the next one.
#
# Moving them all is the fix rather than patching the caller: a human sees
# stderr on a terminal exactly as before, and a caller capturing stdout now gets
# only the thing it asked for.
log_info() {
    echo -e "${LOG_BLUE}ℹ${LOG_NC} $*" >&2
}

# Log success message (green checkmark)
log_success() {
    echo -e "${LOG_GREEN}✓${LOG_NC} $*" >&2
}

# Log warning message (yellow warning icon)
log_warn() {
    echo -e "${LOG_YELLOW}⚠${LOG_NC} $*" >&2
}

# Log error message (red X)
log_error() {
    echo -e "${LOG_RED}✗${LOG_NC} $*" >&2
}

# Log debug message (only if UIS_DEBUG is set)
log_debug() {
    [[ -n "${UIS_DEBUG:-}" ]] && echo -e "${LOG_BLUE}[DEBUG]${LOG_NC} $*" >&2
}

# Print a section header
print_section() {
    echo ""
    echo -e "${LOG_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${LOG_NC}"
    echo -e "${LOG_BOLD}$*${LOG_NC}"
    echo -e "${LOG_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${LOG_NC}"
}

# Print a subsection header
print_subsection() {
    echo ""
    echo -e "${LOG_BOLD}── $* ──${LOG_NC}"
}

# Progress indicator for long operations
# Usage: log_progress "Deploying services" 3 10
log_progress() {
    local message="$1"
    local current="${2:-0}"
    local total="${3:-0}"

    if [[ "$total" -gt 0 ]]; then
        echo -e "${LOG_BLUE}→${LOG_NC} $message [$current/$total]" >&2
    else
        echo -e "${LOG_BLUE}→${LOG_NC} $message" >&2
    fi
}
