#!/bin/bash
# test-remove-refuses-unmanaged.sh - the four defects imac found in urb-agents#1732
#
# 🔴 The worst of them was a loop between two commands:
#   `argocd register` refused to take over a namespace holding workloads, and
#   told the operator to run `uis argocd remove <name>` — which deleted the
#   namespace and those workloads, because it acted on the name alone.
# So the refusal's remedy destroyed exactly what the refusal protected.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    ROOT="/mnt/urbalurbadisk"
else
    ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
CLI="$ROOT/provision-host/uis/manage/uis-cli.sh"
RM_PB="$ROOT/ansible/playbooks/argocd-remove-app.yml"
VERIFY_PB="$ROOT/ansible/playbooks/070-verify-authentik.yml"
UNDEPLOY_PB="$ROOT/ansible/playbooks/070-remove-authentik.yml"

print_test_section "urb-agents#1732: remove, the register remedy, the remedy text, the provider grep"

# ── 1. the loop: register's refusal must not point at a destructive command ──

start_test "register's occupied-namespace refusal no longer prescribes 'uis argocd remove'"
# The block between the occupants check and its exit.
block="$(awk '/already contains workloads:/,/exit "\$EXIT_GENERAL_ERROR"/' "$CLI")"
if echo "$block" | grep -q 'echo "  uis argocd remove'; then
    fail_test "The refusal still prints 'uis argocd remove' as the remedy"
else
    pass_test
fi

start_test "register's refusal warns against it explicitly"
if echo "$block" | grep -q "Do NOT reach for 'uis argocd remove"; then
    pass_test
else
    fail_test "No warning about the destructive command: $block"
fi

# ── 2. remove refuses a namespace it never managed ──

start_test "remove refuses when no Application of that name exists"
if grep -q "5a. Refuse to delete a namespace this never managed" "$RM_PB"; then
    pass_test
else
    fail_test "No refusal task in $RM_PB"
fi

start_test "the refusal is gated on all three conditions, not just one"
guard="$(awk '/5a. Refuse to delete a namespace this never managed/,/^    - name: "5b/' "$RM_PB")"
c=0
echo "$guard" | grep -q "argocd_app.resources | length == 0"     && c=$((c+1))
echo "$guard" | grep -q "namespace_info.resources | length > 0"  && c=$((c+1))
echo "$guard" | grep -q "not (force | default(false) | bool)"    && c=$((c+1))
if [[ $c -eq 3 ]]; then pass_test; else fail_test "Only $c/3 conditions present: $guard"; fi

start_test "the refusal is a fail, not a debug message"
if echo "$guard" | grep -q "ansible.builtin.fail"; then
    pass_test
else
    fail_test "5a does not actually stop the play: $guard"
fi

start_test "--force is offered as the way through, and warns before destroying"
if echo "$guard" | grep -q -- "--force" && grep -q "5f. Forcing the removal of a namespace ArgoCD left behind" "$RM_PB"; then
    pass_test
else
    fail_test "No --force path or no warning on it"
fi

start_test "the CLI accepts --force and passes it to the playbook"
if grep -q -- '--force) force="true"' "$CLI" && grep -q -- '-e "force=\$force"' "$CLI"; then
    pass_test
else
    fail_test "--force is not parsed or not forwarded"
fi

start_test "remove's usage mentions --force"
if grep -q 'Usage: uis argocd remove <name> \[--force\]' "$CLI"; then
    pass_test
else
    fail_test "Usage line does not mention --force"
fi

# ── 3. the printed remedy must survive being pasted ──

start_test "the undeploy remedy has no line-continuation backslash"
# `debug` JSON-escapes its msg, so a lone \ is rendered as \\ and the shell
# sees a literal backslash instead of a continuation. imac pasted it verbatim
# and got 'ERROR! the playbook: \ could not be found'.
remedy="$(sed -n '/^SCRIPT_UNDEPLOY_NOTE="/,/"$/p' "$ROOT/provision-host/uis/services/identity/service-authentik.sh")"
if echo "$remedy" | grep -qF '\\'; then
    fail_test "Remedy still contains a continuation backslash: $remedy"
else
    pass_test
fi

start_test "the remedy is a single runnable ansible-playbook line carrying confirm=yes"
if echo "$remedy" | grep -qF "ansible-playbook playbooks/utility/u09-authentik-create-postgres.yml -e operation=delete -e confirm=yes"; then
    pass_test
else
    fail_test "No single-line command found: $remedy"
fi

start_test "the remedy says how to get into the container"
if echo "$remedy" | grep -q "./uis shell"; then
    pass_test
else
    fail_test "Remedy still says 'INSIDE the container' without saying how: $remedy"
fi

# ── 4. the provider grep that matched nothing, and the no_log that hid it ──

start_test "the verify playbook no longer greps for the non-existent 'whoami-provider'"
# ⚠️ Comments are stripped first: the note explaining this fix quotes the old
# grep, and the first version of this assertion matched that and failed a
# correct file. Assertions must read the code, not the prose beside it.
code_only="$(grep -v '^[[:space:]]*#' "$VERIFY_PB")"
if echo "$code_only" | grep -q "name: whoami-provider'"; then
    fail_test "Still grepping for a provider name the blueprint never creates"
else
    pass_test
fi

start_test "task 16 reuses the provider found by pk instead of by name"
t16="$(awk '/- name: 16. Extract provider details/,/- name: 17/' "$VERIFY_PB")"
if echo "$t16" | grep -q "provider_details_raw: \"{{ provider_config }}\""; then
    pass_test
else
    fail_test "Task 16 does not reuse provider_config: $t16"
fi

start_test "every no_log k8s_exec in the verify playbook reports instead of a censored fatal"
# no_log: true + a hard failure = 'the output has been hidden' and no cause.
missing=""
for reg in app_config provider_config outpost_details; do
    blk="$(grep -A3 "register: $reg\$" "$VERIFY_PB")"
    echo "$blk" | grep -q "failed_when: false" || missing="$missing $reg"
done
if [[ -z "$missing" ]]; then pass_test; else fail_test "No failed_when on:$missing"; fi

start_test "the asserts default their stdout so a failed exec reads as the assert, not an undefined variable"
n=$(grep -c "stdout | default('')" "$VERIFY_PB")
if [[ "$n" -ge 6 ]]; then pass_test; else fail_test "Only $n defaulted stdout references, expected >= 6"; fi

# ── 5. the usage example that 404s ──

start_test "the argocd register example points at a repository that exists"
if grep -q "helpers-no/urb-dev-typescript-hello-world" "$CLI"; then
    fail_test "Usage still names helpers-no/urb-dev-typescript-hello-world, which 404s"
else
    pass_test
fi

start_test "it names the repository's real owner"
if grep -q "terchris/urb-dev-typescript-hello-world" "$CLI"; then
    pass_test
else
    fail_test "No corrected example URL found"
fi


# ============================================================
# urb-agents#1736: --force deleted anything, and the remedy still
# could not be pasted
# ============================================================

print_test_section "urb-agents#1736: --force, the pasteable remedy, and task 18"

SVC_AUTHENTIK="$ROOT/provision-host/uis/services/identity/service-authentik.sh"
SVC_DEPLOY="$ROOT/provision-host/uis/lib/service-deployment.sh"

start_test "--force refuses when the namespace holds resources this app does not own"
if grep -q "5e. Refuse to force-delete resources this application does not own" "$RM_PB"; then
    pass_test
else
    fail_test "No untracked-resource refusal in $RM_PB"
fi

start_test "it finds them with the selector that also catches resources with no label at all"
# `key!=value` matches resources lacking the key — the set that must survive.
if grep -qF 'argocd.argoproj.io/instance!={{ app_name }}' "$RM_PB"; then
    pass_test
else
    fail_test "Not using the argocd.argoproj.io/instance!=<app> selector"
fi

start_test "it looks beyond pods — a Secret and a PVC were destroyed on a pod count"
n=$(grep -cF "all,secret,configmap,persistentvolumeclaim" "$RM_PB")
if [[ "$n" -eq 2 ]]; then
    pass_test
else
    fail_test "Expected the wide enumeration in both 5c and task 12; found $n"
fi

start_test "Kubernetes' own per-namespace ConfigMap is not counted as someone's data"
if grep -qF "kube-root-ca.crt" "$RM_PB"; then
    pass_test
else
    fail_test "kube-root-ca.crt is not excluded, so every namespace looks occupied"
fi

start_test "the refusal names the resources rather than counting them"
blk="$(awk '/5e. Refuse to force-delete/,/^    - name: "5f/' "$RM_PB")"
if echo "$blk" | grep -qF "untracked | join"; then
    pass_test
else
    fail_test "Refusal does not list the resources: $blk"
fi

start_test "🔴 the refusal is a fail — a warning printed and acted on in the same run is a log line"
if echo "$blk" | grep -q "ansible.builtin.fail"; then
    pass_test
else
    fail_test "5e does not stop the play"
fi

start_test "removing a name with no namespace says nothing was removed"
if grep -q "5g. Nothing to remove" "$RM_PB"; then
    pass_test
else
    fail_test "No 'nothing to remove' path — a missing name still claims success"
fi

start_test "the final summary no longer claims removals unconditionally"
fin="$(awk '/17. Final status display/,0' "$RM_PB")"
n=0
echo "$fin" | grep -qF "NOTHING TO REMOVE" && n=$((n+1))
echo "$fin" | grep -qF "No ArgoCD Application of that name existed" && n=$((n+1))
echo "$fin" | grep -qF "No namespace of that name existed" && n=$((n+1))
if [[ $n -eq 3 ]]; then pass_test; else fail_test "only $n of 3 conditional lines in the summary"; fi

# ── the remedy, which failed to paste twice ──

start_test "the undeploy playbook no longer prints anything meant to be pasted"
# 🔴 debug wraps every line: a list item arrives as a JSON string with quotes
# and a trailing comma, so bash said "./uis shell,: No such file or directory".
if grep -qF "ansible-playbook playbooks/utility/u09-authentik-create-postgres.yml" "$UNDEPLOY_PB"; then
    fail_test "The playbook still prints the command through debug"
else
    pass_test
fi

start_test "the command now comes from the service definition, where printf can print it"
if grep -q "^SCRIPT_UNDEPLOY_NOTE=" "$SVC_AUTHENTIK"; then
    pass_test
else
    fail_test "No SCRIPT_UNDEPLOY_NOTE on the authentik service"
fi

start_test "uis prints that note with printf, not through a callback"
if grep -qF "_print_undeploy_note" "$SVC_DEPLOY" && grep -qF "printf '\\n%s\\n'" "$SVC_DEPLOY"; then
    pass_test
else
    fail_test "The note is not printed, or not with printf"
fi

start_test "it is printed after a successful removal"
if awk '/log_success "\$SCRIPT_NAME removed"/{getline; if ($0 ~ /_print_undeploy_note/) found=1} END{exit !found}' "$SVC_DEPLOY"; then
    pass_test
else
    fail_test "_print_undeploy_note is not called after the removal succeeds"
fi

start_test "🔴 the note itself is pasteable: bash can parse every command line in it"
note="$(sed -n '/^SCRIPT_UNDEPLOY_NOTE="/,/"$/p' "$SVC_AUTHENTIK")"
bad=0
echo "$note" | grep -qF '\' && bad=1            # no continuation backslashes
echo "$note" | grep -qE '^\s*".*",\s*$' && bad=1  # no JSON list-item shape
# and the two real command lines must parse
( source "$SVC_AUTHENTIK" 2>/dev/null
  printf '%s\n' "$SCRIPT_UNDEPLOY_NOTE" \
    | grep -E '^\s+(\./uis shell|cd /mnt)' \
    | bash -n - ) 2>/dev/null || bad=1
if [[ $bad -eq 0 ]]; then pass_test; else fail_test "The note is not pasteable: $note"; fi

# ── task 18 ──

start_test "task 18 defaults before 'first', so a missing field does not crash the play"
# regex_search returns None on no match and `first` raises on None BEFORE
# `default` is reached: 'NoneType' object is not iterable.
t18="$(awk '/- name: 18. Extract key provider information/,/- name: 19/' "$VERIFY_PB")"
n=$(echo "$t18" | grep -c "default(\[''\], true) | first")
if [[ "$n" -ge 3 ]]; then pass_test; else fail_test "only $n expressions default before first"; fi

start_test "no expression in task 18 still pipes regex_search straight into first"
if echo "$t18" | grep -qE "regex_search\([^)]*\)[^|]*\| first"; then
    fail_test "An expression still calls first on a possibly-None value: $t18"
else
    pass_test
fi

start_test "OAuth2-only fields are not demanded of a proxy provider"
n=$(echo "$t18" | grep -cF "if has_oauth2_provider else 'Not applicable (proxy provider)'")
if [[ "$n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $n of 2 OAuth2-only fields are guarded (url:, access_token_validity:)"
fi

start_test "the hardcoded provider name is gone from the display too"
t19="$(awk '/- name: 19. Display provider information/,/- name: 20/' "$VERIFY_PB")"
if echo "$t19" | grep -qF "whoami-provider"; then
    fail_test "task 19 still prints 'Provider Name: whoami-provider', which does not exist"
else
    pass_test
fi

print_summary
