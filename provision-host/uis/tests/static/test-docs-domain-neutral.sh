#!/bin/bash
# test-docs-domain-neutral.sh — the networking docs must not name one apex.
#
# Terje, 2026-09-19, on the Cloudflare tunnel page: "remove all references to a
# domain there. it must work with any domain."
#
# The page had 15 occurrences of one apex — in the DNS table, the published
# hostname routes, the curl examples and the wildcard explanation. A reader with
# a different domain had to translate every one of them, and the page read as
# instructions for someone else's installation.
#
# 🔵 SCOPED TO THE NETWORKING DOCS DELIBERATELY. Plans and investigations under
# ai-developer/ record what was measured on real hosts, and a measurement names
# the host it was taken on. Rewriting those would make the record false. This
# asserts the OPERATOR-FACING pages, which are instructions rather than history.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/website" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
DOCS="$REPO/website/docs/networking"

print_test_section "networking docs name no particular domain"

start_test "the networking docs directory exists"
if [[ -d "$DOCS" ]]; then
    pass_test
else
    fail_test "no $DOCS — every check below would vacuously pass"
fi

# A concrete apex: two or more labels where the last is a known TLD we use.
# Deliberately narrow. A broad "any hostname" pattern would match
# traefik.kube-system.svc.cluster.local and every example.com in the prose.
_APEX='urbalurba\.(no|com)|sovereignsky\.no'

start_test "the apex pattern can match anything at all"
# An empty grep is not evidence of absence. Prove the pattern works before
# reading zero hits as a pass.
if printf '%s\n' "see https://urbalurba.no/x" | grep -qE "$_APEX"; then
    pass_test
else
    fail_test "positive control failed: the pattern matches nothing, so its absence proves nothing"
fi

start_test "no operator-facing networking page names a specific apex"
_hits=$(grep -rnE "$_APEX" "$DOCS" 2>/dev/null | grep -v 'urbalurba-secrets' || true)
if [[ -z "$_hits" ]]; then
    pass_test
else
    fail_test "a domain is named in instructions a reader must translate:
$_hits"
fi

start_test "the placeholder these pages use is present, so the rule was applied rather than the text deleted"
# Removing the examples would also make the grep pass. The pages must still SHOW
# the shape a reader substitutes into.
if grep -rqF '<your-domain>' "$DOCS"; then
    pass_test
else
    fail_test "no <your-domain> placeholder — the domain references were removed, not generalised"
fi

# ---------------------------------------------------------------------------
# api- and api. are reserved prefixes, and the warning must survive edits.
#
# A live Cloudflare Transform Rule sets Access-Control-Allow-Origin: * on every
# hostname starting with api- or api., so NAMING a service api-something grants
# any website's JavaScript read access to its responses. That is a security
# decision taken at the moment a service is named, by someone who will not be
# reading the CORS page — so it is recorded in the service schema too, and both
# copies must keep saying it.
# ---------------------------------------------------------------------------

_SCHEMA="$REPO/provision-host/uis/schemas/service.schema.json"

start_test "the service schema warns that api- is a reserved prefix"
if [[ -f "$_SCHEMA" ]] && grep -qF 'RESERVED PREFIXES' "$_SCHEMA"; then
    pass_test
else
    fail_test "the id field does not mention the prefix — a service author sees nothing"
fi

start_test "the schema is still valid JSON after that description"
# A long description with quotes and a path is exactly where JSON gets broken.
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$_SCHEMA" 2>/dev/null; then
    pass_test
else
    fail_test "service.schema.json does not parse"
fi

start_test "the networking docs pin the exact prefixes, not a loose 'api'"
# starts_with(http.host, "api") would also match apidocs. and apikeys., each of
# which would silently receive a wildcard CORS header. The precise pair is the
# whole point, so assert the pair rather than the word.
if grep -rqF 'starts_with(http.host, "api-") or starts_with(http.host, "api.")' "$DOCS"; then
    pass_test
else
    fail_test "the documented expression is not the precise two-prefix form"
fi

start_test "the docs state both halves of the risk"
# "credentials are blocked so it is fine" is wrong, and "any api- service leaks"
# is alarmist. Both sentences have to be present or the warning misleads.
_ok=0
grep -rqF 'cannot be combined with credentials' "$DOCS" && _ok=$((_ok+1))
grep -rqiF 'private that needs no credentials' "$DOCS" && _ok=$((_ok+1))
if [[ "$_ok" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_ok of 2 halves present — the risk is stated as safer or scarier than it is"
fi

# ---------------------------------------------------------------------------
# The Cloudflare 403 mechanisms, and the one that cannot be fixed the obvious way.
#
# urb-agents#1437, measured by Terje against the live zone. Three separate
# comments — all mine — sent readers to Security → WAF → Managed rules, where
# there is nothing relevant. The 403s come from Browser Integrity Check and the
# AI bot policies, on two other screens.
#
# 🔴 And the remedy I proposed was not merely mislocated: BIC is ZONE-WIDE.
# There is no per-hostname exception on the setting, so "add an exception for
# this hostname" describes something that does not exist. A Configuration Rule
# is the only per-hostname mechanism.
# ---------------------------------------------------------------------------

_CF="$REPO/website/docs/networking/cloudflare-setup.md"

start_test "the page says WAF is usually the wrong screen for these 403s"
if grep -qF 'wrong place to look' "$_CF"; then
    pass_test
else
    fail_test "a reader still starts at the screen where three reports found nothing"
fi

start_test "it gives the discriminator, not just the conclusion"
# "check somewhere else" is not actionable. The response body is what tells
# the three mechanisms apart, and it is the only thing a reader has.
_n=0
grep -qF 'error code: 1010' "$_CF" && _n=$((_n+1))
grep -qF 'Your request was blocked' "$_CF" && _n=$((_n+1))
grep -qF '1020' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass_test
else
    fail_test "only $_n of 3 response bodies named — the reader cannot tell which mechanism fired"
fi

start_test "it records that BIC is zone-wide, so the obvious remedy is unavailable"
if grep -qF 'no per-hostname exception' "$_CF"; then
    pass_test
else
    fail_test "someone will propose a per-hostname BIC exception again — it does not exist"
fi

start_test "the mapping is marked as inference rather than measurement"
# Terje flagged it himself: consistent with every observation, but the
# Security Events log is the authority and was not opened. A table that looks
# measured and is not is how a strong guess becomes folklore.
if grep -qF 'inference, not measurement' "$_CF"; then
    pass_test
else
    fail_test "the body-to-mechanism table reads as established fact"
fi

start_test "blocking Training is distinguished from blocking AI tools"
# "we block GPTBot" reads as "AI tools cannot reach us", and that is false:
# a live fetch goes out as Claude-User / ChatGPT-User, which is the Agent
# category and allowed.
if grep -qF 'Claude-User' "$_CF" && grep -qF 'does not block live fetches' "$_CF"; then
    pass_test
else
    fail_test "the page leaves 'Training disallowed' reading as 'AI blocked'"
fi

start_test "it says a Cache Rule is required rather than an optimisation"
# PostgREST emits no Cache-Control, ETag or Last-Modified, so without an Edge
# TTL override Cloudflare caches nothing AND conditional requests cannot help.
if grep -qF 'required to get any caching at all' "$_CF"; then
    pass_test
else
    fail_test "caching reads as tuning, and a measured 0.01% cached stays unexplained"
fi

# ---------------------------------------------------------------------------
# The Cache Rule's two invisible failures.
#
# urb-agents#1437, deployed and measured: a Cache Rule can be Active, correctly
# scoped, and cache exactly nothing — because Cloudflare's default Edge TTL
# defers to a `Cache-Control` header that PostgREST never sends. And fixing
# that exposes the second one: the zone's default Browser Cache TTL of 4 hours
# starts applying, and browser caches cannot be purged.
#
# 🔴 Neither is visible from the rules list. Both need `curl -D -`. A doc that
# says "add a Cache Rule" and stops produces one of the two failures.
# ---------------------------------------------------------------------------

start_test "the Cache Rule is documented as three settings, not one"
if grep -qF 'three settings, and two of them fail invisibly' "$_CF"; then
    pass_test
else
    fail_test "'add a Cache Rule' on its own yields a rule that caches nothing"
fi

start_test "the Edge TTL trap names the default that causes it"
# "set Edge TTL" is not enough: the reader must know the DEFAULT is the failure,
# and why — PostgREST sends no Cache-Control for it to defer to.
_n=0
grep -qF 'Ignore cache-control header' "$_CF" && _n=$((_n+1))
grep -qF 'silent no-op' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — the reader can set Edge TTL and still cache nothing"
fi

start_test "the Browser TTL trap says purge does not reach browsers"
# This is the one that turns a fix into a worse problem: 4 hours of staleness
# that no purge can clear, on an API people are building against.
if grep -qF 'does not purge browser caches' "$_CF"; then
    pass_test
else
    fail_test "enabling caching would introduce unpurgeable staleness with no warning"
fi

start_test "turning off a security setting comes with a blast-radius check"
# A Configuration Rule disabling BIC is a security control being switched off.
# Scoping is the entire safety argument, so the doc has to say prove it.
if grep -qF 'entire safety argument' "$_CF"; then
    pass_test
else
    fail_test "BIC can be disabled with nothing telling the operator to verify the scope"
fi

print_summary
