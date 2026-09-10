#!/bin/bash
# test-kubectl-wait-retries.sh — a `kubectl wait` on pods must be able to retry.
#
# 🔴 `kubectl wait` does NOT wait for a resource to be created. With nothing
# matching the selector it errors immediately, and `--timeout` bounds how long
# to wait for a CONDITION ON EXISTING PODS — not for pods to exist.
#
# 1.6.37 replaced a retrying phase poll with a bare `kubectl wait` and shipped
# that to `:latest`. On a clean cluster it failed in 176 ms, because Helm had
# just created the StatefulSet and the pod object did not exist yet — breaking
# an unknown fraction of FIRST INSTALLS, intermittently, silently (imac,
# urb-agents#525).
#
# ⚠️ The distinction this asserts, because it is not "always add retries":
#   - `kubectl apply` creates an OBJECT synchronously, so waiting on that named
#     object (`deployment/whoami`) cannot miss it
#   - PODS are created asynchronously by a controller, so any wait on `pod`
#     can run before they exist and must tolerate that
#
# So: a wait on `pod` needs `until:`/`retries:`, or explicit tolerance
# (`|| true`, `ignore_errors`, `failed_when`). A wait on a named non-pod
# resource does not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
# static/ -> tests/ -> uis/ -> provision-host/ -> repo root (or /mnt/urbalurbadisk)
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOKS="$REPO_ROOT/ansible/playbooks"
[[ -d "$PLAYBOOKS" ]] || PLAYBOOKS="/mnt/urbalurbadisk/ansible/playbooks"

print_test_section "kubectl wait on pods must tolerate not-yet-created"

if [[ ! -d "$PLAYBOOKS" ]]; then
    skip_test "playbooks not present in this layout"
    print_summary
    return 0 2>/dev/null || exit 0
fi

bare=$(python3 - "$PLAYBOOKS" <<'PY'
import re, glob, os, sys
out = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    lines = open(f).read().split("\n")
    for i, l in enumerate(lines):
        if "kubectl wait" not in l or l.strip().startswith("#"):
            continue
        if "--for=delete" in l:          # absence is the point
            continue
        if not re.search(r"\bpod\b", l): # named non-pod objects exist after apply
            continue
        fwd = "\n".join(lines[i:i+14])
        tolerant = ("until:" in fwd or "retries:" in fwd
                    or "ignore_errors" in fwd or "failed_when" in fwd
                    or "|| true" in l or "|| echo" in l or "2>/dev/null" in l)
        if not tolerant:
            out.append(f"{os.path.basename(f)}:{i+1}")
print(" ".join(out))
PY
)

start_test "🔴 no bare \`kubectl wait ... pod\` without a retry or explicit tolerance"
assert_empty "$bare" "these fail in milliseconds when the pod does not exist yet:$bare"

start_test "the postgresql install wait retries (the one that broke :latest)"
grep -A 12 '8. Wait for PostgreSQL pod to be READY' "$PLAYBOOKS/040-database-postgresql.yml" 2>/dev/null \
    | grep -q 'until: pod_ready.rc == 0' && pass_test \
    || fail_test "040 task 8 has no until: — this is the 1.6.39 defect"

print_summary
