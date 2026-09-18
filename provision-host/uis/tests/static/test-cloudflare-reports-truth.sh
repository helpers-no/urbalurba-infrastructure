#!/bin/bash
# test-cloudflare-reports-truth.sh — the Cloudflare commands must not report success
# for a tunnel that is not serving traffic.
#
# WHY THIS EXISTS. On 2026-09-18 a tunnel was deployed to a test cluster whose dashboard
# routes pointed at `traefik.default.svc.cluster.local:80`. Traefik runs in
# kube-system, so every request returned 502. Three commands reported success
# anyway:
#
#   uis network up      printed "✓ Cloudflare tunnel is up" after the end-to-end
#                       probe had failed twelve consecutive times
#   uis network status   printed "1/1 cloudflared running" as its verdict
#   uis network verify   printed "DNS Token: configured" for an untouched placeholder
#
# None of these scripts had any test coverage, which is why all three survived a
# release. The failure was also not novel: PLAN-012 root-caused this identical
# wrong-namespace bug once before. The information needed to diagnose it was in
# the connector's own log the whole time, as `originService=`.
#
# So these tests pin the reporting, not the deployment: given a connector log that
# shows an origin failure, the tooling must say so and must name the origin.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/networking/cloudflare/scripts" ]]; then
    CF_SCRIPTS="/mnt/urbalurbadisk/networking/cloudflare/scripts"
    PLAYBOOKS="/mnt/urbalurbadisk/ansible/playbooks"
else
    CF_SCRIPTS="$(cd "$SCRIPT_DIR/../../../../networking/cloudflare/scripts" && pwd)"
    PLAYBOOKS="$(cd "$SCRIPT_DIR/../../../../ansible/playbooks" && pwd)"
fi

STATUS_SH="$CF_SCRIPTS/status.sh"
UP_SH="$CF_SCRIPTS/up.sh"
VERIFY_PB="$PLAYBOOKS/822-verify-cloudflare.yml"
DEPLOY_PB="$PLAYBOOKS/820-deploy-network-cloudflare-tunnel.yml"

print_test_section "Cloudflare reporting-truth Tests"

# ---------------------------------------------------------------------------
# _origin_failure: the guard that names the misconfigured origin.
#
# The broken fixture is the verbatim log from that incident. The healthy
# fixture is the other side of the pair — without it, a function that always
# reported a failure would pass.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/broken.log" <<'EOF'
2026-09-18T04:25:28Z ERR  error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from cloudflared: dial tcp: lookup traefik.default.svc.cluster.local on 10.43.0.10:53: no such host" connIndex=1 event=1 ingressRule=0 originService=http://traefik.default.svc.cluster.local:80
2026-09-18T04:25:29Z ERR  error="Unable to reach the origin service." connIndex=1 event=1 ingressRule=1 originService=http://traefik.default.svc.cluster.local:80
EOF

cat > "$TMP/healthy.log" <<'EOF'
2026-09-18T05:00:01Z INF Registered tunnel connection connIndex=0 connection=abc location=osl protocol=quic
2026-09-18T05:00:02Z INF Registered tunnel connection connIndex=1 connection=def location=arn protocol=quic
EOF

# Run the real function from status.sh with _kubectl stubbed to serve a fixture.
_run_origin_failure() {
    local fixture="$1"
    bash -c '
        set -euo pipefail
        _kubectl() { cat "'"$fixture"'"; }
        '"$(sed -n '/^_origin_failure() {/,/^}/p' "$STATUS_SH")"'
        _origin_failure
    ' 2>/dev/null
}

start_test "status.sh defines _origin_failure"
if grep -q '^_origin_failure() {' "$STATUS_SH"; then
    pass_test
else
    fail_test "no _origin_failure in status.sh — the origin guard is gone"
fi

start_test "_origin_failure names the bad origin from a failing connector log"
got="$(_run_origin_failure "$TMP/broken.log")"
if [[ "$got" == *"traefik.default.svc.cluster.local:80"* ]]; then
    pass_test
else
    fail_test "expected the reported origin, got: [$got]"
fi

start_test "_origin_failure reports nothing for a healthy connector log"
got="$(_run_origin_failure "$TMP/healthy.log")"
if [[ -z "$got" ]]; then
    pass_test
else
    fail_test "false positive on a healthy log: [$got]"
fi

start_test "_origin_failure deduplicates a repeated origin"
got="$(_run_origin_failure "$TMP/broken.log")"
if [[ "$(printf '%s' "$got" | grep -c 'traefik.default')" -eq 1 ]]; then
    pass_test
else
    fail_test "origin repeated once per log line: [$got]"
fi

# ---------------------------------------------------------------------------
# status.sh must not call an empty token "set".
# ---------------------------------------------------------------------------
start_test "status.sh does not print 'set' for an empty token"
if grep -q 'Token:     set (\${CLOUDFLARE_TUNNEL_TOKEN:+' "$STATUS_SH"; then
    fail_test "\${VAR:+...} form is back — an empty token renders as 'set ()'"
else
    pass_test
fi

start_test "status.sh reports a degraded tunnel distinctly in --summary"
if grep -q "printf 'degraded" "$STATUS_SH"; then
    pass_test
else
    fail_test "no 'degraded' summary state — 'uis network list' will call a dead tunnel running"
fi

# ---------------------------------------------------------------------------
# up.sh must branch on the playbook's exit status.
# ---------------------------------------------------------------------------
start_test "up.sh captures the playbook exit status instead of assuming success"
if grep -q 'PLAYBOOK_RC=\$?' "$UP_SH"; then
    pass_test
else
    fail_test "up.sh does not capture the playbook rc — the success banner is unconditional again"
fi

start_test "up.sh exits non-zero when the playbook failed"
if grep -q 'exit "\$PLAYBOOK_RC"' "$UP_SH"; then
    pass_test
else
    fail_test "up.sh swallows a failed deploy"
fi

# ---------------------------------------------------------------------------
# 820 must fail, and diagnose, when the probe fails.
# ---------------------------------------------------------------------------
start_test "820 classifies the probe outcome rather than collapsing it"
if grep -q 'probe_passed:' "$DEPLOY_PB" && grep -q 'probe_skipped:' "$DEPLOY_PB"; then
    pass_test
else
    fail_test "820 no longer distinguishes 'nothing to probe' from 'probe failed'"
fi

start_test "820 no longer claims SKIP when the probe actually failed"
# Match only non-comment lines: the rationale for removing this message quotes
# the message, and a test that cannot tell code from commentary is worthless.
if grep -v '^\s*#' "$DEPLOY_PB" | grep -q 'SKIP - domain not configured or test failed'; then
    fail_test "the conflated SKIP message is back"
else
    pass_test
fi

start_test "820 reads back the origin the connector reports"
if grep -q 'originService=' "$DEPLOY_PB"; then
    pass_test
else
    fail_test "820 does not surface originService — the operator must go find it"
fi

start_test "820 fails the play when the tunnel is not serving"
if grep -q 'Fail because the tunnel is deployed but not serving' "$DEPLOY_PB"; then
    pass_test
else
    fail_test "820 exits 0 on a tunnel that cannot serve traffic"
fi

# ---------------------------------------------------------------------------
# 822-verify must not call a placeholder DNS token "configured".
# ---------------------------------------------------------------------------
start_test "822-verify treats the DNS token placeholder as not set"
if grep -q "your-cloudflare-dns-token' in cf_dns_token" "$VERIFY_PB"; then
    pass_test
else
    fail_test "placeholder detection missing — an untouched DNS token reports as configured"
fi

start_test "822-verify bounds the log window by time"
if grep -q 'since_seconds:' "$VERIFY_PB"; then
    pass_test
else
    fail_test "no since_seconds — stale errors keep the log WARN on forever"
fi

start_test "822-verify does not print the constant token prefix as a fingerprint"
if grep -q "cf_tunnel_token\[:8\]" "$VERIFY_PB"; then
    fail_test "eyJhIjoi... is base64 of {\"a\":\" and identical for every token"
else
    pass_test
fi

print_summary
