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
run_verify_playbook() {
    local playbook="$1"; shift
    local target_host
    target_host="$(uis_target_host)"

    # Stated out loud. A verify that silently targets the wrong cluster is how
    # this defect survived: the output looked like a service failure, and
    # nothing on screen said which cluster had been asked.
    log_info "Target cluster: $target_host"

    ansible-playbook "$ANSIBLE_DIR/$playbook" -e "target_host=$target_host" "$@"
}
