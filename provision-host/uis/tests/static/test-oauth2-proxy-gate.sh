#!/bin/bash
# test-oauth2-proxy-gate.sh — the oauth2-proxy gate's non-negotiables.
#
# WHAT THIS CAN AND CANNOT CHECK. There is no cluster and no Jinja2 renderer on
# a dev host, so nothing here proves a template renders or a login works. These
# assertions pin the properties that would silently regress in review and that a
# reader cannot verify by eye:
#
#   - the image stays pinned (an unpinned tag re-pulls on restart and drifts)
#   - no wildcard email domain ever appears
#   - the gate keeps no dependencies (that is the reason to choose it)
#   - no Traefik object reference crosses a namespace (allowCrossNamespace is
#     false here, so a crossing reference silently drops the route)
#   - the secret exists in the namespace that reads it
#   - the deploy refuses a placeholder credential instead of gating nothing
#
# Rendering, redirects and sign-in are Phase 6 of PLAN-service-oauth2-proxy and
# belong to the tester.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/manifests" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi

DEPLOY="$REPO/manifests/072-oauth2-proxy-deployment.yaml.j2"
MW="$REPO/manifests/072-oauth2-proxy-middleware.yaml.j2"
SETUP="$REPO/ansible/playbooks/072-setup-oauth2-proxy.yml"
SVC="$REPO/provision-host/uis/services/identity/service-oauth2-proxy.sh"
MASTER="$REPO/provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template"

print_test_section "oauth2-proxy gate Tests"

# Strip comment lines before asserting. These files EXPLAIN the patterns they
# forbid — "--email-domain=* converts anonymous into anyone" is in the header of
# the manifest that must never contain it — so an assertion that cannot tell
# code from commentary fails on its own documentation. Hit three times on
# 2026-09-18 before being factored out.
_code_only() { grep -vE '^[[:space:]]*#' "$@"; }

# --- the files exist at all ---
for f in "$DEPLOY" "$MW" "$SETUP" "$SVC"; do
    start_test "$(basename "$f") exists"
    assert_file_exists "$f" && pass_test
done

# --- image pinning ---
start_test "the gate image is pinned, not :latest"
if grep -qE 'image: quay\.io/oauth2-proxy/oauth2-proxy:v[0-9]+\.[0-9]+\.[0-9]+' "$DEPLOY"; then
    pass_test
else
    fail_test "image is not pinned to an explicit version: $(grep -m1 'image:' "$DEPLOY")"
fi

start_test "the gate image is not :latest"
if grep -qE 'oauth2-proxy:latest|oauth2-proxy:.*-latest' "$DEPLOY"; then
    fail_test ":latest re-pulls on every restart and drifts between clusters (conformance C9)"
else
    pass_test
fi

# --- 🔴 the wildcard that would make the whole thing theatre ---
start_test "no wildcard email domain anywhere in the gate"
if _code_only "$DEPLOY" "$MW" "$SETUP" 2>/dev/null | grep -qE -- "--email-domain=\*|email-domain=['\"]?\*"; then
    fail_test "--email-domain=* converts 'anonymous' into 'anyone with an account'"
else
    pass_test
fi

start_test "the gate uses an explicit allowlist file"
if grep -q -- '--authenticated-emails-file=' "$DEPLOY"; then
    pass_test
else
    fail_test "no --authenticated-emails-file — what is restricting access?"
fi

# --- the reason this service was chosen over Authentik ---
start_test "the service declares no dependencies"
# shellcheck source=/dev/null
( unset SCRIPT_REQUIRES; source "$SVC" 2>/dev/null; [[ -z "${SCRIPT_REQUIRES:-}" ]] ) \
    && pass_test \
    || fail_test "SCRIPT_REQUIRES is set — a gate with a database is not why this service exists"

# --- 🔴 cross-namespace object references ---
# Traefik's allowCrossNamespace defaults to false and this repo does not set it.
# A forwardAuth *address* may cross (it is DNS); an IngressRoute referencing a
# Service or Middleware in another namespace may not. An earlier draft of the
# middleware template did exactly that and would have dropped the route.
start_test "no IngressRoute references a Service in another namespace"
if awk '/^apiVersion: traefik/{inroute=0} /kind: IngressRoute/{inroute=1; ns=""}
        inroute && /^  namespace:/{ns=$2}
        inroute && /^          namespace:/{ if ($2 != ns) { print "MISMATCH route-ns=" ns " svc-ns=" $2; } }' "$MW" | grep -q MISMATCH; then
    fail_test "$(awk '/kind: IngressRoute/{inroute=1; ns=""} inroute && /^  namespace:/{ns=$2} inroute && /^          namespace:/{ if ($2 != ns) print "route in " ns " -> service in " $2 }' "$MW" | head -1)"
else
    pass_test
fi

start_test "the forwardAuth address is a URL, not an object reference"
if grep -qE 'address: http://oauth2-proxy\.oauth2-proxy\.svc\.cluster\.local:4180/oauth2/auth' "$MW"; then
    pass_test
else
    fail_test "the middleware no longer points at the gate by cluster DNS"
fi

# --- the /oauth2/ path must be reachable without a session ---
start_test "an unauthenticated /oauth2/ route is generated"
if grep -q 'PathPrefix(`/oauth2/`)' "$MW"; then
    pass_test
else
    fail_test "without it the callback needs a session to obtain a session"
fi

start_test "the /oauth2/ route outranks the protected route"
if [[ "$(grep -c 'priority: 30' "$MW")" -ge 1 && "$(grep -c 'priority: 20' "$MW")" -ge 1 ]]; then
    pass_test
else
    fail_test "priorities missing — the protected rule may swallow /oauth2/"
fi

# --- host-specific matching, not the regex that published everything ---
start_test "the protected route matches named hosts, not HostRegexp(.+)"
if _code_only "$MW" | grep -qE 'HostRegexp\(`[^`]*\\\.\.\+`\)'; then
    fail_test "HostRegexp(name\\..+) matches every domain — that is how a wildcard tunnel publishes undeclared services"
else
    pass_test
fi

# --- the secret must exist where the pod reads it ---
start_test "urbalurba-secrets is seeded into the oauth2-proxy namespace"
if grep -q 'namespace: oauth2-proxy' "$MASTER"; then
    pass_test
else
    fail_test "a secretKeyRef is namespace-local; the gate pod would fail to start"
fi

# --- refuse rather than deploy a gate nobody can pass ---
start_test "the deploy refuses a placeholder credential"
if grep -q 'Refuse to deploy a gate that cannot authenticate anyone' "$SETUP"; then
    pass_test
else
    fail_test "no placeholder guard — 822-verify's 'DNS Token: configured' shape"
fi

start_test "the deploy does not treat a Running pod as a working gate"
if grep -q 'A Running pod is not a working login' "$SETUP"; then
    pass_test
else
    fail_test "the 1.6.118 lesson is not recorded where the claim is made"
fi

# --- no ansible-only filters, so the template stays renderable/testable ---
start_test "the templates use no ansible-only Jinja filters"
if grep -qE 'regex_replace|ansible\.builtin\.' "$DEPLOY" "$MW" 2>/dev/null; then
    fail_test "an ansible-only filter cannot be rendered outside the container"
else
    pass_test
fi

# --- balanced Jinja blocks (the cheapest real check available without a renderer) ---
for f in "$DEPLOY" "$MW"; do
    start_test "$(basename "$f") has balanced Jinja for/if blocks"
    fors=$(grep -oE '\{%-? *for ' "$f" | wc -l)
    endfors=$(grep -oE '\{%-? *endfor *-?%\}' "$f" | wc -l)
    ifs=$(grep -oE '\{%-? *if ' "$f" | wc -l)
    endifs=$(grep -oE '\{%-? *endif *-?%\}' "$f" | wc -l)
    if [[ "$fors" -eq "$endfors" && "$ifs" -eq "$endifs" ]]; then
        pass_test
    else
        fail_test "for=$fors endfor=$endfors if=$ifs endif=$endifs"
    fi
done

print_summary
