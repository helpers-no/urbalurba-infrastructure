#!/bin/bash
# test-lab-extra-add.sh — `uis platform lab-extra add <provider> <name>`, the opt-in
# counterpart to `core-service add` for guests judged genuinely useful to SOME labs but
# not assumed as a UIS default (today, only platforms/proxmox's dns-resolver — see
# config.sh-template's "Lab extras" section and urb-agents#1970/#1971/#1972).
#
# Same shape as test-core-service-add.sh, deliberately: 08-lab-extra-add.sh/
# 09-lab-extras-apply.sh are themselves a deliberate parallel to
# 07-core-service-add.sh/05-core-services-apply.sh, kept as a separate list/script pair
# rather than folded in — this test exists to prove the parallel actually holds, not just
# assert it in a comment.
#
# ⚠️ Does not (cannot, in this environment) test the actual Proxmox provisioning — same
# caveat as test-core-service-add.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ADD_SCRIPT="$REPO/platforms/proxmox/scripts/08-lab-extra-add.sh"
APPLY_SCRIPT="$REPO/platforms/proxmox/scripts/09-lab-extras-apply.sh"
GEN_SCRIPT="$REPO/platforms/proxmox/scripts/generate-ansible-config.sh"

print_test_section "08-lab-extra-add.sh: argument and name validation"

start_test "the script exists and is executable"
[[ -x "$ADD_SCRIPT" ]] && pass_test || fail_test "not found or not executable: $ADD_SCRIPT"

start_test "no argument at all is refused, not treated as 'add nothing'"
_out=$("$ADD_SCRIPT" 2>&1); _rc=$?
[[ "$_rc" -ne 0 ]] && pass_test || fail_test "exited 0 with no extra name given"

start_test "an unknown lab extra name is refused, naming the known list"
_out=$("$ADD_SCRIPT" "not-a-real-extra" 2>&1); _rc=$?
if [[ "$_rc" -ne 0 ]] && grep -q "Unknown lab extra" <<< "$_out"; then
    pass_test
else
    fail_test "expected a refusal naming 'Unknown lab extra', got (rc=$_rc): $_out"
fi

start_test "every lab extra generate-ansible-config.sh actually builds is accepted here too"
# Same cross-check as test-core-service-add.sh's own — the two case statements (this
# script's validation, generate-ansible-config.sh's own LAB_EXTRAS dispatch) must list the
# same names. Reading generate-ansible-config.sh's case arms directly, not hand-copying
# its list, so this fails the moment the two drift instead of needing a human to notice.
# 🔴 ISOLATES THE CASE BLOCK FIRST, not a single-line regex — found running this for real: nas's
# own arm needs setup lines before its write_guest_decl call (parsing LAB_EXTRA_NAS_SHARE_MOUNTS),
# so its label and that call are no longer on the same line the way dns-resolver's one-liner arm
# is. A same-line-only regex silently extracted ONLY dns-resolver here and this whole check passed
# vacuously for nas — never actually checked it — until caught by hand. Isolating
# `case "$extra" in ... esac` first and reading every arm LABEL line within it (whether or not
# code follows on that same line) is robust to either shape.
_gen_names="$(awk '/case "\$extra" in/{f=1} f{print} /esac/{if(f)exit}' "$GEN_SCRIPT" \
    | grep -oE '^\s+[a-z][a-z0-9-]*\)' | tr -d ') ' | sort -u)"
_add_script_names="$(grep -E '^\s+[a-z][a-z0-9-]*(\|[a-z][a-z0-9-]*)*\)\s*;;' "$ADD_SCRIPT" \
    | head -1 | sed -E 's/^\s+//; s/\).*//' | tr '|' '\n' | sort -u)"
_missing=""
while IFS= read -r _n; do
    [[ -z "$_n" ]] && continue
    grep -qx "$_n" <<< "$_add_script_names" || _missing+="$_n "
done <<< "$_gen_names"
[[ -z "$_missing" ]] && pass_test || fail_test "generate-ansible-config.sh knows these but 08-lab-extra-add.sh would refuse them: $_missing"

print_test_section "08-lab-extra-add.sh: config.sh mutation"

TMP="$(create_test_dir)"
trap 'cleanup_test_dir "$TMP"' EXIT

CONFIG_UNDER_TEST="$TMP/.uis.secrets/platforms/proxmox/config.sh"

_stub_platform_dir() {
    mkdir -p "$TMP/scripts" "$(dirname "$CONFIG_UNDER_TEST")"
    cp "$ADD_SCRIPT" "$TMP/scripts/"
    cat > "$TMP/scripts/09-lab-extras-apply.sh" <<'EOF'
#!/bin/bash
echo "STUB-APPLY-CALLED-WITH: $*" > "$(dirname "${BASH_SOURCE[0]}")/../apply-call.log"
EOF
    chmod +x "$TMP/scripts/09-lab-extras-apply.sh"
    echo 'LAB_EXTRAS=""' > "$CONFIG_UNDER_TEST"
}

start_test "a new extra is appended, not substituted for the existing (empty) list"
_stub_platform_dir
UIS_REPO_ROOT="$TMP" "$TMP/scripts/08-lab-extra-add.sh" dns-resolver >/dev/null 2>&1
grep -qx 'LAB_EXTRAS=" dns-resolver"' "$CONFIG_UNDER_TEST" \
    && pass_test || fail_test "config.sh after add: $(cat "$CONFIG_UNDER_TEST")"

start_test "the scoped apply script is called with exactly the new extra name"
[[ -f "$TMP/apply-call.log" ]] && grep -qx "STUB-APPLY-CALLED-WITH: dns-resolver" "$TMP/apply-call.log" \
    && pass_test || fail_test "expected 'STUB-APPLY-CALLED-WITH: dns-resolver', got: $(cat "$TMP/apply-call.log" 2>&1)"

start_test "re-adding an already-present extra does not duplicate it"
_stub_platform_dir
echo 'LAB_EXTRAS="dns-resolver"' > "$CONFIG_UNDER_TEST"
UIS_REPO_ROOT="$TMP" "$TMP/scripts/08-lab-extra-add.sh" dns-resolver >/dev/null 2>&1
_count=$(grep -o 'dns-resolver' "$CONFIG_UNDER_TEST" | wc -l)
[[ "$_count" -eq 1 ]] && pass_test || fail_test "'dns-resolver' appears $_count times after re-adding it"

start_test "re-adding an already-present extra still calls the scoped apply (repair path)"
[[ -f "$TMP/apply-call.log" ]] && grep -qx "STUB-APPLY-CALLED-WITH: dns-resolver" "$TMP/apply-call.log" \
    && pass_test || fail_test "expected the apply step to still run for an already-listed extra"

start_test "a config.sh written before LAB_EXTRAS existed gets the line appended, not refused"
_stub_platform_dir
echo 'CORE_SERVICES="pg bao garage registry"' > "$CONFIG_UNDER_TEST"
UIS_REPO_ROOT="$TMP" "$TMP/scripts/08-lab-extra-add.sh" dns-resolver >/dev/null 2>&1
grep -qx 'LAB_EXTRAS="dns-resolver"' "$CONFIG_UNDER_TEST" \
    && pass_test || fail_test "config.sh after add on a LAB_EXTRAS-less file: $(cat "$CONFIG_UNDER_TEST")"

print_test_section "08-lab-extra-add.sh: forgejo-runner depends on forgejo (urb-agents#1982)"

start_test "forgejo-runner is refused when forgejo is not in CORE_SERVICES"
_stub_platform_dir
_out=$(UIS_REPO_ROOT="$TMP" "$TMP/scripts/08-lab-extra-add.sh" forgejo-runner 2>&1); _rc=$?
if [[ "$_rc" -ne 0 ]] && grep -q "needs 'forgejo' in CORE_SERVICES" <<< "$_out"; then
    pass_test
else
    fail_test "expected a refusal naming the forgejo dependency, got (rc=$_rc): $_out"
fi

start_test "forgejo-runner is accepted once forgejo is in CORE_SERVICES"
_stub_platform_dir
echo 'LAB_EXTRAS=""' > "$CONFIG_UNDER_TEST"
echo 'CORE_SERVICES="forgejo"' >> "$CONFIG_UNDER_TEST"
UIS_REPO_ROOT="$TMP" "$TMP/scripts/08-lab-extra-add.sh" forgejo-runner >/dev/null 2>&1
grep -qx 'LAB_EXTRAS=" forgejo-runner"' "$CONFIG_UNDER_TEST" \
    && pass_test || fail_test "config.sh after add: $(cat "$CONFIG_UNDER_TEST")"

print_test_section "09-lab-extras-apply.sh: single-extra scoping (TARGET_EXTRAS)"

start_test "an explicit arg not in config.sh's LAB_EXTRAS is refused"
grep -q 'is not in config.sh' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the not-in-LAB_EXTRAS refusal is missing"

start_test "the per-extra loop iterates TARGET_EXTRAS, not the raw LAB_EXTRAS every time"
grep -qE '^for extra in \$TARGET_EXTRAS; do' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the main loop no longer scopes to TARGET_EXTRAS"

start_test "an empty LAB_EXTRAS exits cleanly rather than erroring under set -u"
grep -q 'LAB_EXTRAS is empty in config.sh' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the empty-LAB_EXTRAS early exit is missing"

print_test_section "09-lab-extras-apply.sh: per-extra site data (nas)"

start_test "a per-extra site-data file is only passed if it actually exists"
grep -q 'if \[\[ -f "\$site_data_file" \]\]' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the optional site-data pass-through guard is missing"

start_test "the site-data path is scoped to THIS extra's own name, not a shared/global file"
grep -qE 'site_data_file="\$REPO_ROOT/\.uis\.secrets/platforms/proxmox/lab-extras/\$\{extra\}-site-data\.yml"' "$APPLY_SCRIPT" \
    && pass_test || fail_test "the per-extra site-data path convention is missing or changed shape"

print_test_section "generate-ansible-config.sh: nas's multi-mount support"

start_test "write_guest_decl accepts an extra_mounts parameter beyond mp0"
grep -q 'extra_mounts="\${15:-}"' "$GEN_SCRIPT" && pass_test \
    || fail_test "write_guest_decl's extra_mounts parameter is missing"

start_test "nas's own case arm actually uses extra_mounts (more than one share mount)"
grep -q '_nas_rest_mounts' "$GEN_SCRIPT" && pass_test \
    || fail_test "nas's multi-mount parsing is missing"

print_test_section "09-lab-extras-apply.sh: VM-kind lab extras (forgejo-runner, urb-agents#1982)"

start_test "a VM-kind declaration calls vm-ensure.yml, not guest-ensure.yml"
grep -q 'playbooks/vm-ensure.yml' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the vm-ensure.yml branch is missing"

start_test "a VM-kind declaration skips replication and HA registration"
grep -q 'stateless compute, no replication or HA registration' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the VM-kind replicate/HA-skip branch is missing"

start_test "a VM-kind declaration connects as VM_CIUSER, not root"
grep -q 'service_ssh_user="\$VM_CIUSER"' "$APPLY_SCRIPT" && pass_test \
    || fail_test "the VM-kind ssh-user branch is missing"

print_test_section "generate-ansible-config.sh: VM-kind lab extras (forgejo-runner, urb-agents#1982)"

start_test "write_vm_extra_decl exists, as the VM counterpart to write_guest_decl"
grep -q '^write_vm_extra_decl()' "$GEN_SCRIPT" && pass_test \
    || fail_test "write_vm_extra_decl is missing"

start_test "write_guest_decl/write_vm_extra_decl both emit service.kind, for 09's dispatch"
_kind_lxc=$(grep -c '^  kind: lxc$' "$GEN_SCRIPT")
_kind_vm=$(grep -c '^  kind: vm$' "$GEN_SCRIPT")
[[ "$_kind_lxc" -ge 1 && "$_kind_vm" -ge 1 ]] && pass_test \
    || fail_test "expected both 'kind: lxc' and 'kind: vm' to appear in generated declarations"

start_test "forgejo-runner's own case arm refuses generation if forgejo is not in CORE_SERVICES"
grep -q "is in LAB_EXTRAS but 'forgejo' is not in CORE_SERVICES" "$GEN_SCRIPT" && pass_test \
    || fail_test "the forgejo-runner dependency check is missing from generate-ansible-config.sh"

start_test "forgejo-runner's instance URL is resolved from CORE_SERVICE_FORGEJO_IP, never hardcoded"
grep -q 'forgejo_runner_instance_url: .*CORE_SERVICE_FORGEJO_IP' "$GEN_SCRIPT" && pass_test \
    || fail_test "forgejo_runner_instance_url is not resolved from the forgejo core-service's own IP"

start_test "forgejo-runner's firewall deny-list excludes forgejo itself"
grep -qE '_ename" == "forgejo" \|\| "\$_ename" == "forgejo-runner"' "$GEN_SCRIPT" && pass_test \
    || fail_test "the deny-list exclusion for forgejo/forgejo-runner is missing"

print_summary
