#!/bin/bash
# platform-switching.sh — Shared helpers for `./uis platform list / use` + Layer 1 banner.
#
# Spec: website/docs/ai-developer/plans/active/PLAN-platform-list-use-and-banner.md
# Investigation: website/docs/ai-developer/plans/backlog/INVESTIGATE-active-cluster-visibility-ux.md
#
# Functions:
#   pf_active_platform           Echo kubectl current-context from kubeconf-all.
#   pf_probe_reachable <ctx>     Return 0 if API reachable (3s timeout), else non-zero.
#   pf_lockstep_flip <platform>  Atomic write: kubectl context + cluster-config.sh.
#   pf_list_platforms            Echo platform names (rancher-desktop + platforms/*).
#   pf_platform_summary <plat>   Invoke <plat>/scripts/status.sh --summary, validate, echo.
#   pf_banner [opts]             Layer 1 banner to stderr; honors UIS_BANNER_PRINTED.
#
# Sourced by: provision-host/uis/manage/uis-cli.sh (cmd_platform_list / cmd_platform_use
# and every cluster-touching cmd_<verb> for the banner), platforms/azure-aks/scripts/
# 02-post-apply.sh + 03-destroy.sh (lockstep writer for auto-flip/auto-reset).
#
# Container-fixed paths. The kubeconf-all sits at the in-container location (NOT
# bind-mounted) to keep kubectl's flock working on Rancher Desktop's lima VM —
# the bind-mounted path under .uis.secrets/generated/kubeconfig/ breaks flock.
PF_KUBECONFIG="${PF_KUBECONFIG:-/mnt/urbalurbadisk/kubeconfig/kubeconf-all}"
PF_CLUSTER_CONFIG="${PF_CLUSTER_CONFIG:-/mnt/urbalurbadisk/.uis.extend/cluster-config.sh}"
PF_PLATFORMS_DIR="${PF_PLATFORMS_DIR:-/mnt/urbalurbadisk/platforms}"
PF_PROBE_TIMEOUT="${PF_PROBE_TIMEOUT:-3s}"
# The legacy bind-mounted kubeconf-all consumed by ~100 ansible playbooks
# (see 04-merge-kubeconf.yml step 30's comment). pf_lockstep_flip keeps it
# byte-identical to PF_KUBECONFIG via plain cp — kubectl writes can't touch
# this path due to the lima/9P flock issue, but cp is fine.
PF_LEGACY_KUBECONFIG="${PF_LEGACY_KUBECONFIG:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"

# C-1 enum — the only valid <state> values status.sh --summary may emit.
PF_VALID_STATES_REGEX='^(not-initialized|configured-not-running|running|unreachable)$'


# ----- pf_ensure_kubeconf_seeded ----------------------------------------------
# Bootstrap rancher-desktop into the merge dir so 04-merge-kubeconf.yml builds
# a kubeconf-all that contains rancher-desktop. The merged kubeconfig is built
# by 02-post-apply.sh during AKS provisioning, but `platform list` is the
# discovery command novices use *before* any cluster work, so we need a seed
# even on fresh containers. F15 from talk48.
#
# Strategy: when the seed file (rancher-desktop-kubeconf) is missing in the
# merge dir, extract the rancher-desktop context from the bind-mounted host
# kubeconfig at /home/ansible/.kube/config and write it to:
#   - rancher-desktop-kubeconf — the per-platform seed file 04-merge-kubeconf.yml
#     picks up. Ensures rancher-desktop survives every merge that runs.
#   - kubeconf-all + legacy kubeconf-all (only when kubeconf-all is missing) —
#     so `platform list` / `platform use` work right now, before any merge.
#
# The idempotency token is the seed file (rancher-desktop-kubeconf), NOT
# kubeconf-all. F18 from talk50: gating on kubeconf-all was wrong because
# 02-post-apply.sh can create kubeconf-all via the merge without going through
# the seeder, leaving rancher-desktop out of the merged kubeconfig forever
# and cascading to a failed auto-reset on destroy.
#
# Safe to call from any pf_* entry point AND from 02-post-apply.sh before its
# merge step. Returns 0 immediately if already seeded, the host kubeconfig is
# missing, or the host has no rancher-desktop context (clean CI env).
pf_ensure_kubeconf_seeded() {
    local kc_dir
    kc_dir="$(dirname "$PF_KUBECONFIG")"
    local seed_file="$kc_dir/rancher-desktop-kubeconf"

    # Idempotent based on the seed file — the actual artifact we're
    # responsible for producing. (Pre-F18 fix this was `[[ -f "$PF_KUBECONFIG" ]]`
    # which had the talk50 hole.)
    [[ -f "$seed_file" ]] && return 0

    local host_kc="/home/ansible/.kube/config"
    [[ -f "$host_kc" ]] || return 0

    # Does the host have a rancher-desktop context to seed from?
    KUBECONFIG="$host_kc" kubectl config get-contexts rancher-desktop \
        >/dev/null 2>&1 || return 0

    mkdir -p "$kc_dir" 2>/dev/null || return 0

    # Extract just the rancher-desktop context (--minify drops other contexts
    # the user might have on their host; --flatten inlines cert/key data so
    # the file is self-contained).
    KUBECONFIG="$host_kc" kubectl config view \
        --minify --context=rancher-desktop --flatten \
        > "$seed_file" 2>/dev/null || { rm -f "$seed_file"; return 0; }
    chmod 600 "$seed_file" 2>/dev/null || true

    # If kubeconf-all is missing (e.g. first-ever seed before any merge has
    # run — the `./uis platform list` cold-start case), write it from the seed
    # so platform list / platform use work right away.
    # If kubeconf-all already exists (e.g. from a prior platform up's merge
    # that didn't include rancher-desktop), don't overwrite it — the next
    # merge in 02-post-apply.sh will pick up the seed file we just wrote and
    # rebuild kubeconf-all correctly.
    if [[ ! -f "$PF_KUBECONFIG" ]]; then
        cp --remove-destination "$seed_file" "$PF_KUBECONFIG" 2>/dev/null || true
        chmod 600 "$PF_KUBECONFIG" 2>/dev/null || true
    fi

    # Mirror to the legacy bind-mounted kubeconfig — the ~100 ansible playbooks
    # under ansible/playbooks/ read from THERE, not from PF_KUBECONFIG.
    #
    # ⚠️ DELIBERATELY NOT NESTED INSIDE THE CHECK ABOVE. It used to be, and that
    # was the defect: once PF_KUBECONFIG existed as a real file, this block never
    # ran again — so the legacy path kept whatever it had, which on first-run is
    # a SYMLINK to /home/ansible/.kube/config. That symlink cannot be read back
    # through the bind mount ("operation not permitted"), so every kubectl in
    # every playbook failed, and every verify reported healthy services as
    # unhealthy. A container restart was enough to land in that state.
    #
    # The two files have independent lifetimes; they must be checked
    # independently. Found by the independent tester (2026-08-25), who nearly
    # attributed it to an unrelated release.
    pf_ensure_legacy_kubeconf "$seed_file"
}


# ----- pf_ensure_legacy_kubeconf ---------------------------------------------
# Guarantee the legacy bind-mounted kubeconfig is a REAL, READABLE file.
#
# Every ansible playbook reads this path. If it is a symlink into the
# container's own home, it is unreadable through the bind mount and everything
# fails in a way that looks like broken services rather than broken config.
pf_ensure_legacy_kubeconf() {
    local seed_file="${1:-}"
    local legacy_dir
    legacy_dir="$(dirname "$PF_LEGACY_KUBECONFIG")"
    [[ -d "$legacy_dir" ]] || return 0

    # A symlink here is ALWAYS wrong, even when it resolves: `-f` follows
    # symlinks, so a plain existence test says "fine" about the exact state that
    # breaks everything. Test the link itself.
    local needs_replacing=false
    if [[ -L "$PF_LEGACY_KUBECONFIG" ]]; then
        needs_replacing=true
    elif [[ ! -f "$PF_LEGACY_KUBECONFIG" ]]; then
        needs_replacing=true
    elif [[ ! -r "$PF_LEGACY_KUBECONFIG" ]]; then
        needs_replacing=true
    fi

    if [[ "$needs_replacing" == "true" ]]; then
        local source_file="$PF_KUBECONFIG"
        [[ -f "$source_file" ]] || source_file="$seed_file"
        [[ -n "$source_file" && -f "$source_file" ]] || return 0

        # Errors are NOT swallowed here. The previous version ended every line
        # with `2>/dev/null || true`, so a failure to fix this left no trace and
        # the next symptom appeared somewhere unrelated.
        if ! cp --remove-destination "$source_file" "$PF_LEGACY_KUBECONFIG" 2>/dev/null; then
            echo "WARNING: could not write $PF_LEGACY_KUBECONFIG from $source_file." >&2
            echo "         Ansible playbooks read that path; kubectl will fail for all of them." >&2
            return 1
        fi
        chmod 600 "$PF_LEGACY_KUBECONFIG" 2>/dev/null || true
    fi

    # Assert the outcome, not the command. A readable real file is the thing
    # that matters, and it is cheap to check.
    if [[ ! -r "$PF_LEGACY_KUBECONFIG" ]] || [[ -L "$PF_LEGACY_KUBECONFIG" ]]; then
        echo "WARNING: $PF_LEGACY_KUBECONFIG is still not a readable regular file." >&2
        echo "         Every ansible playbook reads it; expect kubectl failures that" >&2
        echo "         look like unhealthy services." >&2
        return 1
    fi
    return 0
}


# ----- pf_active_platform -----------------------------------------------------
# Echo the kubectl current-context name (the active platform per Q1). Empty
# string if unset (e.g. fresh kubeconfig).
pf_active_platform() {
    pf_ensure_kubeconf_seeded
    KUBECONFIG="$PF_KUBECONFIG" kubectl config current-context 2>/dev/null || echo ""
}


# ----- pf_probe_reachable -----------------------------------------------------
# The shared primitive for "is this cluster reachable right now?". Used by
# Layer 1's banner (C-9) and by per-platform status.sh --summary (C-1 state
# machine). Targets the named context explicitly — never the bare current
# context (which would give wrong-cluster answers when probing a non-active
# platform; see F12 from talk46).
pf_probe_reachable() {
    local ctx="${1:-}"
    [[ -z "$ctx" ]] && return 2
    KUBECONFIG="$PF_KUBECONFIG" kubectl --context "$ctx" \
        --request-timeout="$PF_PROBE_TIMEOUT" \
        get --raw /version >/dev/null 2>&1
}


# ----- pf_lockstep_flip -------------------------------------------------------
# Atomic write of all three halves of "the active platform":
#   1. kubectl current-context in PF_KUBECONFIG (in-container, truth for reads, Q1)
#   2. byte-identical sync to PF_LEGACY_KUBECONFIG (bind-mounted, consumed by ~100
#      ansible playbooks like 020-setup-nginx.yml that do
#      `kubectl config current-context` with KUBECONFIG=legacy path)
#   3. cluster-config.sh's CLUSTER_TYPE + TARGET_HOST fields (cached projection
#      that service-deployment.sh reads for target_host; written here so it
#      always agrees with kubectl by construction)
#
# Three call sites converge on this function:
#   - 02-post-apply.sh's auto-flip-on-up
#   - 03-destroy.sh's auto-reset-on-down
#   - cmd_platform_use's manual flip
#
# Why all three locations: F16 from talk48 R7 — the 04-merge-kubeconf.yml
# playbook uses `kubectl config use-context {{ most_recent_basename }}` where
# `most_recent_basename` is sorted by the mtime of the *copies in temp_dir*.
# `ansible.builtin.copy` doesn't preserve source mtime by default, so when
# multiple *-kubeconf seeds are present (rancher-desktop-kubeconf from F15's
# auto-seeding + azure-aks-kubeconf from 01-apply.sh), the sort is unstable
# and the playbook may pick the wrong context. By having pf_lockstep_flip
# overwrite both kubeconf-all files immediately after the merge, the brief
# window of merge-picked-wrong-context can't leak to consumer playbooks.
# Single writer means the three locations can never silently diverge.
pf_lockstep_flip() {
    local platform="${1:?pf_lockstep_flip: missing platform argument}"

    # 1. Truth for reads (in-container).
    KUBECONFIG="$PF_KUBECONFIG" kubectl config use-context "$platform" >/dev/null

    # 2. Sync to legacy (bind-mounted). cp instead of kubectl — kubectl writes
    # to the bind mount trigger the lima/9P flock phantom-file bug (see
    # 04-merge-kubeconf.yml step 30 comment). Plain `cp` doesn't use flock; safe.
    # --remove-destination handles the symlink that lives at the legacy path on
    # first-run (kubeconf-all -> /home/ansible/.kube/config); without it cp
    # follows the symlink into the read-only host kubeconfig and fails EROFS.
    if [[ -f "$PF_KUBECONFIG" ]]; then
        local legacy_dir
        legacy_dir="$(dirname "$PF_LEGACY_KUBECONFIG")"
        if [[ -d "$legacy_dir" ]]; then
            cp --remove-destination "$PF_KUBECONFIG" "$PF_LEGACY_KUBECONFIG" 2>/dev/null || true
            chmod 600 "$PF_LEGACY_KUBECONFIG" 2>/dev/null || true
        fi
    fi

    # 3. Cached projection. By convention CLUSTER_TYPE == TARGET_HOST == platform
    # directory name (per the investigation's edge case #10). Write both for
    # backward compat with existing ansible readers; future work can collapse.
    if [[ -f "$PF_CLUSTER_CONFIG" ]]; then
        sed -i.bak \
            -e "s|^CLUSTER_TYPE=.*|CLUSTER_TYPE=\"$platform\"|" \
            -e "s|^TARGET_HOST=.*|TARGET_HOST=\"$platform\"|" \
            "$PF_CLUSTER_CONFIG"
        rm -f "${PF_CLUSTER_CONFIG}.bak"
    fi
}


# ----- pf_remove_context ------------------------------------------------------
# Delete a kubectl context (plus the cluster + user entries it references)
# from kubeconf-all in-container, then sync to legacy. Idempotent — silent
# no-op if the context isn't present.
#
# Called from per-platform 03-destroy.sh scripts after a successful teardown.
# Without this cleanup, `uis platform list` post-destroy shows the destroyed
# platform as `✗ unreachable (API timeout)` against the dead API server URL
# still in the kubeconfig, instead of the correct `· configured, not running`
# (env file present, no live context). F17 from talk49/50.
#
# Why also delete the cluster + user: kubectl's `delete-context` only removes
# the context entry, leaving the cluster/user entries behind as orphans. They
# don't affect platform list semantics but bloat the file over destroy cycles
# and leak the stale API server URL into anything that reads the merged config.
pf_remove_context() {
    local context="${1:?pf_remove_context: missing context argument}"

    [[ -f "$PF_KUBECONFIG" ]] || return 0
    KUBECONFIG="$PF_KUBECONFIG" kubectl config get-contexts "$context" \
        >/dev/null 2>&1 || return 0

    # Capture the cluster + user names this context references before deleting
    # the context (which is what makes them findable).
    local cluster_ref user_ref
    cluster_ref="$(KUBECONFIG="$PF_KUBECONFIG" kubectl config view \
        -o "jsonpath={.contexts[?(@.name=='$context')].context.cluster}" 2>/dev/null)"
    user_ref="$(KUBECONFIG="$PF_KUBECONFIG" kubectl config view \
        -o "jsonpath={.contexts[?(@.name=='$context')].context.user}" 2>/dev/null)"

    KUBECONFIG="$PF_KUBECONFIG" kubectl config delete-context "$context" \
        >/dev/null 2>&1 || true
    [[ -n "$cluster_ref" ]] && \
        KUBECONFIG="$PF_KUBECONFIG" kubectl config delete-cluster "$cluster_ref" \
            >/dev/null 2>&1 || true
    [[ -n "$user_ref" ]] && \
        KUBECONFIG="$PF_KUBECONFIG" kubectl config delete-user "$user_ref" \
            >/dev/null 2>&1 || true

    # Sync to legacy bind-mount. Plain cp — kubectl writes to the bind mount
    # trigger the lima/9P flock phantom-file bug (see PR #163).
    if [[ -d "$(dirname "$PF_LEGACY_KUBECONFIG")" ]]; then
        cp --remove-destination "$PF_KUBECONFIG" "$PF_LEGACY_KUBECONFIG" \
            2>/dev/null || true
        chmod 600 "$PF_LEGACY_KUBECONFIG" 2>/dev/null || true
    fi
}


# ----- pf_list_platforms ------------------------------------------------------
# Emit the inventory of "potential platforms UIS knows about" to stdout, one
# name per line. Sources per Q3:
#   - rancher-desktop hard-coded (always present; installed at OS level, no init.sh)
#   - Every platforms/<name>/scripts/init.sh directory listing, skipping any
#     name starting with _ or . (hidden/WIP directories — edge case #8)
#
# rancher-desktop is emitted first so it lands at the top of `list`'s table.
pf_list_platforms() {
    echo "rancher-desktop"
    local script_path name
    for script_path in "$PF_PLATFORMS_DIR"/*/scripts/init.sh; do
        [[ -f "$script_path" ]] || continue
        name="$(basename "$(dirname "$(dirname "$script_path")")")"
        case "$name" in
            _*|.*) continue ;;
            rancher-desktop) continue ;;  # already emitted above
        esac
        echo "$name"
    done
}


# ----- pf_platform_summary ----------------------------------------------------
# Invoke <platform>/scripts/status.sh --summary [--offline|--deep] and capture
# the tab-separated <state>\t<hint> output. Validates field 1 is a valid C-1
# enum state. Echoes the captured line on stdout, returns 0 on success, non-zero
# if the script is missing, errors, or emits malformed output (caller renders
# `? error` for that row).
#
# Extra args after $1 are passed through unchanged — supports both
#   pf_platform_summary azure-aks
#   pf_platform_summary azure-aks --offline
#   pf_platform_summary azure-aks --deep
pf_platform_summary() {
    local platform="${1:?pf_platform_summary: missing platform argument}"
    shift
    local script="$PF_PLATFORMS_DIR/$platform/scripts/status.sh"
    [[ -x "$script" ]] || return 1
    local line
    line="$("$script" --summary "$@" 2>/dev/null)" || return 1
    local state="${line%%	*}"
    [[ "$state" =~ $PF_VALID_STATES_REGEX ]] || return 1
    echo "$line"
}


# ----- pf_banner --------------------------------------------------------------
# Layer 1 banner (C-9). Writes to stderr per C-9's output-stream decision
# (success doesn't drown out piped stdout; failure stays visible).
#
# Flags:
#   --silent-if-set    Suppress banner when UIS_BANNER_PRINTED=1 is set (C-4
#                      child-suppression for `stack install` → child deploys).
#   --check-reachable  Run the reachability probe and surface the result —
#                      emits the four C-9 cases. Without this flag the banner
#                      just names the active platform without probing.
#
# Returns 0 on the success/warn cases (1, 3 — caller proceeds). Returns 1 on
# the abort cases (2, 4 — caller is expected to exit). The function does NOT
# call `exit` itself so it's composable in any caller (dispatcher / sourced
# helper / test harness).
pf_banner() {
    local silent_if_set=0
    local check_reachable=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --silent-if-set) silent_if_set=1; shift ;;
            --check-reachable) check_reachable=1; shift ;;
            *) shift ;;  # ignore unknown flags
        esac
    done

    # C-4 — child invocation under `stack install` etc.
    if (( silent_if_set )) && [[ "${UIS_BANNER_PRINTED:-0}" == "1" ]]; then
        return 0
    fi

    local active
    active="$(pf_active_platform)"

    # Case 4 — no active context. Abort with the rancher-desktop recovery hint.
    if [[ -z "$active" ]]; then
        {
            echo "⚠  No active kubectl context set."
            echo "   Run './uis platform use rancher-desktop' (the default) or './uis platform list' to see what you have."
            echo "   Aborting."
        } >&2
        return 1
    fi

    # Is the active context a UIS-managed platform?
    local is_uis_platform=0
    if [[ "$active" == "rancher-desktop" ]] || [[ -f "$PF_PLATFORMS_DIR/$active/scripts/init.sh" ]]; then
        is_uis_platform=1
    fi

    # Case 3 — active context is not a UIS platform (personal cluster etc.).
    # One-liner warning; caller proceeds.
    if (( ! is_uis_platform )); then
        echo "⚠  Platform: $active (not a UIS platform — proceeding with kubectl context anyway)" >&2
        # Mark printed so children don't re-banner.
        export UIS_BANNER_PRINTED=1
        return 0
    fi

    # If --check-reachable wasn't requested, name the platform and return.
    if (( ! check_reachable )); then
        echo "ℹ  Platform: $active" >&2
        export UIS_BANNER_PRINTED=1
        return 0
    fi

    # Case 1 — UIS platform AND reachable. One-liner success.
    if pf_probe_reachable "$active"; then
        echo "ℹ  Platform: $active (reachable)" >&2
        export UIS_BANNER_PRINTED=1
        return 0
    fi

    # Case 2 — UIS platform BUT unreachable. Multi-line block + abort. Pull
    # the platform-specific hint from the active platform's status.sh --summary
    # field 2 (only on this error path; common path doesn't pay this cost).
    local summary hint=""
    if summary="$(pf_platform_summary "$active" 2>/dev/null)"; then
        hint="${summary#*	}"
    fi
    {
        echo "✗  Platform: $active, but the API server is unreachable."
        [[ -n "$hint" ]] && echo "   $hint"
        echo "   Recover with: ./uis platform status $active"
        echo "   Or switch:    ./uis platform use rancher-desktop  (or another reachable platform)"
        echo "   Aborting."
    } >&2
    return 1
}


# Make the functions available to child shells if needed (sub-shell invocations
# from ansible's `shell` module, etc.). Most callers source this file directly.
export -f pf_ensure_kubeconf_seeded pf_active_platform pf_probe_reachable
export -f pf_lockstep_flip pf_remove_context pf_list_platforms
export -f pf_platform_summary pf_banner
