#!/bin/bash
# test-pf-kubeconf-restored.sh — PF_KUBECONFIG must survive a `uis pull`.
#
# PF_KUBECONFIG sits under the container's own image/working layer, NOT a
# persistent bind mount — a `uis pull` wipes it, same as every other
# non-.uis.secrets/.uis.extend path. PF_LEGACY_KUBECONFIG DOES persist (it's
# under .uis.secrets/generated/), but pf_lockstep_flip (and pf_probe_reachable/
# pf_context_exists/pf_active_platform) used to read/write PF_KUBECONFIG
# directly with no existence check — `kubectl config use-context` failed
# outright with "no context exists" even when that exact context was present
# and correct in the persistent legacy copy the whole time (found live, ops,
# urb-agents#1982, verifying the forgejo-runner pod build).
#
# pf_ensure_kubeconf_restored (new) closes this: regenerate PF_KUBECONFIG from
# the persistent legacy copy via plain `cp` — never kubectl, which is what
# breaks on the bind-mounted legacy path in the first place (the lima/9P flock
# phantom-file bug this file's own header already documents) — whenever
# PF_KUBECONFIG is missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
fi

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

# Fake kubectl: "config use-context <name>" succeeds only if $KUBECONFIG is a
# real file that actually names that context — exactly real kubectl's
# contract ("error: no context exists with the name: ...") for the failure
# this test needs to reproduce and then prove fixed.
_FAKE_BIN="$_tmp/bin"
mkdir -p "$_FAKE_BIN"
cat > "$_FAKE_BIN/kubectl" <<'EOF'
#!/bin/bash
if [[ "$1" == "config" && "$2" == "use-context" ]]; then
    if [[ -n "$KUBECONFIG" && -f "$KUBECONFIG" ]] && grep -q "name: $3\$" "$KUBECONFIG" 2>/dev/null; then
        exit 0
    fi
    echo "error: no context exists with the name: \"$3\"" >&2
    exit 1
fi
exit 0
EOF
chmod +x "$_FAKE_BIN/kubectl"

_fake_kubeconfig_with_context() {
    cat <<EOF
apiVersion: v1
kind: Config
contexts:
  - name: $1
EOF
}

# ============================================================================
print_test_section "pf_ensure_kubeconf_restored — pure behavior"
# ============================================================================

export PF_KUBECONFIG="$_tmp/kubeconf-all"
export PF_LEGACY_KUBECONFIG="$_tmp/legacy/kubeconf-all"
source "$UIS_LIB/platform-switching.sh"

start_test "pf_ensure_kubeconf_restored is defined after sourcing platform-switching.sh"
declare -F pf_ensure_kubeconf_restored >/dev/null && pass_test || fail_test "function not found"

start_test "is a no-op when PF_KUBECONFIG already exists (does not overwrite it)"
rm -f "$PF_KUBECONFIG"
echo "ORIGINAL-CONTENT" > "$PF_KUBECONFIG"
mkdir -p "$(dirname "$PF_LEGACY_KUBECONFIG")"
echo "LEGACY-CONTENT" > "$PF_LEGACY_KUBECONFIG"
pf_ensure_kubeconf_restored
if [[ "$(cat "$PF_KUBECONFIG")" == "ORIGINAL-CONTENT" ]]; then
    pass_test
else
    fail_test "PF_KUBECONFIG was overwritten even though it already existed"
fi

start_test "restores PF_KUBECONFIG from the legacy copy when PF_KUBECONFIG is missing"
rm -f "$PF_KUBECONFIG"
echo "RESTORED-FROM-LEGACY" > "$PF_LEGACY_KUBECONFIG"
pf_ensure_kubeconf_restored
if [[ -f "$PF_KUBECONFIG" ]] && [[ "$(cat "$PF_KUBECONFIG")" == "RESTORED-FROM-LEGACY" ]]; then
    pass_test
else
    fail_test "PF_KUBECONFIG was not restored from PF_LEGACY_KUBECONFIG"
fi

start_test "is a safe no-op (returns 0, no crash) when BOTH files are missing"
rm -f "$PF_KUBECONFIG" "$PF_LEGACY_KUBECONFIG"
pf_ensure_kubeconf_restored && pass_test || fail_test "expected a clean return even with nothing to restore from"

start_test "restores even when PF_KUBECONFIG's own directory does not exist yet"
rm -rf "$_tmp/fresh-dir"
export PF_KUBECONFIG="$_tmp/fresh-dir/kubeconf-all"
echo "RESTORED-INTO-FRESH-DIR" > "$PF_LEGACY_KUBECONFIG"
pf_ensure_kubeconf_restored
if [[ -f "$PF_KUBECONFIG" ]] && [[ "$(cat "$PF_KUBECONFIG")" == "RESTORED-INTO-FRESH-DIR" ]]; then
    pass_test
else
    fail_test "PF_KUBECONFIG was not restored when its parent directory was missing"
fi

# ============================================================================
print_test_section "pf_lockstep_flip — survives a PF_KUBECONFIG wiped by 'uis pull'"
# ============================================================================

export PF_KUBECONFIG="$_tmp/kubeconf-all"
export PF_CLUSTER_CONFIG="$_tmp/does-not-exist/cluster-config.sh"  # step 3 skips cleanly

start_test "use-context fails against a missing PF_KUBECONFIG (reproduces the bug, proves the fake kubectl)"
rm -f "$PF_KUBECONFIG"
_fake_kubeconfig_with_context proxmox > "$PF_LEGACY_KUBECONFIG"
if PATH="$_FAKE_BIN:$PATH" KUBECONFIG="$PF_KUBECONFIG" kubectl config use-context proxmox 2>/dev/null; then
    fail_test "expected the fake kubectl to fail against a missing/empty PF_KUBECONFIG"
else
    pass_test
fi

start_test "pf_lockstep_flip succeeds anyway — it restores PF_KUBECONFIG first"
# 🔵 ASSERTING ON OUTPUT, NOT THE RETURN CODE — found via mutation-testing this exact
# assertion: pf_lockstep_flip's own step 3 is `if [[ -f "$PF_CLUSTER_CONFIG" ]]; then ...
# fi` with no `else`, which bash evaluates to exit 0 whenever the file is absent — so the
# function's own return code stays 0 even when step 1's kubectl call fails, regardless of
# this fix. That masking is pre-existing (unrelated to this fix, out of scope to change
# here), so the real signal is whether the "no context exists" error ever got printed, not
# the function's own exit status.
rm -f "$PF_KUBECONFIG"
_fake_kubeconfig_with_context proxmox > "$PF_LEGACY_KUBECONFIG"
_flip_output="$(PATH="$_FAKE_BIN:$PATH" pf_lockstep_flip proxmox 2>&1)"
if [[ "$_flip_output" != *"no context exists"* ]]; then
    pass_test
else
    fail_test "pf_lockstep_flip still hits 'no context exists' against a PF_KUBECONFIG wiped by a pull: $_flip_output"
fi

start_test "pf_lockstep_flip calls pf_ensure_kubeconf_restored before trusting PF_KUBECONFIG"
awk '/^pf_lockstep_flip\(\) \{/{f=1} f{print} f && /kubectl config use-context "\$platform"/{exit}' \
    "$UIS_LIB/platform-switching.sh" | grep -q "pf_ensure_kubeconf_restored" \
    && pass_test || fail_test "pf_lockstep_flip no longer calls pf_ensure_kubeconf_restored before use-context"

start_test "exported for sub-shell callers, same as the other pf_* helpers"
grep -q "pf_ensure_kubeconf_restored" <(grep "^export -f" "$UIS_LIB/platform-switching.sh") && pass_test \
    || fail_test "pf_ensure_kubeconf_restored missing from an export -f line"

print_summary
