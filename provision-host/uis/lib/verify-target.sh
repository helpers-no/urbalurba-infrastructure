#!/bin/bash
# verify-target.sh — run a verify playbook against THIS installation's cluster.
#
# ⚠️ WHY THIS EXISTS AS A HELPER RATHER THAN A LINE IN EACH FUNCTION.
#
# Every test playbook declares:
#
#     _target: "{{ target_host | default('rancher-desktop') }}"
#
# and then pins `kubectl --context {{ _target }}` on every task. So a verify
# invoked WITHOUT `-e target_host=...` silently targets a context named
# `rancher-desktop`, whatever this installation actually calls its cluster.
#
# On Rancher Desktop the wrong default is accidentally right, so nothing ever
# fails there. On any other cluster every kubectl call fails and the playbook
# reports THE SERVICE as broken — a healthy Dagster was reported as "the
# webserver did not answer a GraphQL query" on the production installation
# (2026-08-25), when the truth was `context "rancher-desktop" does not exist`.
#
# That is the worst shape of wrong: it blames the thing under test.
#
# 13 of 15 verify commands had omitted it. Two had it, correctly, and had each
# learned it the hard way and written a comment saying so — which is the proof
# that a convention nobody can forget beats a convention everybody must
# remember. Adding a service must not require remembering this line, so the
# helper takes the playbook and passes the target itself.
#
# Deploy and undeploy resolve the target the same way, in
# service-deployment.sh. That duplication is deliberate for now, not an
# oversight: that path is running in production and refactoring it blind, from
# a machine that cannot test it, would risk a working deploy to save a few
# lines. See the note in that file.

# Resolve the cluster this installation targets.
# Precedence: cluster-config.sh TARGET_HOST, else rancher-desktop.
uis_target_host() {
    local cluster_config="${CONFIG_DIR:-/mnt/urbalurbadisk/.uis.extend}/cluster-config.sh"
    local target_host="rancher-desktop"
    if [[ -f "$cluster_config" ]]; then
        # shellcheck source=/dev/null
        source "$cluster_config"
        target_host="${TARGET_HOST:-rancher-desktop}"
    fi
    echo "$target_host"
}

# Run a verify playbook with the target already resolved.
#
#   run_verify_playbook 360-test-dagster.yml
#   run_verify_playbook 088-test-postgrest.yml -e "_app_name=atlas"
#
# Extra args are passed through, so per-service extra-vars still work.
# The kubeconfig every ansible playbook reads. Not PF_KUBECONFIG — the ~100
# playbooks under ansible/playbooks/ use this legacy bind-mounted path.
UIS_VERIFY_KUBECONFIG="${UIS_VERIFY_KUBECONFIG:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"

# Refuse to run a verify that cannot possibly succeed, and say why.
#
# ⚠️ THIS EXISTS BECAUSE A CONFIGURATION ERROR USED TO BE REPORTED AS A BROKEN
# SERVICE. With a context that does not exist, every kubectl in the playbook
# fails, every probe returns empty, and the assertions — which are written as
# "did the expected string appear?" — report the SERVICE as unhealthy. One of
# them even speculated a cause ("the pod may be unable to reach its metadata
# database") that was entirely wrong, sending the reader to debug a database
# while the real fault was a kubectl context.
#
# An empty probe result means "I could not ask" and "the answer was wrong"
# identically, and an assertion on stdout can only ever report the second. The
# fix for that class is to not start: if we cannot ask, say so here, in
# configuration terms, before the playbook runs.
#
# Both failures below were observed in one session (2026-08-25): a
# non-existent context, and a kubeconfig left as an unreadable symlink after a
# container restart — which silently broke EVERY verify on that installation.
uis_verify_preflight() {
    local target_host="$1"

    # Test the LINK before the target. A dangling symlink fails `-e` and a
    # resolvable-but-unreadable one fails `-r`; both were seen, and both want
    # the same diagnosis, so ask about the symlink first rather than letting
    # the sub-case decide which message appears.
    if [[ -L "$UIS_VERIFY_KUBECONFIG" ]]; then
        log_error "Kubeconfig is a SYMLINK: $UIS_VERIFY_KUBECONFIG"
        log_info  "  -> $(readlink "$UIS_VERIFY_KUBECONFIG" 2>/dev/null)"
        log_info  "This path must be a real file. A symlink into the container's own"
        log_info  "home cannot be read back through the bind mount, and every ansible"
        log_info  "playbook reads it — so every verify fails and blames its service."
        log_info  "Fix: ./uis stop && ./uis start rewrites it as a real file."
        return 1
    fi

    if [[ ! -e "$UIS_VERIFY_KUBECONFIG" ]]; then
        log_error "Kubeconfig not found: $UIS_VERIFY_KUBECONFIG"
        log_info  "Every verify playbook reads that path. This is a configuration"
        log_info  "problem, not a problem with the service you are verifying."
        return 1
    fi

    if [[ ! -r "$UIS_VERIFY_KUBECONFIG" ]]; then
        log_error "Kubeconfig is not readable: $UIS_VERIFY_KUBECONFIG"
        log_info  "This is a configuration problem, not an unhealthy service."
        return 1
    fi

    # Does the context actually exist? kubectl already answers this precisely;
    # the old failure mode was that nobody asked, and its answer never appeared
    # anywhere in the output.
    local ctx_err
    if ! ctx_err="$(kubectl config get-contexts "$target_host" \
                      --kubeconfig "$UIS_VERIFY_KUBECONFIG" 2>&1 >/dev/null)"; then
        log_error "Cluster context '$target_host' does not exist in $UIS_VERIFY_KUBECONFIG"
        [[ -n "$ctx_err" ]] && log_info "kubectl: $ctx_err"
        log_info ""
        log_info "Available contexts:"
        kubectl config get-contexts -o name --kubeconfig "$UIS_VERIFY_KUBECONFIG" 2>/dev/null \
            | sed 's/^/  /' || true
        log_info ""
        log_info "TARGET_HOST comes from .uis.extend/cluster-config.sh."
        log_info "This is a configuration problem. The service was never asked."
        return 1
    fi

    return 0
}

run_verify_playbook() {
    local playbook="$1"; shift
    local target_host
    target_host="$(uis_target_host)"

    # Stated out loud. A verify that silently targets the wrong cluster is how
    # this defect survived: the output looked like a service failure, and
    # nothing on screen said which cluster had been asked.
    log_info "Target cluster: $target_host"

    # Fail as configuration BEFORE the playbook can fail as a service.
    uis_verify_preflight "$target_host" || return 2

    ansible-playbook "$ANSIBLE_DIR/$playbook" -e "target_host=$target_host" "$@"
}
