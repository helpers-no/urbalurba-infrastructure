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

# ---------------------------------------------------------------------------
# 1.6.122: the declaration is operator config, not a structural template key.
# ---------------------------------------------------------------------------
DECL="$REPO/provision-host/uis/templates/uis.extend/protected-services.yaml.default"
MASTER_T="$REPO/provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template"
REMOVE="$REPO/ansible/playbooks/072-remove-oauth2-proxy.yml"

start_test "the operator-owned declaration default is shipped"
assert_file_exists "$DECL" && pass_test

start_test "the declaration is NOT a key in the structural template"
# It was, in 1.6.121. That template is re-synced from the image on every start
# as of 1.6.122, so a user edit there is destroyed — and before that fix it was
# never synced at all, which is how 1.6.121 shipped undeployable.
if _code_only "$MASTER_T" | grep -q 'OAUTH2_PROXY_CONFIG:'; then
    fail_test "OAUTH2_PROXY_CONFIG is back in a template that gets overwritten"
else
    pass_test
fi

start_test "both playbooks read the declaration from .uis.extend"
if grep -q 'declaration_file: "/mnt/urbalurbadisk/.uis.extend/protected-services.yaml"' "$SETUP" \
   && grep -q 'declaration_file: "/mnt/urbalurbadisk/.uis.extend/protected-services.yaml"' "$REMOVE"; then
    pass_test
else
    fail_test "a playbook still reads the declaration from the secrets pipeline"
fi

start_test "the shipped declaration gates nothing by default"
if grep -qE '^protected: \[\]' "$DECL"; then
    pass_test
else
    fail_test "the default must protect nothing — deploying it should change no access"
fi

start_test "the shipped declaration offers no wildcard"
if _code_only "$DECL" | grep -qE "^allowed_emails:.*\*|email-domain=\*"; then
    fail_test "a wildcard in the shipped default would make every install open"
else
    pass_test
fi

start_test "a playbook failure is not reported as a Kubernetes error"
if _code_only "$REPO/provision-host/uis/lib/service-deployment.sh" | grep -q 'die_k8s "Playbook failed'; then
    fail_test "a deliberate refusal would again be buried under 'Is the cluster running?'"
else
    pass_test
fi

start_test "the structural template sync is not gated on first_run alone"
# Assert the else-branch by its own distinctive message rather than by looking
# for an `else` after a marker — the first version of this check set a flag and
# then matched ANY later `else` in a 1400-line file, so it could never fail. The
# mutation harness caught that; a reader would not have.
if grep -q 'could not sync the structural secrets template' "$REPO/uis"; then
    pass_test
else
    fail_test "no non-first-run sync branch — new image keys never reach an existing install"
fi

start_test "an existing install also receives new .uis.extend defaults"
# Without this, a file a release introduces appears only on machines installed
# after that release — so protected-services.yaml would be missing on every
# existing host while the playbook that reads it shipped in the same version.
# Assert the ADJACENT PAIR I added, not "the string appears somewhere after a
# marker". That looser form has now been vacuous twice in one release: there are
# two call sites, so matching anywhere-after-the-marker found the other one and
# the assertion could not fail. Distinctive strings, not positional flags.
if grep -A1 'copy_defaults_if_missing || true' \
        "$REPO/provision-host/uis/manage/uis-cli.sh" | grep -q 'copy_secrets_templates || true'; then
    pass_test
else
    fail_test "cmd_init's already-initialized branch does not seed new .uis.extend files"
fi

print_summary
