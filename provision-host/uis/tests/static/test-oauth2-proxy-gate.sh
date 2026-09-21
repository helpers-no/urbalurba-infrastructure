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
# EVERY pattern assertion in this file goes through here. Six separate
# assertions matched their own commentary on 2026-09-18 before this became the
# rule rather than a fix applied one at a time.
_code_only() { grep -vE '^[[:space:]]*#' "$@"; }

# --- the files exist at all ---
for f in "$DEPLOY" "$MW" "$SETUP" "$SVC"; do
    start_test "$(basename "$f") exists"
    assert_file_exists "$f" && pass_test
done

# --- image pinning ---
start_test "the gate image is pinned, not :latest"
if _code_only "$DEPLOY" | grep -qE 'image: quay\.io/oauth2-proxy/oauth2-proxy:v[0-9]+\.[0-9]+\.[0-9]+'; then
    pass_test
else
    fail_test "image is not pinned to an explicit version: $(grep -m1 'image:' "$DEPLOY")"
fi

start_test "the gate image is not :latest"
if _code_only "$DEPLOY" | grep -qE 'oauth2-proxy:latest|oauth2-proxy:.*-latest'; then
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
if _code_only "$DEPLOY" | grep -q -- '--authenticated-emails-file='; then
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

# The address is cluster DNS (so it may cross namespaces where an object
# reference may not) AND it must be the ROOT, not /oauth2/auth. /oauth2/auth
# answers 401 by design — it exists for nginx's auth_request, where nginx turns
# the 401 into a redirect. Traefik has no error_page and relays the 401, so an
# anonymous visitor was never offered a login (measured, urb-agents#1226).
start_test "the forwardAuth address is cluster DNS at the ROOT, not /oauth2/auth"
if _code_only "$MW" | grep -qE 'address: http://oauth2-proxy\.oauth2-proxy\.svc\.cluster\.local:4180/$'; then
    pass_test
else
    fail_test "address is not the root: $(_code_only "$MW" | grep -m1 'address:')"
fi

start_test "the gate serves a 2xx to an authenticated caller"
# Without a static upstream the root has nothing to proxy to, so an
# authenticated request would not produce the 2xx Traefik needs to allow it.
if _code_only "$DEPLOY" | grep -q -- '--upstream=static://202'; then
    pass_test
else
    fail_test "no static upstream — an authenticated request has no 2xx to return"
fi

# --- the /oauth2/ path must be reachable without a session ---
start_test "an unauthenticated /oauth2/ route is generated"
if _code_only "$MW" | grep -q 'PathPrefix(`/oauth2/`)'; then
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
if _code_only "$DEPLOY" "$MW" 2>/dev/null | grep -qE 'regex_replace|ansible\.builtin\.'; then
    fail_test "an ansible-only filter cannot be rendered outside the container"
else
    pass_test
fi

# --- balanced Jinja blocks (the cheapest real check available without a renderer) ---
for f in "$DEPLOY" "$MW"; do
    start_test "$(basename "$f") has balanced Jinja for/if blocks"
    # _code_only, because these files document the very tags they contain —
    # the sixth time on 2026-09-18 that an assertion matched its own commentary.
    fors=$(_code_only "$f" | grep -oE '\{%-? *for ' | wc -l)
    endfors=$(_code_only "$f" | grep -oE '\{%-? *endfor *-?%\}' | wc -l)
    ifs=$(_code_only "$f" | grep -oE '\{%-? *if ' | wc -l)
    endifs=$(_code_only "$f" | grep -oE '\{%-? *endif *-?%\}' | wc -l)
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
if _code_only "$REPO/uis" | grep -q 'could not sync the structural secrets template'; then
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

# ---------------------------------------------------------------------------
# 🔴 NO LINE MAY END WITH A JINJA BLOCK TAG.
#
# Ansible's template module sets trim_blocks=yes, so the newline after a block
# tag is swallowed and the line merges with the one below. That produced
# "mapping values are not allowed here" on the tester's first render
# (urb-agents#1226) — `kind: Rule` became a second mapping value on the match
# line. The other route used the identical loop but was followed by plain text,
# so its newline survived and it did not error.
#
# This asserts the INVARIANT rather than simulating Jinja. I tried the
# simulation: it could not render the constructs the original used, crashed, and
# the YAML parser then happily accepted the traceback — a check that could not
# fail for the reason it claimed. The invariant needs no renderer and forbids
# the whole class.
# ---------------------------------------------------------------------------
for f in "$DEPLOY" "$MW"; do
    start_test "$(basename "$f") has no line ending in a Jinja block tag"
    offenders=$(grep -nE '\{%[^}]*%\}[[:space:]]*$' "$f" | grep -vE '^\s*[0-9]+:\s*\{%-?\s*(end)?(for|if)\b' || true)
    if [[ -z "$offenders" ]]; then
        pass_test
    else
        fail_test "trim_blocks will swallow the newline: $(echo "$offenders" | head -1)"
    fi
done

# ---------------------------------------------------------------------------
# 🔴 NO JINJA STATEMENT TAG IN A YAML COMMENT, IN ANY TEMPLATE IN THE REPO.
#
# A `#` line is a YAML comment, not a Jinja one: Ansible renders the file as
# text and parses every line. A quoted loop-open tag with no loop expression
# broke 1.6.123 at line 5, before any real tag was reached.
#
# 🔵 EXPRESSION tags ({{ }}) in comments are deliberate and must stay — four
# shipped templates interpolate a service name into the rendered comment. Only
# STATEMENT tags ({%) are forbidden, and no shipped template has one, so this
# forbids the mistake without touching working code.
#
# ⚠️ This is a cheap guard, not the real one. The real one is
# test-jinja-templates-render.sh, which renders the templates. A static check
# has now twice passed on a template that could not be parsed.
# ---------------------------------------------------------------------------
start_test "no template has a Jinja statement tag inside a YAML comment"
offenders=""
for t in "$REPO"/manifests/*.j2; do
    if grep -qE '^[[:space:]]*#.*\{%' "$t" 2>/dev/null; then
        offenders="$offenders $(basename "$t")"
    fi
done
if [[ -z "$offenders" ]]; then
    pass_test
else
    fail_test "Jinja parses # lines — these will fail to render:$offenders"
fi

# ---------------------------------------------------------------------------
# 1.6.125 — the three defects from the round that finally got a 302.
# ---------------------------------------------------------------------------
start_test "an SPA path gets its own middleware pointed at /oauth2/auth"
# The root answers 302; only /oauth2/auth answers 401. And ForwardAuth sends its
# own subrequest, so the gate always sees `GET /` and --api-route can never match
# the real path — measured by the tester. The distinction has to live in Traefik.
# Assert BOTH halves: the Middleware object AND a route that references it. A
# first attempt checked only that the name appeared somewhere — and the name
# appears twice, so renaming one occurrence left the assertion passing on a
# template where the route referenced a middleware that no longer existed.
api_mw_defined=$(_code_only "$MW" | grep -cE '^  name: oauth2-forward-auth-api$')
api_mw_used=$(_code_only "$MW" | grep -cE '^ *- name: oauth2-forward-auth-api$')
if [[ "$api_mw_defined" -ge 1 && "$api_mw_used" -ge 1 ]] \
   && _code_only "$MW" | grep -q 'local:4180/oauth2/auth'; then
    pass_test
else
    fail_test "API middleware defined=$api_mw_defined used=$api_mw_used — an SPA's XHR gets a 302 it cannot follow"
fi

start_test "api_routes rules outrank the protected route"
if [[ "$(_code_only "$MW" | grep -c 'priority: 25')" -ge 1 ]]; then
    pass_test
else
    fail_test "an api_routes rule at or below priority 20 would never win"
fi

start_test "every generated object carries the cleanup label"
# Cleanup deletes by label across all namespaces. Without the label on all of
# them, undeploy leaves a route pointing at a deleted gate -> the host 500s.
if [[ "$(_code_only "$MW" | grep -c 'urbalurba.io/generated-by: oauth2-proxy')" -ge 4 ]]; then
    pass_test
else
    fail_test "only $(_code_only "$MW" | grep -c 'urbalurba.io/generated-by: oauth2-proxy') of 4 objects labelled"
fi

start_test "undeploy finds objects by label, not from the declaration"
if _code_only "$REMOVE" | grep -q 'urbalurba.io/generated-by=oauth2-proxy'; then
    pass_test
else
    fail_test "cleanup still trusts the declaration, which may have been emptied"
fi

start_test "undeploy fails rather than reporting a clean removal with leftovers"
if grep -q '04b Fail if anything survived' "$REMOVE"; then
    pass_test
else
    fail_test "a surviving route points ForwardAuth at a deleted Service -> 500"
fi

start_test "an empty protected list un-gates instead of being refused"
if grep -q '06c Remove the gating, because an empty list is a deliberate un-gate' "$SETUP"; then
    pass_test
else
    fail_test "no supported way to un-gate a host — the documented revert is refused"
fi

start_test "a first deploy with nothing declared is still refused"
if grep -q '06b Refuse a first deploy that would protect nothing' "$SETUP"; then
    pass_test
else
    fail_test "an empty first deploy would silently do nothing"
fi

# ---------------------------------------------------------------------------
# 1.6.126: a summary must not claim work it did not do.
#
# The tester ran undeploy twice; the second run had no namespace left to delete
# and the summary still said "and the gate namespace". Cosmetic on its own, and
# the same class as the "✓ oauth2-proxy removed" that shipped a 500 — a report
# asserting an action the code did not take.
# ---------------------------------------------------------------------------

start_test "the summary's namespace claim is conditional, not hardcoded"
if _code_only "$REMOVE" | grep -q 'route(s)/middleware(s){{ gate_ns_phrase }}'; then
    pass_test
else
    fail_test "the summary states the namespace outcome unconditionally"
fi

start_test "both namespace outcomes are actually populated"
# One assertion for the interpolation is not enough: {{ gate_ns_phrase }} with
# no set_fact behind it renders empty on one path and says nothing at all. The
# weak-assertion lesson from 1.6.125 — check the definition AND the reference.
if grep -q 'when: (gate_ns.rc | default(1)) == 0' "$REMOVE" \
   && grep -q 'when: (gate_ns.rc | default(1)) != 0' "$REMOVE" \
   && [[ "$(grep -c 'gate_ns_phrase:' "$REMOVE")" -eq 2 ]]; then
    pass_test
else
    fail_test "gate_ns_phrase is referenced but not set on both paths"
fi

start_test "the namespace is queried BEFORE it is deleted"
# Asked after the delete, the answer is always "gone" and the summary is always
# wrong in the same direction.
_q=$(grep -n '04c Was the gate namespace still there' "$REMOVE" | cut -d: -f1)
_d=$(grep -n '05 Remove the gate namespace' "$REMOVE" | cut -d: -f1)
if [[ -n "$_q" && -n "$_d" && "$_q" -lt "$_d" ]]; then
    pass_test
else
    fail_test "the namespace check does not precede the deletion (query=$_q delete=$_d)"
fi

start_test "the summary warns that Terminating is not a failure"
if _code_only "$REMOVE" | grep -q 'Terminating'; then
    pass_test
else
    fail_test "an operator checking immediately sees Terminating and reads it as a failed removal"
fi

# --- negative assertions, each with a positive control ---
#
# An empty grep is not evidence. On 2026-09-18 `strings` was absent from the
# maintainer's host and 0 hits were read as proof of absence, twice. So every
# absence check below first proves its own pattern can match.

start_test "no ternary filter in either oauth2 playbook"
_tern='[|][[:space:]]*ternary[[:space:]]*[(]'
if ! printf '%s\n' 'msg: "{{ x == 1 | ternary(a, b) }}"' | grep -qE "$_tern"; then
    fail_test "positive control failed: the ternary pattern matches nothing, so its absence proves nothing"
elif _code_only "$SETUP" "$REMOVE" 2>/dev/null | grep -qE "$_tern"; then
    fail_test "a ternary is back: $(_code_only "$SETUP" "$REMOVE" | grep -nE "$_tern" | head -1)"
else
    pass_test
fi

start_test "undeploy does not claim the hosts fail closed"
# It does not, and the tester measured 200 after an undeploy. The gate adds a
# route in FRONT of each service's own route, so deleting it uncovers the
# original. This assertion reads the header, so it cannot use _code_only.
_claim='stop being reachable|fail closed|FAIL CLOSED'
if ! printf '%s\n' '# protected services fail closed, not open' | grep -qE "$_claim"; then
    fail_test "positive control failed: the claim pattern matches nothing"
elif grep -qE "$_claim" "$REMOVE"; then
    fail_test "the header claims a safety property the code does not have: $(grep -nE "$_claim" "$REMOVE" | head -1)"
else
    pass_test
fi

start_test "undeploy states the measured behaviour instead"
if grep -q 'REOPENS THE HOSTS' "$REMOVE"; then
    pass_test
else
    fail_test "removing the false claim is half the fix; the true one has to be written down"
fi

# ---------------------------------------------------------------------------
# 1.6.126: a guard must make every check its refusal message describes.
#
# The refusal text loops over all three credential keys looking for ''/
# placeholder/your-. The condition tested that for CLIENT_ID only, so
# CLIENT_SECRET="your-client-secret" passed the guard while the message it would
# have printed named it. And nothing checked the cookie secret's LENGTH, though
# the tester credited the playbook with refusing bad ones.
# ---------------------------------------------------------------------------

start_test "the credential guard checks all three keys for a placeholder"
if [[ "$(_code_only "$SETUP" | grep -c "'placeholder' in (urbalurba_secrets")" -eq 3 ]]; then
    pass_test
else
    fail_test "only $(_code_only "$SETUP" | grep -c "'placeholder' in (urbalurba_secrets") of 3 keys tested for 'placeholder'"
fi

start_test "the credential guard checks all three keys for an unedited your- value"
if [[ "$(_code_only "$SETUP" | grep -c "'your-' in (urbalurba_secrets")" -eq 3 ]]; then
    pass_test
else
    fail_test "only $(_code_only "$SETUP" | grep -c "'your-' in (urbalurba_secrets") of 3 keys tested for 'your-'"
fi

start_test "a cookie secret oauth2-proxy cannot use is refused, not crashlooped"
# 16, 24 or 32 bytes — AES-128/192/256. Any other length is a pod that will not
# start, surfacing as a later assertion timing out on /oauth2/auth: the symptom,
# not the cause.
if _code_only "$SETUP" | grep -qE 'not in \[16, 24, 32\]'; then
    pass_test
else
    fail_test "no length check — a truncated secret becomes a crashloop with a misleading error"
fi

start_test "the length refusal names all three valid lengths, not just 32"
# 32 is what the documented recipe produces, but 16 and 24 are equally valid and
# a guard that names only 32 teaches the wrong rule.
if _code_only "$SETUP" | grep -q 'exactly 16, 24 or 32 bytes'; then
    pass_test
else
    fail_test "the refusal message does not state the real rule"
fi

# ---------------------------------------------------------------------------
# 1.6.126: rotating a credential must actually roll the pod.
#
# The three credentials arrive as env.valueFrom.secretKeyRef. Kubernetes does
# not restart a pod when a referenced Secret changes and the pod template was
# otherwise byte-identical between runs, so `deploy` had nothing to roll: it
# printed success while the gate carried on with the OLD credentials, and the
# breakage would surface later when the old value was revoked at the provider.
# ---------------------------------------------------------------------------

start_test "the pod template carries a secret version, so a rotation rolls it"
if _code_only "$DEPLOY" | grep -q 'urbalurba.io/secret-version: "{{ oauth2_secret_version }}"'; then
    pass_test
else
    fail_test "no secret version on the pod template — a credential rotation would roll nothing"
fi

start_test "the secret version sits on the POD template, not the Deployment metadata"
# An annotation on the Deployment's own metadata changes nothing about the pod,
# so it would look like this fix and roll nothing. Assert it appears after the
# pod template opens. The render suite checks the parsed position too; this one
# runs on a dev host, where no Jinja renderer exists.
_tpl=$(grep -n '^  template:' "$DEPLOY" | head -1 | cut -d: -f1)
_ann=$(grep -n 'urbalurba.io/secret-version' "$DEPLOY" | grep -v '^\s*#' | head -1 | cut -d: -f1)
if [[ -n "$_tpl" && -n "$_ann" && "$_ann" -gt "$_tpl" ]]; then
    pass_test
else
    fail_test "secret version is not inside the pod template (template=$_tpl annotation=$_ann)"
fi

start_test "the playbook passes the secret version it just read"
if _code_only "$SETUP" | grep -q 'oauth2_secret_version: "{{ urbalurba_secrets.resources\[0\].metadata.resourceVersion }}"'; then
    pass_test
else
    fail_test "the template variable is never supplied, so the render fails or the annotation is constant"
fi

start_test "the deploy waits for the rollout, not for any pod being Running"
# During a rolling update the OLD pod is Running, so an until-Running loop passes
# instantly and the play asserts against a gate that was never replaced. That is
# how "deployed successfully" was printed over the previous credentials.
# 🔴 Match the ARGV, not the word. The first version grepped for 'rollout'
# anywhere, which matched the register name `gate_rollout` — so replacing the
# command with `kubectl get deployment` left the assertion passing. Found by
# mutation, the same weak-assertion shape as 1.6.125's middleware-name check.
if _code_only "$SETUP" | grep -qE '^\s+- rollout$' \
   && _code_only "$SETUP" | grep -qE '^\s+- status$' \
   && _code_only "$SETUP" | grep -qE '^\s+- deployment/oauth2-proxy$'; then
    pass_test
else
    fail_test "no 'kubectl rollout status deployment/oauth2-proxy' — the play can continue against the pod it meant to replace"
fi

start_test "the old until-Running loop is gone rather than left beside it"
# Leaving it is not harmless: it re-introduces the instant pass and makes the
# rollout wait look redundant to the next reader.
# 🔴 grep -F, not -E. The first version of this check used an ERE containing an
# unescaped `|` and `(`, so it was an ALTERNATION and matched any mention of
# gate_pods.resources at all. It failed — and the failure was real for a
# different reason than the pattern claimed, which is how the undefined
# gate_pods variable was found. A literal match cannot go wrong that way.
_pat="gate_pods.resources | map(attribute='status.phase')"
if ! printf '%s\n' "$_pat" | grep -qF "$_pat"; then
    fail_test "positive control failed: the until-Running pattern matches nothing"
elif _code_only "$SETUP" | grep -qF "$_pat"; then
    fail_test "the until-Running loop is still there: $(_code_only "$SETUP" | grep -nF "$_pat" | head -1)"
else
    pass_test
fi

start_test "a pod serving an older secret version fails the deploy"
if grep -q '08c Fail if a pod is still serving an older secret version' "$SETUP"; then
    pass_test
else
    fail_test "nothing re-queries the running pod, so a silent non-rotation still reports success"
fi

# ---------------------------------------------------------------------------
# A lint for the class of bug above, not just the instance.
#
# Deleting a task takes its `register:` with it, and any OTHER task still reading
# that variable then fails at runtime with "'x' is undefined" — on every deploy,
# for everyone. It is invisible to review because the reference and the register
# are far apart, and no YAML check catches it. This found a real one in 1.6.126:
# the until-Running loop was removed and two references in the report survived.
# ---------------------------------------------------------------------------

start_test "every registered variable these playbooks read is also registered"
_missing=""
for _pb in "$SETUP" "$REMOVE"; do
    # names that are registered in this file
    _regs=$(_code_only "$_pb" | sed -n 's/^[[:space:]]*register:[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' | sort -u)
    # names dereferenced as a registered result: x.stdout / x.rc / x.resources
    _refs=$(_code_only "$_pb" \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]*\.(stdout|stdout_lines|rc|resources|results)' \
        | cut -d. -f1 | sort -u)
    for _r in $_refs; do
        # play vars and facts are legitimate non-register sources; only flag a
        # name that looks like a task result and has no register anywhere here.
        #
        # `item` is Ansible's loop variable and carries .stdout when looping over
        # a registered result's .results — legitimate, and never registered. The
        # lint flagged it the first time a task did that, which is the lint
        # finding its own boundary rather than a bug in the playbook.
        # ⚠️ This does NOT check that a task using `item` has a `loop:`; that is
        # a different lint and is not claimed here.
        [[ "$_r" == "item" ]] && continue
        if ! printf '%s\n' "$_regs" | grep -qx "$_r"; then
            _missing="$_missing $(basename "$_pb"):$_r"
        fi
    done
done
if [[ -z "$_missing" ]]; then
    pass_test
else
    fail_test "read but never registered —$_missing"
fi

# ---------------------------------------------------------------------------
# 1.6.126: the gate matches literal hosts; the services match patterns.
#
# HostRegexp(`dagster\..+`) at priority 10 serves ANY dagster.* hostname. The
# gate's Host(`dagster.urbalurba.com`) at priority 20 wins only for the host it
# names. Point a second apex domain at the cluster and the service is reachable
# there ungated — while every check on the declared host keeps passing.
# Found by ops-dev reading a running ingress, before a second domain existed.
# ---------------------------------------------------------------------------

start_test "the deploy looks for a broader route to each service it gates"
if grep -q '11b Look for a broader route to a service we just gated' "$SETUP"; then
    pass_test
else
    fail_test "nothing notices the gate and the service disagreeing about which hosts exist"
fi

start_test "the desync check is driven by the declaration, so ungated services are never flagged"
# api-atlas has the same pattern and no gate — a published API reachable under a
# second name is the intent. Looping over the declaration means it is never
# examined, which is the design, not an omission.
if _code_only "$SETUP" | grep -A24 '11b Look for a broader route' | grep -qF 'loop: "{{ gate_config.protected }}"'; then
    pass_test
else
    fail_test "the check does not iterate the declaration — it may flag services nothing gates"
fi

start_test "the desync check ignores the gate's own generated routes"
# Without this it reports the gate's own IngressRoute as the broader route, every
# run, for every service — a warning that is always wrong is a warning nobody
# reads, which is how the original finding stayed invisible.
if _code_only "$SETUP" | grep -A24 '11b Look for a broader route' | grep -qF 'urbalurba.io/generated-by"] != "oauth2-proxy"'; then
    pass_test
else
    fail_test "the check would flag itself and become noise"
fi

start_test "both the refusal and the accepted-pattern notice name the gated hosts"
# "a pattern is broader than a literal" is not actionable. The operator needs to
# see which hosts are covered today. Re-anchored in 1.6.141: the task this used
# to read was replaced when the warning became a refusal, and an assertion
# anchored on a task NAME goes quiet when the name changes — so it checks both
# surfaces by count rather than one by title.
if [[ "$(_code_only "$SETUP" | grep -c "item.item.hosts | join")" -ge 2 ]]; then
    pass_test
else
    fail_test "only $(_code_only "$SETUP" | grep -c "item.item.hosts | join") of 2 surfaces say which hosts the gate actually covers"
fi

# ---------------------------------------------------------------------------
# 1.6.141: a Host header must not walk around the gate silently.
#
# urb-agents#1364, measured on a live cluster:
#
#   Host: dagster.urbalurba.com            -> 302 to the provider   GATED
#   Host: dagster.localhost                -> 200, the full UI      NO AUTH
#   Host: dagster.anything-at-all.example  -> 200, the full UI      NO AUTH
#
# The service's own route is a pattern; the gate matches literal hosts. 1.6.126
# detected that and WARNED. The warning printed once and the cluster then sat
# bypassable indefinitely with every signal green. The deployability argument
# for warning was right; the trade was wrong.
# ---------------------------------------------------------------------------

start_test "a broader route now REFUSES the deploy rather than warning"
if _code_only "$SETUP" | grep -A2 '11c Refuse to report a gate' | grep -qF 'ansible.builtin.fail'; then
    pass_test
else
    fail_test "the bypass is still only a warning, and a warning printed once does not survive the week"
fi

start_test "and the refusal can be accepted deliberately, so the gate stays deployable"
# Refusing with no way through would make the gate undeployable for every
# service that has a pattern route — which is all of them today. That was the
# correct half of the original objection.
if _code_only "$SETUP" | grep -qF 'accept_unauthenticated_pattern'; then
    pass_test
else
    fail_test "no opt-out — the gate cannot be deployed at all"
fi

start_test "accepting it does NOT silence it"
# An opt-out that stops the message becomes a way to stop thinking. The
# operator who accepted the pattern is told what they accepted, every deploy.
if _code_only "$SETUP" | grep -qF '11d An accepted open pattern is still reported'; then
    pass_test
else
    fail_test "the key silences the finding instead of recording it"
fi

start_test "the refusal says what to do before it offers the escape hatch"
# Ordering matters: an operator who meets the escape hatch first will take it.
_fix=$(_code_only "$SETUP" | grep -n 'Narrow the service' | head -1 | cut -d: -f1)
_esc=$(_code_only "$SETUP" | grep -n 'accept_unauthenticated_pattern: true' | head -1 | cut -d: -f1)
if [[ -n "$_fix" && -n "$_esc" && "$_fix" -lt "$_esc" ]]; then
    pass_test
else
    fail_test "the escape hatch is offered before the fix (fix=$_fix escape=$_esc)"
fi

start_test "the declaration documents the key as a security decision"
if grep -qF 'accept_unauthenticated_pattern' "$DECL" && grep -qF 'NO LOGIN' "$DECL"; then
    pass_test
else
    fail_test "an operator meets the key with no statement of what it accepts"
fi

print_summary
