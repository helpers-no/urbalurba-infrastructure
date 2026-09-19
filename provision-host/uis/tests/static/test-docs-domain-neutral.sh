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

print_summary
