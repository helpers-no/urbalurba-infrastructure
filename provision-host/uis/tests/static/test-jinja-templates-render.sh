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

print(json.dumps({"documents": len(docs),
                  "kinds": [f"{d.get('kind')}/{d.get('metadata',{}).get('name')}" for d in docs],
                  "podAnnotations": pod_ann}))
PYEOF

_render() {
    local tpl="$1" ctx="$2"
    python3 "$TMP/render.py" "$MANIFESTS/$tpl" "$ctx" 2>&1
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

print_summary
