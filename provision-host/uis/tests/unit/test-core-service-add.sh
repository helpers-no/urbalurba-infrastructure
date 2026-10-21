#!/bin/bash
# test-core-service-add.sh — `uis platform core-service add <provider> <name>`, the
# per-service counterpart to `uis deploy`/`uis undeploy` for host-level CORE_SERVICES
# guests (registry/bao/garage/pg/forgejo on platforms/proxmox).
#
# Before this existed, adding one service meant hand-editing config.sh's CORE_SERVICES
# line and re-running 05-core-services-apply.sh, which touched every already-built guest
# too. This tests the two real pieces of new logic: the config.sh editor
# (07-core-service-add.sh) and the single-service scoping it depends on
# (05-core-services-apply.sh's TARGET_SERVICES).
#
# ⚠️ Does not (cannot, in this environment) test the actual Proxmox provisioning —
# `05-core-services-apply.sh` itself needs a live 3-host cluster. What's tested here is
# everything that runs BEFORE that: name validation, the config.sh mutation, and
# idempotency — all pure bash, no Proxmox dependency.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ADD_SCRIPT="$REPO/platforms/proxmox/scripts/07-core-service-add.sh"
APPLY_SCRIPT="$REPO/platforms/proxmox/scripts/05-core-services-apply.sh"

print_test_section "07-core-service-add.sh: argument and name validation"

start_test "the script exists and is executable"
[[ -x "$ADD_SCRIPT" ]] && pass_test || fail_test "not found or not executable: $ADD_SCRIPT"

start_test "no argument at all is refused, not treated as 'add nothing'"
_out=$("$ADD_SCRIPT" 2>&1); _rc=$?
[[ "$_rc" -ne 0 ]] && pass_test || fail_test "exited 0 with no service name given"

start_test "an unknown service name is refused, naming the known list"
_out=$("$ADD_SCRIPT" "not-a-real-service" 2>&1); _rc=$?
if [[ "$_rc" -ne 0 ]] && grep -q "Unknown core service" <<< "$_out"; then
    pass_test
else
    fail_test "expected a refusal naming 'Unknown core service', got (rc=$_rc): $_out"
fi

start_test "every service generate-ansible-config.sh actually builds is accepted here too"
# The two case statements (this script's validation, generate-ansible-config.sh's own
# dispatch) must list the same names — see this script's own "keep in step" comment.
# Reading generate-ansible-config.sh's case arms directly, not hand-copying its list,
# so this fails the moment the two drift instead of needing a human to notice.
_gen_names="$(grep -oE '^\s+[a-z][a-z0-9-]*\)\s+write_core_service' \
    "$REPO/platforms/proxmox/scripts/generate-ansible-config.sh" \
    | awk '{print $1}' | tr -d ')' | sort -u)"
_add_script_names="$(grep -E '^\s+[a-z][a-z0-9-]*(\|[a-z][a-z0-9-]*)*\)\s*;;' "$ADD_SCRIPT" \
    | head -1 | sed -E 's/^\s+//; s/\).*//' | tr '|' '\n' | sort -u)"
_missing=""
while IFS= read -r _n; do
    [[ -z "$_n" ]] && continue
    grep -qx "$_n" <<< "$_add_script_names" || _missing+="$_n "
done <<< "$_gen_names"
[[ -z "$_missing" ]] && pass_test || fail_test "generate-ansible-config.sh knows these but 07-core-service-add.sh would refuse them: $_missing"

print_test_section "07-core-service-add.sh: config.sh mutation"

TMP="$(create_test_dir)"
trap 'cleanup_test_dir "$TMP"' EXIT

CONFIG_UNDER_TEST="$TMP/.uis.secrets/platforms/proxmox/config.sh"

_stub_platform_dir() {
    # A real config.sh the script can edit, at the SAME persistent-state path the real script
    # computes (REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh, urb-agents#1935 — config.sh
    # must survive a container restart/uis-pull, not live inside platforms/proxmox/ itself) —
    # UIS_REPO_ROOT is set to $TMP so the script's own REPO_ROOT computation lands here instead
    # of walking up from a real checkout. 05-core-services-apply.sh is replaced by a stub that
    # just records how it was invoked — this test is about the config.sh edit and the hand-off,
    # not Proxmox provisioning itself.
    mkdir -p "$TMP/scripts" "$(dirname "$CONFIG_UNDER_TEST")"
    cp "$ADD_SCRIPT" "$TMP/scripts/"
    cat > "$TMP/scripts/05-core-services-apply.sh" <<'EOF'
#!/bin/bash
echo "STUB-APPLY-CALLED-WITH: $*" > "$(dirname "${BASH_SOURCE[0]}")/../apply-call.log"
EOF
    chmod +x "$TMP/scripts/05-core-services-apply.sh"
    echo 'CORE_SERVICES="pg bao garage registry"' > "$CONFIG_UNDER_TEST"
}

start_test "a new service is appended, not substituted for the existing list"
_stub_platform_dir
UIS_REPO_ROOT="$TMP" "$TMP/scripts/07-core-service-add.sh" forgejo >/dev/null 2>&1
grep -qx 'CORE_SERVICES="pg bao garage registry forgejo"' "$CONFIG_UNDER_TEST" \
    && pass_test || fail_test "config.sh after add: $(cat "$CONFIG_UNDER_TEST")"

start_test "the scoped apply script is called with exactly the new service name"
[[ -f "$TMP/apply-call.log" ]] && grep -qx "STUB-APPLY-CALLED-WITH: forgejo" "$TMP/apply-call.log" \
    && pass_test || fail_test "expected 'STUB-APPLY-CALLED-WITH: forgejo', got: $(cat "$TMP/apply-call.log" 2>&1)"

start_test "re-adding an already-present service does not duplicate it"
_stub_platform_dir
echo 'CORE_SERVICES="pg bao garage registry forgejo"' > "$CONFIG_UNDER_TEST"
UIS_REPO_ROOT="$TMP" "$TMP/scripts/07-core-service-add.sh" forgejo >/dev/null 2>&1
_count=$(grep -o 'forgejo' "$CONFIG_UNDER_TEST" | wc -l)
[[ "$_count" -eq 1 ]] && pass_test || fail_test "'forgejo' appears $_count times after re-adding it"

start_test "re-adding an already-present service still calls the scoped apply (repair path)"
[[ -f "$TMP/apply-call.log" ]] && grep -qx "STUB-APPLY-CALLED-WITH: forgejo" "$TMP/apply-call.log" \
    && pass_test || fail_test "expected the apply step to still run for an already-listed service"

print_test_section "05-core-services-apply.sh: single-service scoping (TARGET_SERVICES)"

start_test "an explicit arg not in config.sh's CORE_SERVICES is refused"
grep -q 'is not in config.sh' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the not-in-CORE_SERVICES refusal is missing"

start_test "the per-service loop iterates TARGET_SERVICES, not the raw CORE_SERVICES every time"
grep -qE '^for svc in \$TARGET_SERVICES; do' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the main loop no longer scopes to TARGET_SERVICES"

start_test "🔴 a scoped run still completes registry/forgejo's k3s-trust wiring if either is already configured"
# The bug this guards: a scoped 'add forgejo' run with 'registry' already in CORE_SERVICES
# (but not touched this run) must not leave REGISTRY_IP empty — k3s-registry-ensure.yml
# would then be told nothing about registry's own already-legitimate entry and refuse,
# citing it as unrecognized (see that playbook's own refuse-on-unrecognized-domain guard).
grep -q '_core_services_has registry' "$APPLY_SCRIPT" && grep -q '_core_services_has forgejo' "$APPLY_SCRIPT" \
    && pass_test || fail_test "the registry/forgejo IP backfill for a scoped run is missing"

print_summary
