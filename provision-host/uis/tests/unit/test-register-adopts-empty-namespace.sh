#!/bin/bash
# test-register-adopts-empty-namespace.sh - `uis argocd register` name-collision guard
#
# 🔴 These run the real cmd_argocd_register against a stubbed kubectl rather
# than grepping the source. The bug this covers was a guard that was correct
# in isolation and wrong in sequence: it refused on namespace *existence*, and
# `uis configure --namespace x` creates namespace x, so the documented
# two-step (make the database, then deploy) refused itself at step 2.
#
# A test that asserted "a namespace check exists" would have passed against
# the broken version. These assert which way it decides.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_CLI="/mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh"
else
    UIS_CLI="$(cd "$SCRIPT_DIR/../../manage" && pwd)/uis-cli.sh"
fi

print_test_section "argocd register: adopt an empty namespace, refuse an occupied one"

TMP="$(create_test_dir)"
trap 'cleanup_test_dir "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stub kubectl. EXISTING_NS / EXISTING_APPS / NS_WORKLOADS drive the answers.
cat > "$TMP/bin/kubectl" <<'STUB'
#!/bin/bash
args=("$@")
if [[ "${args[0]}" == "get" && "${args[1]}" == "namespace" ]]; then
    for n in $EXISTING_NS; do [[ "$n" == "${args[2]}" ]] && exit 0; done
    exit 1
fi
if [[ "${args[0]}" == "get" && "${args[1]}" == "application" ]]; then
    for a in $EXISTING_APPS; do [[ "$a" == "${args[2]}" ]] && exit 0; done
    exit 1
fi
if [[ "${args[0]}" == "get" && "${args[1]}" == deployments,* ]]; then
    # NS_WORKLOADS is a space-separated list of "kind/name"
    for w in $NS_WORKLOADS; do echo "$w   1/1   1   1   5d"; done
    exit 0
fi
if [[ "${args[0]}" == "get" && "${args[1]}" == "secret" ]]; then exit 1; fi
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

# Harness: source only the function under test, with the CLI's dependencies stubbed.
sed -n '/^_argocd_app_exists() {/,/^}/p'            "$UIS_CLI" >  "$TMP/fn.sh"
sed -n '/^_argocd_namespace_workloads() {/,/^}/p'   "$UIS_CLI" >> "$TMP/fn.sh"
sed -n '/^cmd_argocd_register() {/,/^}/p'           "$UIS_CLI" >> "$TMP/fn.sh"

cat > "$TMP/run.sh" <<'HARNESS'
export PATH="$TMP/bin:$PATH"
log_error()     { echo "ERROR: $*"; }
print_section() { echo "SECTION: $*"; }
EXIT_GENERAL_ERROR=1
ANSIBLE_DIR="/nonexistent"
ansible-playbook() { echo "REGISTERED: $*"; }
source "$TMP/fn.sh"
cmd_argocd_register "$@"
HARNESS

# Run one scenario. Sets OUT and RC.
#
# ⚠️ NOT `out=$(_register ...)`: that runs the function in a subshell, so an RC
# assigned inside it never reaches the caller — and `[[ "" -eq 0 ]]` is TRUE in
# bash, so every "expected success" assertion would have passed without running
# anything. The first draft of this file did exactly that.
_register() {
    OUT="$(TMP="$TMP" EXISTING_NS="$1" EXISTING_APPS="$2" NS_WORKLOADS="$3" \
        bash "$TMP/run.sh" "${4:-console}" "${5:-https://github.com/helpers-no/console}" 2>&1)"
    RC=$?
}

# ============================================================
# The case the fix exists for
# ============================================================

start_test "A namespace left by 'configure' is adopted, not refused"
_register "console" "" ""; out="$OUT"
if [[ $RC -eq 0 ]] && echo "$out" | grep -q "REGISTERED:"; then
    pass_test
else
    fail_test "Expected registration to proceed (rc=0); rc=$RC, output: $out"
fi

start_test "Adopting says so, naming configure as the reason the namespace is there"
_register "console" "" ""; out="$OUT"
if echo "$out" | grep -q "adopting it" && echo "$out" | grep -q "uis configure --namespace console"; then
    pass_test
else
    fail_test "Adoption was silent or unexplained: $out"
fi

start_test "The old message is gone (it named existence, not occupancy)"
_register "console" "" ""; out="$OUT"
if echo "$out" | grep -q "already in use as a Kubernetes namespace"; then
    fail_test "Still refusing on mere existence: $out"
else
    pass_test
fi

# ============================================================
# What must still be refused
# ============================================================

start_test "A namespace holding workloads is refused"
_register "console" "" "deployment.apps/console-api"; out="$OUT"
if [[ $RC -ne 0 ]] && ! echo "$out" | grep -q "REGISTERED:"; then
    pass_test
else
    fail_test "Registered over live workloads; rc=$RC, output: $out"
fi

start_test "The refusal names the workloads it found"
_register "console" "" "deployment.apps/console-api statefulset.apps/console-db"; out="$OUT"
if echo "$out" | grep -q "console-api" && echo "$out" | grep -q "console-db"; then
    pass_test
else
    fail_test "Refusal did not list the occupants: $out"
fi

start_test "The refusal says why it matters (prune/selfHeal), not just that it refused"
_register "console" "" "deployment.apps/console-api"; out="$OUT"
if echo "$out" | grep -qi "prune"; then
    pass_test
else
    fail_test "Refusal gave no reason: $out"
fi

start_test "An existing ArgoCD Application is refused even with no namespace"
# 🔴 The pre-fix guard did not check Applications at all, so this registered.
_register "" "console" ""; out="$OUT"
if [[ $RC -ne 0 ]] && ! echo "$out" | grep -q "REGISTERED:"; then
    pass_test
else
    fail_test "Re-registered over an existing Application; rc=$RC, output: $out"
fi

start_test "That refusal points at 'uis argocd remove'"
_register "" "console" ""; out="$OUT"
if echo "$out" | grep -q "uis argocd remove console"; then
    pass_test
else
    fail_test "Refusal gave no way forward: $out"
fi

# ============================================================
# Unchanged behaviour
# ============================================================

start_test "A free name still registers"
_register "" "" ""; out="$OUT"
if [[ $RC -eq 0 ]] && echo "$out" | grep -q "REGISTERED:"; then
    pass_test
else
    fail_test "A clean registration broke; rc=$RC, output: $out"
fi

start_test "Argument validation still rejects a non-DNS name before touching the cluster"
_register "" "" "" "Not_A_DNS_Name" "https://github.com/x/y"; out="$OUT"
if [[ $RC -ne 0 ]] && ! echo "$out" | grep -q "REGISTERED:"; then
    pass_test
else
    fail_test "Invalid name accepted: $out"
fi

start_test "Argument validation still rejects a non-HTTPS repo URL"
_register "" "" "" "console" "git@github.com:x/y.git"; out="$OUT"
if [[ $RC -ne 0 ]] && ! echo "$out" | grep -q "REGISTERED:"; then
    pass_test
else
    fail_test "Non-HTTPS URL accepted: $out"
fi

print_summary
