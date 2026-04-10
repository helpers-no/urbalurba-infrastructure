#!/bin/bash
# integration-testing.sh - Full integration test orchestration
#
# Runs deploy/undeploy for all services in dependency order.
# Uses SCRIPT_REQUIRES and SCRIPT_PRIORITY metadata from service scripts.
#
# Usage:
#   source /path/to/integration-testing.sh
#   run_integration_tests          # run all tests
#   run_integration_tests --dry-run  # show plan only

# Guard against multiple sourcing
[[ -n "${_UIS_INTEGRATION_TESTING_LOADED:-}" ]] && return 0
_UIS_INTEGRATION_TESTING_LOADED=1

# ============================================================
# Configuration
# ============================================================

# Services always skipped (broken or not testable)
SKIP_SERVICES_ALWAYS="gravitee"

# Services skipped unless credentials are configured.
# Each service lists the variables that must have real (non-placeholder) values
# in secrets-config/00-common-values.env.template.
# Format: one entry per line, service_id:VAR1,VAR2,...
SKIP_SERVICES_CONDITIONAL="
tailscale-tunnel:TAILSCALE_CLIENTID,TAILSCALE_CLIENTSECRET,TAILSCALE_DOMAIN
cloudflare-tunnel:CLOUDFLARE_TUNNEL_TOKEN
"

# Check if a value is a placeholder (not configured).
# Returns 0 if placeholder, 1 if real value.
_is_placeholder() {
    local val="$1"
    [[ -z "$val" ]] && return 0
    [[ "$val" == "your-"* ]] && return 0
    [[ "$val" == "your_"* ]] && return 0
    [[ "$val" == *"-here" ]] && return 0
    [[ "$val" == *"-name" ]] && return 0
    return 1
}

# Build effective skip list at runtime
_build_skip_list() {
    local skip_list="$SKIP_SERVICES_ALWAYS"

    # Find the secrets config file
    local secrets_config="${SECRETS_DIR:-$(get_secrets_dir)}/secrets-config/00-common-values.env.template"

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local service_id="${line%%:*}"
        local required_vars="${line#*:}"

        local skip=false

        # If secrets config doesn't exist, skip the service
        if [[ ! -f "$secrets_config" ]]; then
            skip=true
        else
            # Check each required variable
            local var
            for var in ${required_vars//,/ }; do
                local val=""
                val=$(grep "^${var}=" "$secrets_config" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
                if _is_placeholder "$val"; then
                    skip=true
                    break
                fi
            done
        fi

        if [[ "$skip" == "true" ]]; then
            skip_list="$skip_list $service_id"
        fi
    done <<< "$SKIP_SERVICES_CONDITIONAL"
    echo "$skip_list"
}

# Services with a verify step (one per line, format: service_id:cli_args)
VERIFY_SERVICES="
argocd:argocd verify
backstage:backstage verify
enonic:enonic verify
nextcloud:nextcloud verify
openmetadata:openmetadata verify
"

# ============================================================
# Test Plan Builder
# ============================================================

# Arrays populated by build_test_plan
_FOUNDATION_SERVICES=()
_REGULAR_SERVICES=()
_SKIPPED_SERVICES=()

# Build the test plan from service metadata.
# Populates _FOUNDATION_SERVICES, _REGULAR_SERVICES, _SKIPPED_SERVICES.
# Each entry: "service_id:priority"
# Args: optional list of service IDs to test (--only filter)
build_test_plan() {
    _FOUNDATION_SERVICES=()
    _REGULAR_SERVICES=()
    _SKIPPED_SERVICES=()

    # Capture --only filter if provided
    local -A only_filter=()
    local has_only_filter=false
    for arg in "$@"; do
        only_filter[$arg]=1
        has_only_filter=true
    done

    # Collect all service metadata: id, priority, requires
    local all_ids=()
    local -A priorities=()
    local -A requires_map=()

    for service_id in $(get_all_service_ids); do
        local script
        script=$(find_service_script "$service_id") || continue

        local priority="" requires=""
        while IFS= read -r line; do
            case "$line" in
                SCRIPT_PRIORITY=*)
                    priority="${line#SCRIPT_PRIORITY=}"
                    priority="${priority//\"/}"
                    priority="${priority//\'/}"
                    ;;
                SCRIPT_REQUIRES=*)
                    requires="${line#SCRIPT_REQUIRES=}"
                    requires="${requires//\"/}"
                    requires="${requires//\'/}"
                    ;;
            esac
        done < "$script"

        all_ids+=("$service_id")
        priorities[$service_id]="${priority:-50}"
        requires_map[$service_id]="$requires"
    done

    if [[ "$has_only_filter" == "true" ]]; then
        # --only mode: test only specified services + their dependencies
        # Validate that all requested services exist
        for sid in "${!only_filter[@]}"; do
            local found=false
            for id in "${all_ids[@]}"; do
                [[ "$id" == "$sid" ]] && found=true && break
            done
            if [[ "$found" == "false" ]]; then
                log_error "Unknown service: $sid"
                return 1
            fi
        done

        # Resolve dependencies recursively for the requested services
        local -A needed_deps=()
        _resolve_deps() {
            local sid="$1"
            for dep in ${requires_map[$sid]}; do
                if [[ -z "${needed_deps[$dep]:-}" ]]; then
                    needed_deps[$dep]=1
                    _resolve_deps "$dep"
                fi
            done
        }
        for sid in "${!only_filter[@]}"; do
            _resolve_deps "$sid"
        done

        # Classify: requested services are regular, their deps are foundation
        for service_id in "${all_ids[@]}"; do
            if [[ -n "${only_filter[$service_id]:-}" ]]; then
                _REGULAR_SERVICES+=("$service_id:${priorities[$service_id]}")
            elif [[ -n "${needed_deps[$service_id]:-}" ]]; then
                _FOUNDATION_SERVICES+=("$service_id:${priorities[$service_id]}")
            fi
            # Everything else is simply not included
        done
    else
        # Full mode: test all services except skip list

        # Build the set of all required-by (foundation) services
        local -A is_foundation=()
        for service_id in "${all_ids[@]}"; do
            for dep in ${requires_map[$service_id]}; do
                is_foundation[$dep]=1
            done
        done

        # Build dynamic skip list based on available credentials
        local effective_skip
        effective_skip=$(_build_skip_list)

        # Classify each service
        for service_id in "${all_ids[@]}"; do
            # Check skip list
            if [[ " $effective_skip " == *" $service_id "* ]]; then
                _SKIPPED_SERVICES+=("$service_id:${priorities[$service_id]}")
                continue
            fi

            if [[ -n "${is_foundation[$service_id]:-}" ]]; then
                _FOUNDATION_SERVICES+=("$service_id:${priorities[$service_id]}")
            else
                _REGULAR_SERVICES+=("$service_id:${priorities[$service_id]}")
            fi
        done
    fi

    # Sort by priority (numeric)
    _FOUNDATION_SERVICES=($(printf '%s\n' "${_FOUNDATION_SERVICES[@]}" | sort -t: -k2 -n))
    _REGULAR_SERVICES=($(printf '%s\n' "${_REGULAR_SERVICES[@]}" | sort -t: -k2 -n))
    _SKIPPED_SERVICES=($(printf '%s\n' "${_SKIPPED_SERVICES[@]}" | sort -t: -k2 -n))
}

# Get service ID from "id:priority" entry
_entry_id() {
    echo "${1%%:*}"
}

# ============================================================
# Dry Run
# ============================================================

print_test_plan() {
    local total_services=$(( ${#_FOUNDATION_SERVICES[@]} + ${#_REGULAR_SERVICES[@]} ))

    print_section "Integration Test Plan (dry run)"
    echo ""
    echo "Services to test: $total_services"
    echo "Skipped: ${#_SKIPPED_SERVICES[@]}"
    echo ""

    echo -e "${LOG_BOLD}── Phase 1: Deploy foundation services ──${LOG_NC}"
    local step=1
    for entry in "${_FOUNDATION_SERVICES[@]}"; do
        local sid=$(_entry_id "$entry")
        echo "  $step. deploy $sid (keep running)"
        step=$((step + 1))
    done
    echo ""

    echo -e "${LOG_BOLD}── Phase 2: Test regular services (deploy + undeploy) ──${LOG_NC}"
    for entry in "${_REGULAR_SERVICES[@]}"; do
        local sid=$(_entry_id "$entry")
        local verify_cmd=""
        verify_cmd=$(_get_verify_command "$sid") || true
        echo "  $step. deploy $sid"
        step=$((step + 1))
        if [[ -n "$verify_cmd" ]]; then
            echo "  $step. verify $sid"
            step=$((step + 1))
        fi
        echo "  $step. undeploy $sid"
        step=$((step + 1))
    done
    echo ""

    echo -e "${LOG_BOLD}── Phase 3: Cleanup foundation services ──${LOG_NC}"
    # Reverse order
    local i
    for (( i=${#_FOUNDATION_SERVICES[@]}-1; i>=0; i-- )); do
        local sid=$(_entry_id "${_FOUNDATION_SERVICES[$i]}")
        echo "  $step. undeploy $sid"
        step=$((step + 1))
    done
    echo ""

    if [[ ${#_SKIPPED_SERVICES[@]} -gt 0 ]]; then
        echo -e "${LOG_BOLD}── Skipped services ──${LOG_NC}"
        for entry in "${_SKIPPED_SERVICES[@]}"; do
            local sid=$(_entry_id "$entry")
            local reason="not testable"
            if [[ " $SKIP_SERVICES_ALWAYS " != *" $sid "* ]]; then
                reason="credentials not configured"
            fi
            echo "  - $sid ($reason)"
        done
        echo ""
    fi

    echo "Total operations: $((step - 1))"
}

# ============================================================
# Clean State Check
# ============================================================

# Check if any testable services are currently deployed.
# Returns 0 if cluster is clean, 1 if services are running.
# Prints the list of deployed services to stdout.
_check_clean_state() {
    local deployed=()
    for entry in "${_FOUNDATION_SERVICES[@]}" "${_REGULAR_SERVICES[@]}"; do
        local sid=$(_entry_id "$entry")
        if check_service_deployed "$sid" 2>/dev/null; then
            deployed+=("$sid")
        fi
    done

    if [[ ${#deployed[@]} -gt 0 ]]; then
        printf '%s\n' "${deployed[@]}"
        return 1
    fi
    return 0
}

# Undeploy all currently deployed services (reverse priority order).
_clean_cluster() {
    local cli_script="$SCRIPT_DIR/uis-cli.sh"

    # Build reverse list: regular services first (reverse priority), then foundation (reverse priority)
    local all_reverse=()
    local i
    for (( i=${#_REGULAR_SERVICES[@]}-1; i>=0; i-- )); do
        all_reverse+=("${_REGULAR_SERVICES[$i]}")
    done
    for (( i=${#_FOUNDATION_SERVICES[@]}-1; i>=0; i-- )); do
        all_reverse+=("${_FOUNDATION_SERVICES[$i]}")
    done

    for entry in "${all_reverse[@]}"; do
        local sid=$(_entry_id "$entry")
        if check_service_deployed "$sid" 2>/dev/null; then
            echo -e "${LOG_BOLD}[$(_timestamp)] Cleaning: undeploy $sid${LOG_NC}"
            local exit_code=0
            "$cli_script" undeploy "$sid" || exit_code=$?
            if [[ $exit_code -ne 0 ]]; then
                log_error "Failed to undeploy $sid during cleanup (exit code $exit_code)"
                return 1
            fi
            sleep 5
        fi
    done

    echo ""
    log_success "Cluster cleaned — all services undeployed"
    return 0
}

# ============================================================
# Verify command lookup
# ============================================================

_get_verify_command() {
    local service_id="$1"
    local line
    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        if [[ "${line%%:*}" == "$service_id" ]]; then
            echo "${line#*:}"
            return 0
        fi
    done <<< "$VERIFY_SERVICES"
    return 1
}

# ============================================================
# Result Tracking
# ============================================================

# Results stored as: "service_id|operation|result|duration_secs"
_TEST_RESULTS=()
_TEST_FAILED=0

_record_result() {
    local service_id="$1"
    local operation="$2"
    local result="$3"
    local duration="$4"
    _TEST_RESULTS+=("$service_id|$operation|$result|$duration")
    if [[ "$result" == "FAIL" ]]; then
        _TEST_FAILED=1
    fi
}

# ============================================================
# Time Formatting
# ============================================================

_format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 60 ]]; then
        local mins=$((secs / 60))
        local remaining=$((secs % 60))
        echo "${mins}m ${remaining}s"
    else
        echo "${secs}s"
    fi
}

_timestamp() {
    date "+%H:%M:%S"
}

_datetime() {
    date "+%Y-%m-%d %H:%M:%S"
}

# ============================================================
# Operation Execution
# ============================================================

# Run a single CLI command and record the result.
# Returns 0 on PASS, 1 on FAIL.
_run_test_operation() {
    local service_id="$1"
    local operation="$2"    # deploy, undeploy, or verify
    local step_num="$3"
    local total_ops="$4"
    local total_services="$5"

    local cli_script="$SCRIPT_DIR/uis-cli.sh"

    # Build the command
    local cmd_args=""
    case "$operation" in
        deploy)   cmd_args="deploy $service_id" ;;
        undeploy) cmd_args="undeploy $service_id" ;;
        verify)
            local verify_cmd
            verify_cmd=$(_get_verify_command "$service_id")
            cmd_args="$verify_cmd"
            ;;
    esac

    # Print banner
    echo ""
    echo -e "${LOG_BOLD}══════════════════════════════════════════════════════════════${LOG_NC}"
    echo -e "${LOG_BOLD}[$(_timestamp)] STEP $step_num/$total_ops: $operation $service_id${LOG_NC}"
    echo -e "${LOG_BOLD}══════════════════════════════════════════════════════════════${LOG_NC}"
    echo ""

    # Run the command
    local start_time
    start_time=$(date +%s)

    # Execute as a separate invocation of uis-cli.sh
    # This matches how the manual tester runs commands
    # Capture exit code without letting set -e abort us
    local exit_code=0
    "$cli_script" $cmd_args || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Print result line
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${LOG_BOLD}[$(_timestamp)] RESULT: $operation $service_id — ${LOG_GREEN}PASS${LOG_NC} ($(_format_duration $duration))${LOG_NC}"
        _record_result "$service_id" "$operation" "PASS" "$duration"
    else
        echo -e "${LOG_BOLD}[$(_timestamp)] RESULT: $operation $service_id — ${LOG_RED}FAIL${LOG_NC} (exit code $exit_code, $(_format_duration $duration))${LOG_NC}"
        _record_result "$service_id" "$operation" "FAIL" "$duration"
    fi

    # After undeploy, wait for Kubernetes namespace cleanup to avoid race conditions
    # (namespace deletion is async — next deploy may fail if namespace is still terminating)
    if [[ "$operation" == "undeploy" && $exit_code -eq 0 ]]; then
        sleep 5
    fi

    return $exit_code
}

# ============================================================
# Summary Table
# ============================================================

print_test_summary() {
    local test_end_time="$1"
    local total_duration="$2"

    echo ""
    print_section "Test Summary"
    echo "Finished: $(_datetime)"
    echo "Duration: $(_format_duration $total_duration)"

    if [[ $_TEST_FAILED -eq 1 ]]; then
        # Find the failed operation
        for entry in "${_TEST_RESULTS[@]}"; do
            local sid="${entry%%|*}"
            local rest="${entry#*|}"
            local op="${rest%%|*}"
            rest="${rest#*|}"
            local result="${rest%%|*}"
            if [[ "$result" == "FAIL" ]]; then
                echo -e "${LOG_RED}STOPPED: $op $sid FAILED${LOG_NC}"
                break
            fi
        done
    fi
    echo ""

    # Collect unique service IDs in order
    local -a seen_services=()
    local -A service_deploy=()
    local -A service_undeploy=()
    local -A service_verify=()

    for entry in "${_TEST_RESULTS[@]}"; do
        local sid="${entry%%|*}"
        local rest="${entry#*|}"
        local op="${rest%%|*}"
        rest="${rest#*|}"
        local result="${rest%%|*}"

        # Track order of first appearance
        local found=0
        for s in "${seen_services[@]}"; do
            [[ "$s" == "$sid" ]] && found=1 && break
        done
        [[ $found -eq 0 ]] && seen_services+=("$sid")

        case "$op" in
            deploy)   service_deploy[$sid]="$result" ;;
            undeploy) service_undeploy[$sid]="$result" ;;
            verify)   service_verify[$sid]="$result" ;;
        esac
    done

    printf "%-20s %-10s %-10s %s\n" "SERVICE" "DEPLOY" "UNDEPLOY" "VERIFY"
    echo "─────────────────────────────────────────────────────────"

    for sid in "${seen_services[@]}"; do
        local d="${service_deploy[$sid]:--}"
        local u="${service_undeploy[$sid]:--}"
        local v="${service_verify[$sid]:--}"

        # Colorize
        [[ "$d" == "PASS" ]] && d="${LOG_GREEN}PASS${LOG_NC}"
        [[ "$d" == "FAIL" ]] && d="${LOG_RED}FAIL${LOG_NC}"
        [[ "$u" == "PASS" ]] && u="${LOG_GREEN}PASS${LOG_NC}"
        [[ "$u" == "FAIL" ]] && u="${LOG_RED}FAIL${LOG_NC}"
        [[ "$v" == "PASS" ]] && v="${LOG_GREEN}PASS${LOG_NC}"
        [[ "$v" == "FAIL" ]] && v="${LOG_RED}FAIL${LOG_NC}"

        printf "%-20s %-10b %-10b %b\n" "$sid" "$d" "$u" "$v"
    done

    echo "─────────────────────────────────────────────────────────"

    local total=${#_TEST_RESULTS[@]}
    local passed=0
    for entry in "${_TEST_RESULTS[@]}"; do
        local rest="${entry#*|}"
        rest="${rest#*|}"
        local result="${rest%%|*}"
        [[ "$result" == "PASS" ]] && ((passed++)) || true
    done

    if [[ $_TEST_FAILED -eq 1 ]]; then
        echo -e "Result: ${LOG_RED}FAILED${LOG_NC} ($passed/$total operations passed)"
    else
        echo -e "Result: ${LOG_GREEN}ALL PASSED${LOG_NC} ($passed/$total operations)"
    fi
}

# ============================================================
# Main Test Runner
# ============================================================

run_integration_tests() {
    local dry_run=false
    local clean=false
    local only_services=()

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --clean)  clean=true; shift ;;
            --only)
                shift
                while [[ $# -gt 0 && "$1" != --* ]]; do
                    only_services+=("$1")
                    shift
                done
                ;;
            *) log_error "Unknown option: $1"; return 1 ;;
        esac
    done

    # Build the plan
    build_test_plan "${only_services[@]}"

    # Dry run - just print and exit
    if [[ "$dry_run" == "true" ]]; then
        print_test_plan
        return 0
    fi

    # Check for clean cluster state
    local deployed_list=""
    deployed_list=$(_check_clean_state) || true

    if [[ -n "$deployed_list" ]]; then
        if [[ "$clean" == "true" ]]; then
            print_section "Cleaning cluster before test"
            echo "Deployed services found — undeploying all before test..."
            echo ""
            if ! _clean_cluster; then
                log_error "Cleanup failed — cannot proceed with tests"
                return 1
            fi
            echo ""
        else
            log_error "Cluster is not in a clean state. The following services are deployed:"
            echo ""
            echo "$deployed_list" | while IFS= read -r sid; do
                echo "  - $sid"
            done
            echo ""
            echo "Run with --clean to undeploy all services first:"
            echo "  ./uis test-all --clean"
            return 1
        fi
    fi

    # Set up log file — redirect stdout+stderr through tee in the current shell
    # so that arrays (_TEST_RESULTS etc.) are preserved
    local log_file="/tmp/uis-test-all-$(date '+%Y-%m-%d-%H%M%S').log"

    # Save original file descriptors
    exec 3>&1 4>&2
    # Redirect stdout+stderr through tee (appending to log file)
    exec > >(tee "$log_file") 2>&1

    _run_tests_inner "$log_file"
    local exit_code=$?

    # Restore original file descriptors
    exec 1>&3 2>&4 3>&- 4>&-
    # Give tee a moment to flush
    sleep 0.2

    echo ""
    echo "Log file: $log_file"

    return $exit_code
}

_run_tests_inner() {
    local log_file="$1"
    local total_services=$(( ${#_FOUNDATION_SERVICES[@]} + ${#_REGULAR_SERVICES[@]} ))

    # Reset results
    _TEST_RESULTS=()
    _TEST_FAILED=0

    # Count total operations
    local total_ops=0
    for entry in "${_FOUNDATION_SERVICES[@]}"; do
        total_ops=$((total_ops + 1))  # deploy
    done
    for entry in "${_REGULAR_SERVICES[@]}"; do
        local sid=$(_entry_id "$entry")
        total_ops=$((total_ops + 1))  # deploy
        local verify_cmd=""
        verify_cmd=$(_get_verify_command "$sid") || true
        [[ -n "$verify_cmd" ]] && total_ops=$((total_ops + 1))  # verify
        total_ops=$((total_ops + 1))  # undeploy
    done
    for entry in "${_FOUNDATION_SERVICES[@]}"; do
        total_ops=$((total_ops + 1))  # undeploy
    done

    # Print header
    print_section "UIS Integration Test"
    echo "Started: $(_datetime)"
    echo "Services: $total_services (skipping ${#_SKIPPED_SERVICES[@]}: $(printf '%s ' "${_SKIPPED_SERVICES[@]}" | sed 's/:[0-9]*//g'))"
    echo "Operations: $total_ops"
    echo "Log file: $log_file"

    local test_start_time
    test_start_time=$(date +%s)
    local step=1

    # Phase 1: Deploy foundation services
    echo ""
    echo -e "${LOG_BOLD}── Phase 1: Deploy foundation services ──${LOG_NC}"

    for entry in "${_FOUNDATION_SERVICES[@]}"; do
        local sid=$(_entry_id "$entry")
        if ! _run_test_operation "$sid" "deploy" "$step" "$total_ops" "$total_services"; then
            local test_end_time
            test_end_time=$(date +%s)
            print_test_summary "$test_end_time" "$((test_end_time - test_start_time))"
            return 1
        fi
        step=$((step + 1))
    done

    # Phase 2: Test regular services (deploy + verify + undeploy)
    echo ""
    echo -e "${LOG_BOLD}── Phase 2: Test regular services ──${LOG_NC}"

    for entry in "${_REGULAR_SERVICES[@]}"; do
        local sid=$(_entry_id "$entry")

        # Deploy
        if ! _run_test_operation "$sid" "deploy" "$step" "$total_ops" "$total_services"; then
            local test_end_time
            test_end_time=$(date +%s)
            print_test_summary "$test_end_time" "$((test_end_time - test_start_time))"
            return 1
        fi
        step=$((step + 1))

        # Verify (if applicable)
        local verify_cmd=""
        verify_cmd=$(_get_verify_command "$sid") || true
        if [[ -n "$verify_cmd" ]]; then
            if ! _run_test_operation "$sid" "verify" "$step" "$total_ops" "$total_services"; then
                local test_end_time
                test_end_time=$(date +%s)
                print_test_summary "$test_end_time" "$((test_end_time - test_start_time))"
                return 1
            fi
            step=$((step + 1))
        fi

        # Undeploy
        if ! _run_test_operation "$sid" "undeploy" "$step" "$total_ops" "$total_services"; then
            local test_end_time
            test_end_time=$(date +%s)
            print_test_summary "$test_end_time" "$((test_end_time - test_start_time))"
            return 1
        fi
        step=$((step + 1))
    done

    # Phase 3: Cleanup foundation services (reverse order)
    echo ""
    echo -e "${LOG_BOLD}── Phase 3: Cleanup foundation services ──${LOG_NC}"

    local i
    for (( i=${#_FOUNDATION_SERVICES[@]}-1; i>=0; i-- )); do
        local sid=$(_entry_id "${_FOUNDATION_SERVICES[$i]}")
        if ! _run_test_operation "$sid" "undeploy" "$step" "$total_ops" "$total_services"; then
            local test_end_time
            test_end_time=$(date +%s)
            print_test_summary "$test_end_time" "$((test_end_time - test_start_time))"
            return 1
        fi
        step=$((step + 1))
    done

    # All passed - print summary
    local test_end_time
    test_end_time=$(date +%s)
    print_test_summary "$test_end_time" "$((test_end_time - test_start_time))"
    return 0
}
