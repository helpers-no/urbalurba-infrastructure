#!/bin/bash
# test-external-proxy-contract.sh
#
# The external-services shim exists so that "runs in the cluster" and "runs
# outside it, behind a proxy" are indistinguishable to everything downstream.
# It guarantees a specific, small identity, and NOTHING else:
#
#     Service name              == <service-id>
#     app.kubernetes.io/name    == <service-id>
#
# It deliberately does NOT guarantee:
#
#     the POD name       - the proxy is a Deployment (postgresql-<hash>-<hash>),
#                          the real thing is often a StatefulSet (postgresql-0)
#     the WORKLOAD KIND  - so `rollout status statefulset/<id>` cannot work
#
# Every topology defect this repo has hit was code addressing a service by an
# identity from that second list. So this test asks ops's question directly:
#
#     does anything address a proxy-eligible service by an identity the shim
#     does not guarantee?
#
# ⚠️ WHY THIS IS GENERIC AND test-postgres-connection-shape.sh IS NOT.
# That test guards postgres specifically, including the `psql` host shape which
# is postgres-only and still needed. But the shim mechanism is generic: ANY
# service with a <NNN>-<id>-external-proxy.yml.j2 template can be declared
# external. A per-service guard means the second proxy-eligible service ships
# unguarded - which is the same "convention everybody must remember" failure the
# verify-target helper was built to end.
#
# So this keys off the TEMPLATES ON DISK, not a list of service names. Add a
# proxy template and this test starts guarding that service on the next run,
# with no edit here. Today that is postgresql and minio.
#
# Known live example of why that matters: `statefulset/mongodb` and
# `statefulset/open-webui` waits exist in the playbooks today. Neither service
# has a proxy template, so neither is a defect - and both become one the moment
# somebody adds one. This test fails on that day instead of in production.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /mnt/urbalurbadisk ]]; then ROOT=/mnt/urbalurbadisk
else ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"; fi

TEMPLATE_DIR="$ROOT/ansible/playbooks/templates"
CODE_DIRS=("$ROOT/ansible/playbooks" "$ROOT/provision-host/uis/lib" "$ROOT/provision-host/uis/manage")

fails=0
note() { echo "  $*"; }

# Strip the "file:line:" prefix, then drop anything after a '#'. A documented
# kubectl recipe in operator help text is prose, not an invocation.
_code_only() {
    sed -E 's/^([^:]+:[0-9]+:)//' | sed -E 's/#.*$//'
}

# Is the match CODE, or a quoted string being displayed to a human?
#
# Operator help text lives in `debug: msg:` lists as quoted display strings:
#
#     - "* Restart OpenWebUI: kubectl rollout restart statefulset/open-webui"
#
# That is not an invocation. But it is NOT harmless either, which is why this
# does not simply skip it: on the day that service is declared external there is
# no StatefulSet to restart, so the help text becomes wrong advice. It still has
# to change - it just needs a different remedy than the code case.
#
# Deciding structurally, the same way test-postgres-connection-shape.sh does:
# strip quoted string literals, then ask whether the pattern still stands. Code
# survives that; a display string does not.
_match_is_code() {  # $1 = raw "file:line:code" hit, $2 = extended regex
    local code stripped
    code="$(printf '%s' "$1" | sed -E 's/^[^:]+:[0-9]+://')"
    stripped="$(printf '%s' "$code" | awk '{
        out=""; inq=0; q=""
        for (i=1; i<=length($0); i++) {
            c = substr($0,i,1)
            if (inq) { if (c==q) inq=0; continue }
            if (c=="\"" || c=="'"'"'") { inq=1; q=c; continue }
            if (c=="#") break
            out = out c
        }
        print out
    }')"
    printf '%s' "$stripped" | grep -qE "$2"
}

_pod_artefact_hits() {   # $1 = service id
    # No `--` here. It terminates option parsing, which turns both --include
    # arguments into file operands: the filters stop filtering, grep recurses over
    # every file, and the "No such file" errors for the two literal --include paths
    # are swallowed by 2>/dev/null. The tester found it when its own .imacbak
    # scratch file appeared in this test's output. test-postgres-connection-shape.sh
    # does the same search without `--`, which is why its filters have always worked.
    grep -rn "$1-0" "${CODE_DIRS[@]}" \
        --include='*.sh' --include='*.yml' --include='*.yaml' 2>/dev/null \
        | awk -v id="$1" '{ line=$0; sub(/^[^:]+:[0-9]+:/,"",line); sub(/#.*$/,"",line);
                            if (line ~ id "-0") print $0 }' || true
}

_workload_kind_hits() {  # $1 = service id
    # See the note in _pod_artefact_hits: no `--`, or the filters are inert.
    grep -rnE "(statefulset|sts)/$1([^A-Za-z0-9_-]|$)" "${CODE_DIRS[@]}" \
        --include='*.sh' --include='*.yml' --include='*.yaml' 2>/dev/null \
        | awk -v id="$1" '{ line=$0; sub(/^[^:]+:[0-9]+:/,"",line); sub(/#.*$/,"",line);
                            if (line ~ "(statefulset|sts)/" id) print $0 }' || true
}

# A gate that stops matching reports PASS forever. Both matchers must be shown
# capable of firing AND of ignoring prose, or this test's verdict means nothing.
# (Same reasoning as the self-check in test-postgres-connection-shape.sh, which
# exists because a prose blocklist there left main red for a day.)
_self_check() {
    local tmp ok=0
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/ansible/playbooks"
    printf 'a: kubectl exec widget-0 -- true\n' > "$tmp/ansible/playbooks/real.yml"
    printf 'b: # kubectl exec widget-0 -- true\n' > "$tmp/ansible/playbooks/prose.yml"
    printf 'c: kubectl rollout status statefulset/widget\n' >> "$tmp/ansible/playbooks/real.yml"

    local saved=("${CODE_DIRS[@]}")
    CODE_DIRS=("$tmp/ansible/playbooks")

    [[ -n "$(_pod_artefact_hits widget)" ]] || { echo "SELF-CHECK FAIL: pod-artefact matcher missed a real hit"; ok=1; }
    [[ -n "$(_workload_kind_hits widget)" ]] || { echo "SELF-CHECK FAIL: workload-kind matcher missed a real hit"; ok=1; }
    # prose.yml must contribute nothing: remove real.yml and expect silence
    rm -f "$tmp/ansible/playbooks/real.yml"
    [[ -z "$(_pod_artefact_hits widget)" ]] || { echo "SELF-CHECK FAIL: pod-artefact matcher flagged a comment"; ok=1; }

    CODE_DIRS=("${saved[@]}")

    # The classifier decides FAIL-as-code vs FAIL-as-stale-guidance. If it always
    # answered "code" the remedy would be wrong; if it always answered "prose"
    # every real defect would be filed as a documentation nit. Both directions
    # must be shown to work, or the split is decoration.
    local rx='(statefulset|sts)/open-webui'
    local real='x.yml:98:        kubectl rollout status statefulset/open-webui -n ai'
    local help='x.yml:346:        - "* Restart: kubectl rollout restart statefulset/open-webui -n ai"'
    _match_is_code "$real" "$rx" || { echo "SELF-CHECK FAIL: classifier called a real invocation prose"; ok=1; }
    _match_is_code "$help" "$rx" && { echo "SELF-CHECK FAIL: classifier called quoted help text code"; ok=1; }

    return $ok
}

if ! _self_check; then
    note "The matchers are broken; this test's verdict cannot be trusted."
    fails=$((fails+1))
fi

# Report one check, splitting code from operator help text.
#
# BOTH fail. A display string that names a StatefulSet is wrong advice the moment
# the service goes external, so silencing it would hide a real defect. What differs
# is the REMEDY: "wait on the Service instead" is sound for code and meaningless
# for a help string, and a contributor handed the wrong remedy learns to reword
# prose until the gate goes quiet - the worst habit to teach around a correctness
# check. So the message says which kind it is and what to actually do.
_report() {  # $1 id, $2 hits, $3 regex, $4 fail_msg, $5 code_remedy, $6 pass_msg
    local id="$1" hits="$2" rx="$3" fail_msg="$4" code_remedy="$5" pass_msg="$6"
    local code_hits="" text_hits="" line

    [[ -z "$hits" ]] && { echo "      PASS: $pass_msg"; return; }

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if _match_is_code "$line" "$rx"; then code_hits+="$line"$'\n'
        else                                  text_hits+="$line"$'\n'; fi
    done <<< "$hits"

    if [[ -n "$code_hits" ]]; then
        echo "      FAIL: $fail_msg"
        printf '%s' "$code_hits" | sed 's/^/          /'
        note "$code_remedy"
        fails=$((fails+1))
    fi

    if [[ -n "$text_hits" ]]; then
        echo "      FAIL: stale operator guidance for '$id' - quoted help text, not code"
        printf '%s' "$text_hits" | sed 's/^/          /'
        note "These are display strings telling a human what to type. They are not"
        note "invocations, so the code remedy does not apply - but once '$id' is"
        note "declared external the thing they tell the operator to do does not"
        note "exist. Update the guidance to match the proxy, or drop the line."
        note "Do NOT reword it just to quiet this test."
        fails=$((fails+1))
    fi

    [[ -z "$code_hits$text_hits" ]] && echo "      PASS: $pass_msg"
    return 0
}

shopt -s nullglob
templates=("$TEMPLATE_DIR"/*-external-proxy.yml.j2)
shopt -u nullglob

if [[ ${#templates[@]} -eq 0 ]]; then
    echo "FAIL: no *-external-proxy.yml.j2 templates found under $TEMPLATE_DIR"
    note "Either the shim was removed or this test is looking in the wrong place."
    note "An empty subject list must not read as PASS - that is a gate that cannot fail."
    exit $((fails+1))
fi

echo "Proxy-eligible services (from templates on disk): ${#templates[@]}"

for tpl in "${templates[@]}"; do
    base="$(basename "$tpl")"
    id="${base#*-}"; id="${id%-external-proxy.yml.j2}"
    echo "  --- $id ($base)"

    # 1. the template must publish the identity the shim promises
    if grep -qE "^[[:space:]]*name:[[:space:]]*$id[[:space:]]*$" "$tpl" \
       && grep -qE "app\.kubernetes\.io/name:[[:space:]]*$id([[:space:]]|,|\}|$)" "$tpl"; then
        echo "      PASS: publishes Service name and app.kubernetes.io/name = $id"
    else
        echo "      FAIL: template does not publish the shim identity for '$id'"
        note "Consumers address the service by name and by label. If the proxy"
        note "publishes anything else, it is not transparent."
        fails=$((fails+1))
    fi

    # 2. nothing may address it by StatefulSet pod name
    _report "$id" "$(_pod_artefact_hits "$id")" "$id-0" \
        "'$id-0' is a StatefulSet pod name; the proxy is a Deployment" \
        "Discover it instead: -l app.kubernetes.io/name=$id" \
        "no '$id-0' pod name"

    # 3. nothing may assume the workload kind
    _report "$id" "$(_workload_kind_hits "$id")" "(statefulset|sts)/$id" \
        "workload kind assumed for '$id'; the proxy is a Deployment" \
        "Wait on the Service or on pods by label, not on statefulset/$id." \
        "no workload-kind assumption"
done

if [[ $fails -eq 0 ]]; then
    echo "PASS: every proxy-eligible service is addressed only by guaranteed identity"
fi
exit $fails

# imac actions-v5 round: touch to trigger test-uis.yml paths. Comment only.
