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

_pod_artefact_hits() {   # $1 = service id
    grep -rn -- "$1-0" "${CODE_DIRS[@]}" --include='*.sh' --include='*.yml' 2>/dev/null \
        | awk -v id="$1" '{ line=$0; sub(/^[^:]+:[0-9]+:/,"",line); sub(/#.*$/,"",line);
                            if (line ~ id "-0") print $0 }' || true
}

_workload_kind_hits() {  # $1 = service id
    grep -rnE -- "(statefulset|sts)/$1([^A-Za-z0-9_-]|$)" "${CODE_DIRS[@]}" \
        --include='*.sh' --include='*.yml' 2>/dev/null \
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
    return $ok
}

if ! _self_check; then
    note "The matchers are broken; this test's verdict cannot be trusted."
    fails=$((fails+1))
fi

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
    hits="$(_pod_artefact_hits "$id")"
    if [[ -n "$hits" ]]; then
        echo "      FAIL: '$id-0' is a StatefulSet pod name; the proxy is a Deployment"
        echo "$hits" | sed 's/^/          /'
        note "Discover it instead: -l app.kubernetes.io/name=$id"
        fails=$((fails+1))
    else
        echo "      PASS: no '$id-0' pod name in code"
    fi

    # 3. nothing may assume the workload kind
    hits="$(_workload_kind_hits "$id")"
    if [[ -n "$hits" ]]; then
        echo "      FAIL: workload kind assumed for '$id'; the proxy is a Deployment"
        echo "$hits" | sed 's/^/          /'
        note "Wait on the Service or on pods by label, not on statefulset/$id."
        fails=$((fails+1))
    else
        echo "      PASS: no workload-kind assumption for '$id'"
    fi
done

if [[ $fails -eq 0 ]]; then
    echo "PASS: every proxy-eligible service is addressed only by guaranteed identity"
fi
exit $fails
