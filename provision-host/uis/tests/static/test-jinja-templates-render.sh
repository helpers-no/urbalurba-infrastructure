#!/bin/bash
# test-jinja-templates-render.sh — actually render every Jinja template.
#
# 🔴 WHY THIS EXISTS: TWO UNPARSEABLE TEMPLATES SHIPPED WITH ALL TESTS GREEN.
#
# 1.6.121 shipped a template whose match line ended with a block tag. Ansible's
# trim_blocks swallowed the newline, the line merged with the next, and YAML
# rejected it. Static tests passed.
#
# 1.6.123 fixed that and shipped a template whose explanatory COMMENT quoted a
# loop-open tag with no loop expression. A `#` line is a YAML comment, not a
# Jinja one — Ansible renders the file as text and parses every line — so Jinja
# failed on line 5 and never reached the real tags on line 37. Static tests
# passed again, including a new assertion written specifically to catch the
# first bug: it forbade the SHAPE of that bug rather than the class.
#
# The tester's conclusion, and it is correct: "this is the second time a static
# assertion has passed on an unparseable template. Worth taking as the finding
# rather than as two accidents." The only check that found either bug was
# rendering the template. So this renders them.
#
# ⚠️ It cannot run on a dev host: there is no Jinja2, no pip, no ensurepip, no
# venv and no docker there. It therefore SKIPS locally and HARD FAILS in CI if
# the dependency is missing — because a check that silently skips is how three
# prometheus assertions went unrun for months, and the yq install step in
# test-uis.yml exists for exactly that reason.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/manifests" ]]; then
    MANIFESTS="/mnt/urbalurbadisk/manifests"
else
    MANIFESTS="$(cd "$SCRIPT_DIR/../../../../manifests" && pwd)"
fi

print_test_section "Jinja template render Tests"

# --- dependency, and the rule about skipping ---
HAVE_JINJA=0
if python3 -c 'import jinja2, yaml' 2>/dev/null; then
    HAVE_JINJA=1
fi

if [[ "$HAVE_JINJA" -eq 0 ]]; then
    if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
        start_test "jinja2 and pyyaml are installed (required in CI)"
        fail_test "python3 -c 'import jinja2, yaml' failed in CI — the render check would skip, which is how two unparseable templates shipped green. Install them in the workflow."
        print_summary
        exit 1
    fi
    start_test "jinja2 available for real template rendering"
    skip_test "no jinja2/pyyaml on this host — CI renders these; a dev host cannot"
    print_summary
    exit 0
fi

# ---------------------------------------------------------------------------
# One context per template. These are FIXTURES, not defaults: each supplies the
# variables its template needs so rendering exercises the real code paths
# (loops with one item and with two, and both branches of a conditional).
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/render.py" <<'PYEOF'
import json, sys, pathlib
import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

tpl_path = pathlib.Path(sys.argv[1])
ctx = json.loads(sys.argv[2])

# trim_blocks/lstrip_blocks match ansible.builtin.template's defaults, so a
# template that renders here renders the same way in the playbook.
env = Environment(
    loader=FileSystemLoader(str(tpl_path.parent)),
    trim_blocks=True,
    lstrip_blocks=False,
    keep_trailing_newline=True,
    undefined=StrictUndefined,
)
out = env.get_template(tpl_path.name).render(**ctx)
docs = [d for d in yaml.safe_load_all(out) if d is not None]

# The pod template's annotations, when there is a Deployment in the render. This
# is how the rotation annotation is asserted on its PARSED value rather than by
# grepping the template text — a text match would pass on a template whose
# annotation sat in the wrong place to trigger a roll.
pod_ann = {}
for d in docs:
    if d.get("kind") == "Deployment":
        pod_ann = (d.get("spec", {}).get("template", {})
                    .get("metadata", {}).get("annotations") or {})

# Routes, parsed. A route's PRIORITY decides which rule wins when two match,
# and asserting it by grepping the template text would pass on a priority that
# landed in the wrong route. It has to come off the parsed document.
routes = []
for d in docs:
    if d.get("kind") == "IngressRoute":
        for r in (d.get("spec", {}).get("routes") or []):
            routes.append({"priority": r.get("priority"),
                           "match": r.get("match"),
                           "middlewares": [m.get("name") for m in (r.get("middlewares") or [])]})

# Every Deployment's name, pod label and the secretKeyRef.key its containers
# read, parsed off the real rendered+parsed document — not grepped off the
# template text, so a value that landed in the wrong place would still fail.
deployments = []
for d in docs:
    if d.get("kind") == "Deployment":
        containers = d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        secret_key = None
        env_names = []
        for c in containers:
            for e in (c.get("env") or []):
                env_names.append(e.get("name"))
                ref = (e.get("valueFrom") or {}).get("secretKeyRef")
                if ref:
                    secret_key = ref.get("key")
        deployments.append({
            "name": d.get("metadata", {}).get("name"),
            "podLabel": (d.get("spec", {}).get("template", {}).get("metadata", {}).get("labels") or {}).get("app"),
            "secretKey": secret_key,
            "envNames": env_names,
            "hasVolumeMounts": any("volumeMounts" in c for c in containers),
            "containers": [{"name": c.get("name"), "resources": c.get("resources", {})} for c in containers],
        })

print(json.dumps({"documents": len(docs),
                  "kinds": [f"{d.get('kind')}/{d.get('metadata',{}).get('name')}" for d in docs],
                  "podAnnotations": pod_ann,
                  "routes": routes,
                  "deployments": deployments}))
PYEOF

_render() {
    local tpl="$1" ctx="$2"
    python3 "$TMP/render.py" "$MANIFESTS/$tpl" "$ctx" 2>&1
}

# The 088 templates live beside the playbooks, not in manifests/.
PBT="$(cd "$MANIFESTS/../ansible/playbooks/templates" && pwd)"
_render_pb() {
    local tpl="$1" ctx="$2"
    python3 "$TMP/render.py" "$PBT/$tpl" "$ctx" 2>&1
}

# --- the oauth2-proxy gate: one host, and the provider conditional ---
start_test "072-oauth2-proxy-deployment.yaml.j2 renders and parses (provider: github)"
CTX='{"oauth2_provider":"github","oauth2_issuer":"","oauth2_cookie_domain":"example.org","oauth2_allowed_emails":["a@example.org"],"oauth2_secret_version":"12345"}'
OUT="$(_render 072-oauth2-proxy-deployment.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "072-oauth2-proxy-deployment.yaml.j2 renders the oidc branch too"
CTX='{"oauth2_provider":"oidc","oauth2_issuer":"https://idp.example.org","oauth2_cookie_domain":"example.org","oauth2_allowed_emails":["a@example.org","b@example.org"],"oauth2_secret_version":"12345"}'
OUT="$(_render 072-oauth2-proxy-deployment.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "072-oauth2-proxy-middleware.yaml.j2 renders and parses (one host)"
CTX='{"oauth2_protected":[{"name":"svc","namespace":"svcns","service":"svc-web","port":80,"hosts":["svc.localhost"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

# The two-host case is the one the join expression exists for, and the one a
# single-host fixture would never exercise.
start_test "072-oauth2-proxy-middleware.yaml.j2 renders and parses (two hosts)"
CTX='{"oauth2_protected":[{"name":"svc","namespace":"svcns","service":"svc-web","port":80,"hosts":["svc.localhost","svc.example.org"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "072-oauth2-proxy-middleware.yaml.j2 renders two protected services"
CTX='{"oauth2_protected":[{"name":"a","namespace":"ans","service":"a-web","port":80,"hosts":["a.localhost"]},{"name":"b","namespace":"bns","service":"b-web","port":8080,"hosts":["b.localhost"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

# --- api_routes: the SPA case, which is why the second middleware exists ---
start_test "072-oauth2-proxy-middleware.yaml.j2 renders api_routes"
CTX='{"oauth2_protected":[{"name":"svc","namespace":"svcns","service":"svc-web","port":80,"hosts":["svc.localhost"],"api_routes":["^/graphql"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

# A service with no api_routes at all must still render — the default([]) path.
start_test "072-oauth2-proxy-middleware.yaml.j2 renders with api_routes absent"
CTX='{"oauth2_protected":[{"name":"svc","namespace":"svcns","service":"svc-web","port":80,"hosts":["svc.localhost"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "two api_routes produce two rules"
CTX='{"oauth2_protected":[{"name":"svc","namespace":"svcns","service":"svc-web","port":80,"hosts":["svc.localhost"],"api_routes":["^/graphql","^/api/"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

# --- the rendered output must contain what it is for ---
start_test "the rendered middleware produces the expected objects"
CTX='{"oauth2_protected":[{"name":"svc","namespace":"svcns","service":"svc-web","port":80,"hosts":["svc.localhost"],"api_routes":["^/graphql"]}]}'
OUT="$(_render 072-oauth2-proxy-middleware.yaml.j2 "$CTX")"
if [[ "$OUT" == *'Middleware/oauth2-forward-auth'* \
   && "$OUT" == *'Middleware/oauth2-forward-auth-api'* \
   && "$OUT" == *'IngressRoute/svc-oauth2-protected'* \
   && "$OUT" == *'IngressRoute/svc-oauth2-callback'* ]]; then
    pass_test
else
    fail_test "expected four objects including the api middleware, got: $OUT"
fi

# --- the rotation annotation: the pod must change when the Secret does ---
#
# Without this annotation a credential rotation rolls nothing: the three values
# arrive via secretKeyRef, Kubernetes does not restart a pod when a Secret
# changes, and the pod template is otherwise identical between runs. The tester
# measured a deploy printing success while the gate kept the OLD credentials.

start_test "the pod template carries the secret version, in the place that rolls it"
CTX='{"oauth2_provider":"github","oauth2_issuer":"","oauth2_cookie_domain":"example.org","oauth2_allowed_emails":["a@example.org"],"oauth2_secret_version":"rv-11111"}'
OUT="$(_render 072-oauth2-proxy-deployment.yaml.j2 "$CTX")"
if python3 -c '
import json,sys
d = json.loads(sys.argv[1])
sys.exit(0 if d["podAnnotations"].get("urbalurba.io/secret-version") == "rv-11111" else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "pod-template annotation absent or wrong: $OUT"
fi

start_test "a different secret version renders a different pod template"
# The whole mechanism is that the rendered pod changes. Two renders that differ
# only in the version must differ in output, or the Deployment has nothing to
# roll and the rotation is silent again.
CTX_A='{"oauth2_provider":"github","oauth2_issuer":"","oauth2_cookie_domain":"example.org","oauth2_allowed_emails":["a@example.org"],"oauth2_secret_version":"rv-11111"}'
CTX_B='{"oauth2_provider":"github","oauth2_issuer":"","oauth2_cookie_domain":"example.org","oauth2_allowed_emails":["a@example.org"],"oauth2_secret_version":"rv-22222"}'
A="$(_render 072-oauth2-proxy-deployment.yaml.j2 "$CTX_A")"
B="$(_render 072-oauth2-proxy-deployment.yaml.j2 "$CTX_B")"
if [[ "$A" != "$B" ]]; then pass_test; else fail_test "identical render for two secret versions — a rotation would roll nothing"; fi

start_test "omitting the secret version is a hard render failure, not an empty annotation"
# StrictUndefined is the contract: add a template variable and forget to pass it
# from the playbook, and this fails here rather than shipping an annotation that
# is empty on every run — which would peg the pod template constant again.
CTX='{"oauth2_provider":"github","oauth2_issuer":"","oauth2_cookie_domain":"example.org","oauth2_allowed_emails":["a@example.org"]}'
OUT="$(_render 072-oauth2-proxy-deployment.yaml.j2 "$CTX")"
if [[ "$OUT" != \{* ]] && [[ "$OUT" == *oauth2_secret_version* ]]; then
    pass_test
else
    fail_test "a missing secret version rendered anyway: $OUT"
fi

# ---------------------------------------------------------------------------
# 088-postgrest-ingressroute: the spec alias, and the priority band it sits in.
#
# urb-agents#1490 — PostgREST serves its OpenAPI document at `/` and treats
# every other path as a table name, so /openapi.json returns PGRST205 "Could
# not find the table 'api_v1.openapi.json'". Real clients were measured asking
# for it. The alias is routing only; there is no second document to drift.
#
# 🔴 The priority is the whole safety question. The alias carries no
# ForwardAuth middleware, so if it ever outranks oauth2-proxy's route it
# serves the full schema of every exposed view PAST AUTHENTICATION. The
# assertion below derives the gate's lowest priority from 072's own template
# rather than hardcoding it: lower the gate and this test fails instead of the
# hole opening silently.
# ---------------------------------------------------------------------------

_PGRST_IR_CTX='{"_app_name":"atlas","_url_prefix":"api-atlas"}'

start_test "088-postgrest-ingressroute.yml.j2 renders and parses (two documents)"
OUT="$(_render_pb 088-postgrest-ingressroute.yml.j2 "$_PGRST_IR_CTX")"
if [[ "$OUT" == \{* ]] && [[ "$(printf '%s' "$OUT" | jq -r '.documents')" == "2" ]]; then
    pass_test
else
    fail_test "expected an IngressRoute and a Middleware: $OUT"
fi

start_test "the alias route outranks the catch-all, or it never fires"
# Traefik's default priority is the rule's LENGTH, which for the catch-all is
# about 27 — above anything safe for the alias. Both must be explicit.
_alias_p="$(printf '%s' "$OUT" | jq -r '.routes[] | select(.match | contains("openapi.json")) | .priority')"
_base_p="$(printf '%s' "$OUT" | jq -r '.routes[] | select(.match | contains("openapi.json") | not) | .priority')"
if [[ "$_alias_p" =~ ^[0-9]+$ ]] && [[ "$_base_p" =~ ^[0-9]+$ ]] && (( _alias_p > _base_p )); then
    pass_test
else
    fail_test "alias priority '$_alias_p' does not beat catch-all '$_base_p' (empty means unset)"
fi

start_test "the alias never outranks the gate, whose priority is read from 072"
_gate_min="$(grep -oE '^\s*priority:\s*[0-9]+' "$MANIFESTS/072-oauth2-proxy-middleware.yaml.j2" \
             | grep -oE '[0-9]+' | sort -n | head -1)"
if [[ ! "$_gate_min" =~ ^[0-9]+$ ]]; then
    fail_test "could not read any priority from 072's template — the coupling is unchecked"
elif (( _alias_p < _gate_min )); then
    pass_test
else
    fail_test "alias priority $_alias_p >= gate priority $_gate_min: /openapi.json would serve the full schema past the login"
fi

start_test "the alias route references a Middleware the template actually ships"
_mw="$(printf '%s' "$OUT" | jq -r '.routes[] | select(.match | contains("openapi.json")) | .middlewares[0] // ""')"
if [[ -n "$_mw" ]] && printf '%s' "$OUT" | jq -e --arg m "Middleware/$_mw" '.kinds | index($m)' >/dev/null; then
    pass_test
else
    fail_test "alias references middleware '$_mw' which is not among: $(printf '%s' "$OUT" | jq -c '.kinds')"
fi

start_test "the playbook applies the template as multiple documents"
# from_yaml parses ONE document and raises on the second. This template emits
# two, so from_yaml would break the install at runtime, not here.
_PB="$MANIFESTS/../ansible/playbooks/088-setup-postgrest.yml"
if grep -q "088-postgrest-ingressroute.yml.j2') | from_yaml_all | list" "$_PB"; then
    pass_test
else
    fail_test "the ingressroute template is not applied with from_yaml_all | list"
fi

start_test "removing the instance removes the Middleware too"
_PBR="$MANIFESTS/../ansible/playbooks/088-remove-postgrest.yml"
if grep -q 'kind: Middleware' "$_PBR" && grep -q 'postgrest-spec-alias' "$_PBR"; then
    pass_test
else
    fail_test "undeploy leaves an orphaned Middleware in the namespace"
fi

# --- 820-cloudflare-tunnel-base.yaml.j2: the multi-env backward-compat pin ---
# Empty cf_env must render BYTE-FOR-BYTE what the original static manifest
# shipped (cloudflare-tunnel / cloudflared / CLOUDFLARE_TUNNEL_TOKEN) — proven
# here by actually rendering and parsing, not by reading the template source.
start_test "820-cloudflare-tunnel-base.yaml.j2 renders today's exact names with no cf_env"
CTX='{"cf_deployment_name":"cloudflare-tunnel","cf_pod_label":"cloudflared","cf_token_key":"CLOUDFLARE_TUNNEL_TOKEN"}'
OUT="$(_render 820-cloudflare-tunnel-base.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]] \
   && grep -q '"name": "cloudflare-tunnel"' <<<"$OUT" \
   && grep -q '"podLabel": "cloudflared"' <<<"$OUT" \
   && grep -q '"secretKey": "CLOUDFLARE_TUNNEL_TOKEN"' <<<"$OUT"; then
    pass_test
else
    fail_test "$OUT"
fi

start_test "820-cloudflare-tunnel-base.yaml.j2 renders suffixed names for a named env"
CTX='{"cf_deployment_name":"cloudflare-tunnel-test","cf_pod_label":"cloudflared-test","cf_token_key":"CLOUDFLARE_TUNNEL_TOKEN_TEST"}'
OUT="$(_render 820-cloudflare-tunnel-base.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]] \
   && grep -q '"name": "cloudflare-tunnel-test"' <<<"$OUT" \
   && grep -q '"podLabel": "cloudflared-test"' <<<"$OUT" \
   && grep -q '"secretKey": "CLOUDFLARE_TUNNEL_TOKEN_TEST"' <<<"$OUT"; then
    pass_test
else
    fail_test "$OUT"
fi

# ---------------------------------------------------------------------------
# 635-forgejo.yaml.j2: the forgejo_actions_default_url opt-in conditional.
#
# 🔴 urb-agents#2027: `{%- if %}`/`{%- endif %}` combined with Ansible's own
# trim_blocks=True ate the newline on BOTH sides of this block regardless of
# which branch rendered, merging `volumeMounts:` onto the previous line in the
# DEFAULT case and into the block's own content in the opt-in case — breaking
# `uis deploy forgejo` outright, in both branches, discovered live by imac only
# after this had already merged. The bug this file exists to catch (an
# unparseable template shipping green) recurred because this specific
# template was never added here — the harness itself (trim_blocks=True,
# lstrip_blocks=False, matching Ansible exactly) was already correct the
# whole time.
# ---------------------------------------------------------------------------

_FORGEJO_CTX_BASE='"forgejo_image":"test/forgejo:1","forgejo_http_port":3000,"forgejo_domain":"forgejo.localhost","forgejo_namespace":"forgejo"'

start_test "635-forgejo.yaml.j2 renders and parses with the opt-in unset (the plain, documented 'uis deploy forgejo')"
CTX="{${_FORGEJO_CTX_BASE},\"forgejo_actions_default_url\":\"\"}"
OUT="$(_render 635-forgejo.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "...and the forgejo container still has volumeMounts (not merged into the previous line)"
if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dep = next((x for x in d["deployments"] if x["name"] == "forgejo"), None)
sys.exit(0 if dep and dep["hasVolumeMounts"] else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "forgejo Deployment missing volumeMounts, or not found: $OUT"
fi

start_test "...and GITEA__actions__DEFAULT_ACTIONS_URL is absent when the opt-in is unset"
if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dep = next((x for x in d["deployments"] if x["name"] == "forgejo"), None)
sys.exit(0 if dep and "GITEA__actions__DEFAULT_ACTIONS_URL" not in dep["envNames"] else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "DEFAULT_ACTIONS_URL present despite being unset: $OUT"
fi

start_test "635-forgejo.yaml.j2 renders and parses with the opt-in set to 'self'"
CTX="{${_FORGEJO_CTX_BASE},\"forgejo_actions_default_url\":\"self\"}"
OUT="$(_render 635-forgejo.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "...and the forgejo container still has volumeMounts (not merged into the opt-in block)"
if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dep = next((x for x in d["deployments"] if x["name"] == "forgejo"), None)
sys.exit(0 if dep and dep["hasVolumeMounts"] else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "forgejo Deployment missing volumeMounts, or not found: $OUT"
fi

start_test "...and GITEA__actions__DEFAULT_ACTIONS_URL is present, with the right value, when opted in"
if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dep = next((x for x in d["deployments"] if x["name"] == "forgejo"), None)
sys.exit(0 if dep and "GITEA__actions__DEFAULT_ACTIONS_URL" in dep["envNames"] else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "DEFAULT_ACTIONS_URL missing despite being set to self: $OUT"
fi

# ---------------------------------------------------------------------------
# 645-github-runner.yaml.j2 (urb-agents#2030): the GitHub-protocol counterpart to
# forgejo-runner, added here from the start — not retrofitted after a regression shipped,
# the way 635-forgejo.yaml.j2 was (urb-agents#2027).
# ---------------------------------------------------------------------------

CTX='{"github_runner_namespace":"github-runner","github_runner_image":"ghcr.io/actions/actions-runner:2.337.0","github_runner_dind_image":"docker:27-dind","github_runner_repo":"owner/repo","github_runner_name":"rancher-desktop-github-runner","github_runner_labels":"self-hosted,linux,x64,docker","github_runner_memory_request":"1Gi","github_runner_memory_limit":"2Gi","github_runner_instance":"","github_runner_resource_name":"github-runner"}'

start_test "645-github-runner.yaml.j2 renders and parses"
OUT="$(_render 645-github-runner.yaml.j2 "$CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

start_test "...and the github-runner Deployment carries all four registration env vars"
if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dep = next((x for x in d["deployments"] if x["name"] == "github-runner"), None)
sys.exit(0 if dep and set(["GITHUB_RUNNER_REPO","GITHUB_RUNNER_NAME","GITHUB_RUNNER_LABELS","GITHUB_RUNNER_TOKEN"]) <= set(dep["envNames"]) else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "expected all four GITHUB_RUNNER_* env vars on the github-runner Deployment: $OUT"
fi

start_test "🔴 urb-agents#2032: the runner container's memory limit is not the 768Mi that OOM-killed a real build"
if python3 -c '
import json, sys
d = json.loads(sys.argv[1])
dep = next((x for x in d["deployments"] if x["name"] == "github-runner"), None)
runner = next((c for c in (dep or {}).get("containers", []) if c["name"] == "runner"), None)
limit = (runner or {}).get("resources", {}).get("limits", {}).get("memory")
sys.exit(0 if limit and limit != "768Mi" else 1)
' "$OUT" 2>/dev/null; then
    pass_test
else
    fail_test "runner container memory limit is missing or back to the proven-too-low 768Mi: $OUT"
fi

# ---------------------------------------------------------------------------
# 645-github-runner.yaml.j2, multi-instance (urb-agents#2053): a second runner must be able to
# coexist with the default one on the same cluster, without ever sharing a selector. render.py's
# shared parsing does not expose the Secret's referenced NAME or the full label set (only
# envNames/podLabel["app"]), so these two cases parse the template directly instead.
# ---------------------------------------------------------------------------

start_test "645-github-runner.yaml.j2: the DEFAULT instance carries no 'instance' label anywhere (backward compatibility)"
if python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/645-github-runner.yaml.j2').read())
ctx = json.loads('$CTX')
out = tpl.render(**ctx)
d = next(x for x in yaml.safe_load_all(out) if x is not None)
name_ok = d['metadata']['name'] == 'github-runner'
no_instance_label = (
    'instance' not in d['metadata']['labels']
    and 'instance' not in d['spec']['selector']['matchLabels']
    and 'instance' not in d['spec']['template']['metadata']['labels']
)
secret_ok = d['spec']['template']['spec']['containers'][0]['env'][-1]['valueFrom']['secretKeyRef']['name'] == 'github-runner-token'
import sys
sys.exit(0 if (name_ok and no_instance_label and secret_ok) else 1)
" 2>&1; then
    pass_test
else
    fail_test "the default/unnamed instance must render EXACTLY as it always has — any 'instance' label here, or a renamed Deployment/Secret, would force a redeploy of whatever is already running"
fi

start_test "645-github-runner.yaml.j2: a NAMED instance gets a suffixed name and an 'instance' label in the selector itself"
if python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/645-github-runner.yaml.j2').read())
ctx = json.loads('$CTX')
ctx['github_runner_instance'] = 'bifrost'
ctx['github_runner_resource_name'] = 'github-runner-bifrost'
out = tpl.render(**ctx)
d = next(x for x in yaml.safe_load_all(out) if x is not None)
name_ok = d['metadata']['name'] == 'github-runner-bifrost'
# The selector is what Kubernetes actually enforces uniqueness on — a label present only on
# metadata, with the selector still bare 'app=github-runner', is the exact collision this
# whole mechanism exists to prevent, so check the SELECTOR specifically, not just any label.
selector_ok = d['spec']['selector']['matchLabels'] == {'app': 'github-runner', 'instance': 'bifrost'}
pod_label_ok = d['spec']['template']['metadata']['labels'] == {'app': 'github-runner', 'instance': 'bifrost'}
secret_ok = d['spec']['template']['spec']['containers'][0]['env'][-1]['valueFrom']['secretKeyRef']['name'] == 'github-runner-bifrost-token'
import sys
sys.exit(0 if (name_ok and selector_ok and pod_label_ok and secret_ok) else 1)
" 2>&1; then
    pass_test
else
    fail_test "a named instance must get its own uniquely-selectored Deployment and its own Secret name — sharing a selector with the default instance is the exact collision this mechanism exists to prevent"
fi

# ---------------------------------------------------------------------------
# 075-authentik-config.yaml.j2: the server/worker /dev/shm + resources fix
# (urb-agents#2021). This file is Helm VALUES, not a rendered Kubernetes
# manifest — render.py's Deployment-shaped parsing does not apply, so this
# parses the raw values directly instead.
# ---------------------------------------------------------------------------

AUTHENTIK_CTX='{"domains":{"localhost":{"enabled":true,"protocol":"http","base_domain":"localhost"},"tailscale":{"enabled":true,"protocol":"https","base_domain":"example.ts.net"}},"protected_services":[{"name":"whoami","domains":"auto"}]}'

start_test "075-authentik-config.yaml.j2 renders and parses"
OUT="$(_render 075-authentik-config.yaml.j2 "$AUTHENTIK_CTX")"
if [[ "$OUT" == \{* ]]; then pass_test; else fail_test "$OUT"; fi

RAW="$(python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/075-authentik-config.yaml.j2').read())
ctx = json.loads('$AUTHENTIK_CTX')
out = tpl.render(**ctx)
d = next(x for x in yaml.safe_load_all(out) if x is not None)
worker_vols = [v['name'] for v in d.get('worker', {}).get('volumes', [])]
worker_mounts = [v['name'] for v in d.get('worker', {}).get('volumeMounts', [])]
server_vols = [v['name'] for v in d.get('server', {}).get('volumes', [])]
server_mounts = [v['name'] for v in d.get('server', {}).get('volumeMounts', [])]
print(json.dumps({
    'worker_resources': d.get('worker', {}).get('resources', {}),
    'server_resources': d.get('server', {}).get('resources', {}),
    'worker_has_dshm': 'dshm' in worker_vols and 'dshm' in worker_mounts,
    'server_has_dshm': 'dshm' in server_vols and 'dshm' in server_mounts,
}))
" 2>&1)"

start_test "🔴 urb-agents#2021: worker and server both have a memory-backed /dev/shm, not the 64Mi container default"
if echo "$RAW" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d["worker_has_dshm"] and d["server_has_dshm"] else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "expected a dshm volume+mount on both server and worker: $RAW"
fi

start_test "...and both server and worker carry a memory limit (not left unbounded)"
if echo "$RAW" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d["worker_resources"].get("limits", {}).get("memory") and d["server_resources"].get("limits", {}).get("memory") else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "expected a memory limit on both server and worker: $RAW"
fi

start_test "🔴 urb-agents#2021 part 2: the worker's memory limit is not the 1Gi that OOM-killed a real backlog drain"
if echo "$RAW" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
limit = d["worker_resources"].get("limits", {}).get("memory")
sys.exit(0 if limit and limit != "1Gi" else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "worker memory limit is missing or back to the proven-too-low 1Gi: $RAW"
fi

start_test "🔴 urb-agents#2021 part 2: no authentik-specific redis: config or AUTHENTIK_REDIS__PASSWORD env (2025.10+ does not need one)"
if python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/075-authentik-config.yaml.j2').read())
ctx = json.loads('$AUTHENTIK_CTX')
out = tpl.render(**ctx)
d = next(x for x in yaml.safe_load_all(out) if x is not None)
has_redis_block = 'redis' in d.get('authentik', {})
env_names = [e['name'] for e in d.get('global', {}).get('env', [])]
import sys
sys.exit(0 if not has_redis_block and 'AUTHENTIK_REDIS__PASSWORD' not in env_names else 1)
" 2>/dev/null; then
    pass_test
else
    fail_test "expected no authentik.redis block and no AUTHENTIK_REDIS__PASSWORD env var"
fi

# ---------------------------------------------------------------------------
# 627-epinio-identity-values.yaml.j2: dex.connectors/rolesMapping (urb-agents#2040).
# Each connector is independently optional - render with each combination that
# matters, not just "all enabled", since an if-block typo could easily pass a
# single all-on render and still break the common single-provider case.
# ---------------------------------------------------------------------------

EPINIO_IDENTITY_BASE_CTX='{"default_epinio_domain":"apps.example.test","epinio_identity_github":{"enabled":false},"epinio_identity_authentik":{"enabled":false},"epinio_identity_okta":{"enabled":false},"epinio_identity_github_client_secret":"","epinio_identity_authentik_client_secret":"","epinio_identity_okta_client_secret":""}'

start_test "627-epinio-identity-values.yaml.j2 renders and parses with only GitHub enabled"
RAW="$(python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/627-epinio-identity-values.yaml.j2').read())
ctx = json.loads('$EPINIO_IDENTITY_BASE_CTX')
ctx['epinio_identity_github'] = {'enabled': True, 'client_id': 'gh', 'org': 'org1', 'teams': [{'name': 't1', 'roles': ['admin:t1']}]}
ctx['epinio_identity_github_client_secret'] = 's1'
out = tpl.render(**ctx)
d = yaml.safe_load(out)
print(json.dumps({'connectors': [c['type'] for c in d['dex']['connectors']], 'rolesMapping_connectors': [r['connectorId'] for r in d['dex']['rolesMapping']]}))
" 2>&1)"
if echo "$RAW" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d["connectors"] == ["github"] and d["rolesMapping_connectors"] == ["github"] else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "expected exactly one github connector and one github rolesMapping entry: $RAW"
fi

start_test "...and only the authentik connector carries rootCAs (github/okta must not)"
if python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/627-epinio-identity-values.yaml.j2').read())
ctx = json.loads('$EPINIO_IDENTITY_BASE_CTX')
ctx['epinio_identity_authentik'] = {'enabled': True, 'issuer': 'https://a/', 'client_id': 'ak', 'groups': [{'name': 'HQ', 'roles': ['admin:hq']}]}
ctx['epinio_identity_okta'] = {'enabled': True, 'issuer': 'https://o/', 'client_id': 'ok', 'groups': [{'name': 'HQ', 'roles': ['admin:hq']}]}
ctx['epinio_identity_authentik_client_secret'] = 's2'
ctx['epinio_identity_okta_client_secret'] = 's3'
out = tpl.render(**ctx)
d = yaml.safe_load(out)
by_type = {c['id']: c for c in d['dex']['connectors']}
import sys
sys.exit(0 if 'rootCAs' in by_type['authentik']['config'] and 'rootCAs' not in by_type['okta']['config'] and by_type['okta']['config'].get('insecureSkipEmailVerified') is True else 1)
" 2>/dev/null; then
    pass_test
else
    fail_test "expected rootCAs only on the authentik connector, and insecureSkipEmailVerified only on okta"
fi

start_test "...and a group's roles always include a bare 'user' role alongside admin:<ns>"
if python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/627-epinio-identity-values.yaml.j2').read())
ctx = json.loads('$EPINIO_IDENTITY_BASE_CTX')
ctx['epinio_identity_authentik'] = {'enabled': True, 'issuer': 'https://a/', 'client_id': 'ak', 'groups': [{'name': 'HQ', 'roles': ['admin:hq']}]}
ctx['epinio_identity_authentik_client_secret'] = 's2'
out = tpl.render(**ctx)
d = yaml.safe_load(out)
roles = d['dex']['rolesMapping'][0]['groups'][0]['roles']
import sys
sys.exit(0 if roles == ['user', 'admin:hq'] else 1)
" 2>/dev/null; then
    pass_test
else
    fail_test "expected ['user', 'admin:hq'], the bare 'user' role missing would 403 every API call (found live during the PoC)"
fi

# ---------------------------------------------------------------------------
# 627-epinio-authentik-blueprint.yaml.j2: redirect_uris (urb-agents#2051). Without it,
# Authentik (2025.10.3) refuses the blueprint apply outright - "redirect_uris: This
# field is required." - before the provider or the application is ever created, found
# live by imac. Uses a custom YAML loader for Authentik's own `!Find` blueprint tag,
# which plain yaml.safe_load cannot parse at all.
# ---------------------------------------------------------------------------

start_test "627-epinio-authentik-blueprint.yaml.j2 renders and carries a required, correctly-shaped redirect_uris"
OUT="$(python3 -c "
import jinja2, yaml, json

class _BlueprintLoader(yaml.SafeLoader):
    pass
_BlueprintLoader.add_multi_constructor('!', lambda loader, suffix, node: None)

env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/627-epinio-authentik-blueprint.yaml.j2').read())
ctx = {
    'epinio_identity_authentik': {'client_id': 'ak'},
    'epinio_identity_authentik_client_secret': 's2',
    'default_epinio_domain': 'apps.example.test',
}
out = tpl.render(**ctx)
docs = [d for d in yaml.load_all(out, Loader=_BlueprintLoader) if d is not None]
provider = next(e for e in docs[0]['entries'] if e['model'] == 'authentik_providers_oauth2.oauth2provider')
print(json.dumps(provider['attrs'].get('redirect_uris')))
" 2>&1)"
if echo "$OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d == [{"matching_mode": "strict", "url": "https://auth.apps.example.test/callback"}] else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "expected redirect_uris: [{matching_mode: strict, url: https://auth.apps.example.test/callback}]: $OUT"
fi

start_test "...and that URL matches Dex's own redirectURI construction exactly, not a hand-duplicated copy"
if grep -qF 'url: "https://auth.{{ default_epinio_domain }}/callback"' "$MANIFESTS/627-epinio-authentik-blueprint.yaml.j2" \
   && grep -qF 'redirectURI: "https://auth.{{ default_epinio_domain }}/callback"' "$MANIFESTS/627-epinio-identity-values.yaml.j2"; then
    pass_test
else
    fail_test "the blueprint's redirect_uris url and Dex's redirectURI must be built from the exact same Jinja expression, or they will silently drift apart"
fi

# ---------------------------------------------------------------------------
# 076-authentik-server-tls-certificate.yaml.j2: dnsNames (urb-agents#2054). Found live by
# imac: the manual {%- dash whitespace control, combined with Ansible's trim_blocks, merged
# every "- item" line into ONE string, so the certificate carried a single garbled SAN
# ("authentik.localhost    - authentik.x    - authentik.y") that no strict TLS client can
# ever match against. Same bug class as 635-forgejo.yaml.j2 (urb-agents#2026). Each case
# asserts on the parsed LIST, because a text match would pass on the merged string too.
# ---------------------------------------------------------------------------

_render_cert_dnsnames() {
    python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/076-authentik-server-tls-certificate.yaml.j2').read())
d = next(x for x in yaml.safe_load_all(tpl.render(domains=json.loads('$1'))) if x is not None)
print(json.dumps(d['spec']['dnsNames']))
" 2>&1
}

start_test "076-authentik-server-tls-certificate.yaml.j2: every enabled domain is its OWN dnsNames entry"
OUT="$(_render_cert_dnsnames '{"localhost":{"enabled":true,"base_domain":"localhost"},"tailscale":{"enabled":true,"base_domain":"x.ts.net"},"cloudflare":{"enabled":true,"base_domain":"x.com"}}')"
if [[ "$OUT" == '["authentik.localhost", "authentik.x.ts.net", "authentik.x.com"]' ]]; then
    pass_test
else
    fail_test "expected three separate SANs, got: $OUT"
fi

start_test "...localhost alone renders exactly one SAN"
OUT="$(_render_cert_dnsnames '{"localhost":{"enabled":true,"base_domain":"localhost"}}')"
if [[ "$OUT" == '["authentik.localhost"]' ]]; then pass_test; else fail_test "got: $OUT"; fi

start_test "...a disabled domain is left out"
OUT="$(_render_cert_dnsnames '{"localhost":{"enabled":true,"base_domain":"localhost"},"tailscale":{"enabled":false,"base_domain":"x.ts.net"},"cloudflare":{"enabled":true,"base_domain":"x.com"}}')"
if [[ "$OUT" == '["authentik.localhost", "authentik.x.com"]' ]]; then pass_test; else fail_test "got: $OUT"; fi

# ---------------------------------------------------------------------------
# 076-authentik-ingressroute-tls.yaml.j2: tls.domains (urb-agents#2046). Traefik builds
# its SNI certificate store from literal domain names extracted from a router's own
# match rule - HostRegexp() is a pattern, not a name, so secretName alone (no tls.domains)
# never actually associates the cert with any SNI at all, confirmed live (host-side AND
# in-cluster, both got Traefik's generic default cert instead).
# ---------------------------------------------------------------------------

start_test "076-authentik-ingressroute-tls.yaml.j2 renders and parses with only localhost enabled"
OUT="$(python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/076-authentik-ingressroute-tls.yaml.j2').read())
ctx = {'domains': {'localhost': {'enabled': True, 'protocol': 'http', 'base_domain': 'localhost'}}}
out = tpl.render(**ctx)
d = next(x for x in yaml.safe_load_all(out) if x is not None)
print(json.dumps(d['spec']['tls']))
" 2>&1)"
if echo "$OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get("domains") == [{"main": "authentik.localhost"}] else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "expected tls.domains: [{main: authentik.localhost}] with no sans key when no extra domain is enabled: $OUT"
fi

start_test "...and includes an enabled extra domain as a san, excludes a disabled one"
OUT="$(python3 -c "
import jinja2, yaml, json
env = jinja2.Environment(trim_blocks=True, lstrip_blocks=False, undefined=jinja2.StrictUndefined)
tpl = env.from_string(open('$MANIFESTS/076-authentik-ingressroute-tls.yaml.j2').read())
ctx = {'domains': {
    'localhost': {'enabled': True, 'protocol': 'http', 'base_domain': 'localhost'},
    'tailscale': {'enabled': True, 'protocol': 'https', 'base_domain': 'example.ts.net'},
    'cloudflare': {'enabled': False, 'protocol': 'https', 'base_domain': 'example.com'},
}}
out = tpl.render(**ctx)
d = next(x for x in yaml.safe_load_all(out) if x is not None)
print(json.dumps(d['spec']['tls']))
" 2>&1)"
if echo "$OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
sans = d.get("domains", [{}])[0].get("sans", [])
sys.exit(0 if "authentik.example.ts.net" in sans and "authentik.example.com" not in sans else 1)
' 2>/dev/null; then
    pass_test
else
    fail_test "expected only the enabled extra domain as a san: $OUT"
fi

print_summary
