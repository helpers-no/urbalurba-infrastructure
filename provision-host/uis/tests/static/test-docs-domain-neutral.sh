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

# ---------------------------------------------------------------------------
# The Cache Rule's third invisible failure: it reads as a violated control.
#
# urb-agents#1448 — a consumer and an agent both saw `cf-cache-status: HIT`
# alongside `cache-control: no-store` and reasonably concluded Cloudflare was
# ignoring the origin. It is not: PostgREST sends no Cache-Control at all, and
# the no-store is setting 3 of this very rule talking to the BROWSER.
#
# 🔴 Two things must be on the page. That the pair is not a violation — or the
# next reader files the same defect. And that setting 2 means what it says, so
# the rule is only safe while the hostname is public: an origin no-store WILL
# be ignored, which is the control you would reach for the day it matters.
# ---------------------------------------------------------------------------

start_test "the HIT + no-store pair is explained as one rule, not a violation"
_n=0
grep -qF 'cf-cache-status: HIT' "$_CF" && _n=$((_n+1))
grep -qF "Cloudflare's own instruction to the browser" "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — the header pair keeps reading as an ignored no-store"
fi

start_test "the rule says an origin no-store will be ignored, and what that costs"
_n=0
grep -qF 'correct only while everything behind the hostname is public' "$_CF" && _n=$((_n+1))
grep -qF 'handed to somebody else' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — 'ignore cache-control' reads as tuning, not a precondition"
fi

start_test "it refuses the rule on a gated hostname"
if grep -qF 'Never apply this rule to a hostname behind' "$_CF"; then
    pass_test
else
    fail_test "nothing stops this rule landing on an oauth2-proxy hostname"
fi

start_test "both pages tell a measurer to bust the cache and verify the miss"
# The Cloudflare page owns the rule; the PostgREST page is where someone
# timing a slow query actually looks. #1448 cost an hour because neither said it.
_PGR="$REPO/website/docs/services/integration/postgrest.md"
_n=0
grep -qF 'cf-cache-status' "$_CF" && _n=$((_n+1))
grep -qF 'cf-cache-status' "$_PGR" && _n=$((_n+1))
grep -qF 'is not a measurement of the origin' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass_test
else
    fail_test "only $_n of 3 — a timing through the edge still reads as a database timing"
fi

# ---------------------------------------------------------------------------
# The bullet that asks you to write down a limitation rather than remove one.
#
# Røde Kors brief, Priority 6: "Note in docs what the uptime expectation is
# (home-hosted for now)." ops-dev: "the one most likely to be skipped."
#
# A tunnel makes a machine reachable, and a public hostname returning 200 makes
# it look like infrastructure. A consumer cannot tell from outside whether it is
# backed by a region or by a Mac on a shelf, so the page has to say.
# ---------------------------------------------------------------------------

start_test "the tunnel page states an availability expectation, not just reachability"
_n=0
grep -qF 'No uptime guarantee, no SLA, no on-call' "$_CF" && _n=$((_n+1))
grep -qF 'does nothing to make it' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — a 200 from a public hostname keeps reading as infrastructure"
fi

start_test "it names what is singular, so the claim is checkable rather than a mood"
_n=0
grep -qF 'a restart is a gap, not a failover' "$_CF" && _n=$((_n+1))
grep -qF 'single home internet connection' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — 'best effort' with nothing behind it"
fi

start_test "it says which outages the cache hides and which it does not"
# The dangerous half: a cached repeat can make an outage invisible, while the
# person doing new work sees it immediately. Stating only the first is worse
# than stating neither.
if grep -qF 'protects repetition, not exploration' "$_CF"; then
    pass_test
else
    fail_test "the cache reads as outage protection it does not provide"
fi

start_test "it says a deployed watchdog with no monitor is not monitoring"
if grep -qF 'A monitor has to actually exist' "$_CF"; then
    pass_test
else
    fail_test "deploying Uptime Kuma reads as done"
fi

# ---------------------------------------------------------------------------
# urb-agents#1542 — two merged changes that contradict each other.
#
# Atlas's published API description says `/openapi.json` "returns 404 today".
# The alias shipped in 1.6.151 makes it 200. Whichever lands second silently
# falsifies the first, and the word "today" had no mechanism behind it.
#
# 🔴 The ordering is the decidable part and it is NOT symmetric: text-first
# leaves a description that merely stops promising a working path; alias-first
# leaves an API actively telling machines a working path is broken — and the
# edge cache extends that window past the correction.
# ---------------------------------------------------------------------------

_PGR="$REPO/website/docs/services/integration/postgrest.md"

start_test "deploying the alias is documented as falsifying published text"
_n=0
grep -qF 'Change the text first, then deploy' "$_PGR" && _n=$((_n+1))
grep -qF 'can never be simultaneous' "$_PGR" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — the coupling stays unwritten, which is why it was missed"
fi

start_test "it says why the two orders are not interchangeable"
if grep -qF 'actively misdirects' "$_PGR"; then
    pass_test
else
    fail_test "'do them together' is not actionable — the cache makes it impossible"
fi

start_test "a documented limitation is told to carry its expiry condition"
if grep -qF 'a claim with an expiry' "$_PGR"; then
    pass_test
else
    fail_test "the next 'today' ships with no trigger behind it either"
fi

# ⚠️ Both pages prescribe the same cache-bust, so both must carry the trap.
# An invented parameter is parsed as a column filter: PGRST100, a 400 from a
# healthy endpoint, which reads as a broken API rather than a bad buster.
start_test "both pages warn that the cache-bust parameter must be a real one"
_n=0
grep -qF 'PGRST100' "$_PGR" && _n=$((_n+1))
grep -qF 'PGRST100' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — a reader follows the advice and gets a 400 they misread"
fi

# ---------------------------------------------------------------------------
# urb-agents#1544 — three more deployed changes on a live zone.
#
# 🔴 A Managed Challenge returns 403, the SAME status as a block, and only
# `cf-mitigated: challenge` tells them apart. Without it a reader goes hunting
# for a blocking rule that does not exist.
#
# 🔴 And Bot Fight Mode is the switch everyone reaches for on a scanned zone.
# It is zone-wide and unscopeable, so on a zone that also serves a scripted
# open-data API it UNDOES the Configuration Rule this page spends a section
# explaining. Naming the conflict is the point; a page that lists the remedy
# without it invites someone to break the API fixing the scanners.
# ---------------------------------------------------------------------------

start_test "a challenge is distinguished from a block by cf-mitigated"
_n=0
grep -qF 'cf-mitigated: challenge' "$_CF" && _n=$((_n+1))
grep -qF 'the same status as a block' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — a 403 from a challenge reads as a block"
fi

start_test "Bot Fight Mode is named as conflicting with the scripted-client fix"
_n=0
grep -qF 'Bot Fight Mode' "$_CF" && _n=$((_n+1))
grep -qF 're-breaks scripted clients' "$_CF" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — the obvious remedy silently undoes the BIC exception"
fi

start_test "the Link header is documented as reaching edge-blocked responses"
# The row that justifies putting it at the edge at all: it arrives on
# refusals the origin never sees, which is where a reader has no other clue.
if grep -qF 'responses the origin never sees' "$_CF"; then
    pass_test
else
    fail_test "the edge placement reads as convenience rather than reach"
fi

start_test "a Link target is required to resolve before being set"
if grep -qF 'aimed at a dead host is worse than no header' "$_CF"; then
    pass_test
else
    fail_test "an authoritative pointer to nothing, on exactly the blocked responses"
fi

start_test "the Edge TTL is given as a cadence argument, not a number"
if grep -qF "from how often the data actually changes" "$_CF"; then
    pass_test
else
    fail_test "a copied number outlives the reasoning that chose it"
fi

start_test "a sampled figure is flagged as weaker than a preview estimate"
if grep -qF 'Know which of your figures is sampled' "$_CF"; then
    pass_test
else
    fail_test "a joined-by-hand number gets quoted as measurement"
fi

print_summary
