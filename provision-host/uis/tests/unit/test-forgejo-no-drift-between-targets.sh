#!/bin/bash
# test-forgejo-no-drift-between-targets.sh — the Rancher Desktop Forgejo install must
# stay pinned to the SAME settings as the Proxmox production install, not drift
# independently over time.
#
# Terje, 2026-10-21: "i want the IaC to be the sane [sic] so that we dont get drift
# between the two types of deployment" — the Proxmox LXC guest
# (platforms/proxmox/ansible/roles/forgejo/) and the Rancher Desktop Kubernetes service
# (635-setup-forgejo.yml) are two different provisioning mechanisms by necessity (Rancher
# Desktop has no host-guest layer at all), but the image version, config choices, and
# runner version must match — that's the whole point of reusing ops's proven settings
# instead of an independently invented install.
#
# This is a regression guard, not a one-time check: if either side's pinned version
# changes without the other, this fails loudly instead of the two installs silently
# drifting apart.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PROXMOX_FORGEJO_DEFAULTS="$REPO/platforms/proxmox/ansible/roles/forgejo/defaults/main.yml"
PROXMOX_RUNNER_DEFAULTS="$REPO/platforms/proxmox/ansible/roles/forgejo-runner/defaults/main.yml"
RD_FORGEJO_PLAYBOOK="$REPO/ansible/playbooks/635-setup-forgejo.yml"
RD_RUNNER_PLAYBOOK="$REPO/ansible/playbooks/640-setup-forgejo-runner.yml"

print_test_section "Forgejo: same pinned image on both deployment targets"

start_test "the Proxmox role's forgejo image digest is readable"
_proxmox_digest=$(grep -oE 'sha256:[0-9a-f]{64}' "$PROXMOX_FORGEJO_DEFAULTS" | head -1)
[[ -n "$_proxmox_digest" ]] && pass_test || fail_test "no digest found in $PROXMOX_FORGEJO_DEFAULTS"

start_test "635-setup-forgejo.yml pins the SAME digest, not an independently chosen one"
_rd_digest=$(grep -oE 'sha256:[0-9a-f]{64}' "$RD_FORGEJO_PLAYBOOK" | head -1)
if [[ -n "$_rd_digest" && "$_rd_digest" == "$_proxmox_digest" ]]; then
    pass_test
else
    fail_test "Proxmox pins $_proxmox_digest, Rancher Desktop pins '$_rd_digest' — these must match"
fi

print_test_section "Forgejo Runner: same version on both deployment targets (once the Proxmox side exists)"

# 🔵 A Proxmox-specific VM-kind role once lived at PROXMOX_RUNNER_DEFAULTS (urb-agents#1982) and
# was removed outright, urb-agents#1997, once the pod-based successor (640-setup-forgejo-runner.yml
# itself, targeted at Proxmox's own k3s cluster via forgejo-runner-pod-deploy.sh) was
# live-verified and covers both platforms with ONE pinned version — there is no separate Proxmox
# side left to drift against. These two checks stay as a regression guard in case a
# platform-specific role ever returns, not because one is expected to.
start_test "if the Proxmox runner role exists yet, its version is readable"
if [[ -f "$PROXMOX_RUNNER_DEFAULTS" ]]; then
    _proxmox_runner_version=$(grep -oE 'forgejo_runner_version: "[0-9][0-9.]*"' "$PROXMOX_RUNNER_DEFAULTS" | grep -oE '[0-9][0-9.]*')
    [[ -n "$_proxmox_runner_version" ]] && pass_test || fail_test "role exists but no version found in $PROXMOX_RUNNER_DEFAULTS"
else
    skip_test "no Proxmox-specific runner role (retired urb-agents#1997 in favor of the shared pod-based playbook) — nothing to compare against"
fi

start_test "640-setup-forgejo-runner.yml's pinned runner version matches the Proxmox side, if it exists"
if [[ -f "$PROXMOX_RUNNER_DEFAULTS" ]]; then
    _rd_runner_version=$(grep -oE 'forgejo_runner_version: "[0-9][0-9.]*"' "$RD_RUNNER_PLAYBOOK" | grep -oE '[0-9][0-9.]*')
    if [[ -n "$_rd_runner_version" && -n "$_proxmox_runner_version" && "$_rd_runner_version" == "$_proxmox_runner_version" ]]; then
        pass_test
    else
        fail_test "Proxmox pins '$_proxmox_runner_version', Rancher Desktop pins '$_rd_runner_version' — these must match"
    fi
else
    skip_test "no Proxmox-specific runner role — nothing to compare against"
fi

print_test_section "Service metadata: the dependency chain is correct"

start_test "service-forgejo-runner.sh requires service-forgejo.sh"
grep -q '^SCRIPT_REQUIRES="forgejo"$' "$REPO/provision-host/uis/services/management/service-forgejo-runner.sh" \
    && pass_test || fail_test "SCRIPT_REQUIRES is not exactly 'forgejo'"

start_test "service-forgejo.sh and service-forgejo-runner.sh each point at a playbook that exists"
_ok=1
for svc in service-forgejo.sh service-forgejo-runner.sh; do
    _f="$REPO/provision-host/uis/services/management/$svc"
    _pb=$(grep -oE 'SCRIPT_PLAYBOOK="[^"]+"' "$_f" | cut -d'"' -f2)
    [[ -f "$REPO/ansible/playbooks/$_pb" ]] || { _ok=0; echo "  missing: $svc -> $_pb"; }
done
[[ "$_ok" -eq 1 ]] && pass_test || fail_test "a referenced playbook does not exist"

print_summary
