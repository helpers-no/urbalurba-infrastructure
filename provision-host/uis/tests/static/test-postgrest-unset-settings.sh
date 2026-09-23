#!/bin/bash
# test-postgrest-unset-settings.sh — a documented "we do not set this" must stay true.
#
# urb-agents#1259. A live consumer fetches the register unpaged and is only
# correct while PostgREST's db-max-rows is unset: set it, and the client gets
# the first N rows with a 200, a well-formed body and no error, so every figure
# derived from it goes quietly low.
#
# 🔴 The trap is an interaction. db-aggregates-enabled is a reasonable request,
# and the standard mitigation for the load it invites is db-max-rows plus a
# statement timeout — which is what a requester will propose. Granting the
# aggregates request with that mitigation silently caps every unpaged consumer.
# Two sensible decisions, made separately, combining into a data bug.
#
# 🔵 THIS TEST EXISTS TO MAKE THE DOCUMENTATION SELF-ENFORCING. postgrest.md
# states that UIS does not set these. A page asserting a fact about the code is
# worthless if the code can change underneath it — so the claim is asserted
# here. Setting either value is allowed; setting it while the page still says
# otherwise is not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/manifests" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
DOC="$REPO/website/docs/services/integration/postgrest.md"

print_test_section "PostgREST settings UIS deliberately leaves unset"

# Where a setting would have to appear to take effect. Not the whole repo: the
# docs and this test both NAME these settings, and a repo-wide grep would match
# its own explanation — the comment-matching lesson from the oauth2 suite.
_SEARCH=("$REPO/manifests" "$REPO/provision-host/uis/lib" "$REPO/ansible")
_PAT='PGRST_DB_MAX_ROWS|db-max-rows|PGRST_DB_AGGREGATES_ENABLED|db-aggregates-enabled|PGRST_OPENAPI_MODE|openapi-mode'

start_test "the search pattern can match a PostgREST setting at all"
# An empty grep is not evidence. Prove the pattern and the paths work together
# before reading zero hits as "not set" — a typo in either would pass silently.
if grep -rhoE 'PGRST_DB_[A-Z_]+' "${_SEARCH[@]}" 2>/dev/null | grep -q 'PGRST_DB_'; then
    pass_test
else
    fail_test "positive control failed: no PGRST_DB_* found in the searched paths, so absence proves nothing"
fi

start_test "UIS does not set db-max-rows, db-aggregates-enabled or openapi-mode"
_hits=$(grep -rniE "$_PAT" "${_SEARCH[@]}" 2>/dev/null || true)
if [[ -z "$_hits" ]]; then
    pass_test
else
    fail_test "one of these is now set — postgrest.md says it is not, and that page must be updated in the same change:
$_hits"
fi

start_test "the page says a repo grep is not sufficient to know the running config"
# 🔴 THIS SUITE PROVES A NECESSARY CONDITION, NOT A SUFFICIENT ONE. It can only
# see this repository. PostgREST also reads settings from pg_roles.rolconfig and
# pg_db_role_setting, which no grep here would ever show — urb-agents#1300,
# where "unset in the manifest, therefore default" was a right conclusion
# reached through a wrong step. A green suite must not read as "the default is
# running".
if grep -qF 'pg_db_role_setting' "$DOC" && grep -qF 'three' "$DOC"; then
    pass_test
else
    fail_test "the page does not warn that in-database settings override the manifest"
fi

start_test "the page says openapi-mode's DEFAULT is the safe value"
# urb-agents#1287: a spec over-advertising writes makes setting openapi-mode
# look like the fix. follow-privileges IS the default, so setting it changes
# nothing — and setting ignore-privileges makes the over-advertisement
# permanent by design. The page has to say which way is which.
if grep -qF 'unset is already the safe value' "$DOC" && grep -qF 'ignore-privileges' "$DOC"; then
    pass_test
else
    fail_test "nothing stops someone 'fixing' this by setting ignore-privileges"
fi

start_test "the page still carries the warning that makes the absence deliberate"
# Deleting the section would also make the check above pass, and would leave the
# next operator with no reason not to set it.
_ok=0
grep -qF 'db-max-rows` is unset' "$DOC" && _ok=$((_ok+1))
grep -qF 'db-aggregates-enabled' "$DOC" && _ok=$((_ok+1))
if [[ "$_ok" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_ok of 2 — the documented reason is gone, so the setting looks free to change"
fi

# ---------------------------------------------------------------------------
# 1.6.142: the published spec named PostgREST's bind address.
#
# urb-agents#1403. Swagger 2.0 builds request URLs from host + schemes +
# basePath, so a spec carrying the listen address sends every generated client,
# every Scalar "try it" and every Redoc reader somewhere unreachable. It blocks
# a public docs page that has already been approved.
# ---------------------------------------------------------------------------

_LIB="$REPO/provision-host/uis/lib/configure-postgrest.sh"
_TPL="$REPO/ansible/playbooks/templates/088-postgrest-config.yml.j2"

start_test "the deployment passes PostgREST a public URI to rewrite the spec with"
if grep -qF 'PGRST_OPENAPI_SERVER_PROXY_URI' "$_TPL"; then
    pass_test
else
    fail_test "nothing sets openapi-server-proxy-uri, so the spec keeps the bind address"
fi

start_test "and it is optional, so a localhost-only install still deploys"
# An install with no public domain stores an empty value. Without optional:true
# the Deployment would fail to start on a missing key — turning a cosmetic spec
# defect into a broken service.
if grep -A6 'PGRST_OPENAPI_SERVER_PROXY_URI' "$_TPL" | grep -qF 'optional: true'; then
    pass_test
else
    fail_test "a missing key would stop the pod rather than leave PostgREST as it was"
fi

start_test "the URI is derived, not asked of the tenant"
# url_prefix plus the installation's public domain already determine the public
# name. A tenant that had to declare it could declare it wrong.
if grep -qF '_pgrst_openapi_proxy_uri' "$_LIB"; then
    pass_test
else
    fail_test "no derivation — every application would have to be told to set it"
fi

start_test "and it is derived at BOTH secret-writing call sites"
# One call site covers a fresh configure and the other a reconfigure. Missing
# either leaves half the installations publishing the wrong host.
if [[ "$(grep -c '_pgrst_create_secret "\$secret_name" "\$db_uri" .* "\$url_prefix"' "$_LIB")" -eq 2 ]]; then
    pass_test
else
    fail_test "only $(grep -c '_pgrst_create_secret "\$secret_name" "\$db_uri" .* "\$url_prefix"' "$_LIB") of 2 call sites pass url_prefix"
fi

start_test "the shipped placeholder domain never reaches the spec"
# BASE_DOMAIN_CLOUDFLARE ships as your-domain.com. Publishing a spec that points
# there would be a second wrong answer wearing a more plausible face.
if grep -qE '^\s*""\|your-domain\.com\|localhost\|\*\.localhost\)' "$_LIB"; then
    pass_test
else
    fail_test "the guard arm is gone — an unconfigured install would publish https://<prefix>.your-domain.com"
fi

# ---------------------------------------------------------------------------
# 1.6.143: 1.6.142's fix could not reach an existing installation.
#
# urb-agents#1411, measured on a real host: pull to 1.6.142, configure, deploy —
# every step exit 0, and the secret still had two keys. `configure` dispatches
# to `no-op` when roles exist, the secret exists and the schemas match, and that
# path RETURNS BEFORE the phase that writes the secret.
#
# 🔴 The block's own comment already described this bug in another form: the
# same early return made the documented remediation for the FOR ROLE defect a
# no-op on urb-agents#330. `no-op` means THERE IS NO SQL TO APPLY; it has been
# read as "nothing to do at all", and everything added after it inherits that.
# ---------------------------------------------------------------------------

start_test "the no-op path syncs the published API address before returning"
if grep -B25 "already configured for '\$app_name' with schemas" "$_LIB" | grep -qF '_pgrst_sync_openapi_uri'; then
    pass_test
else
    fail_test "a steady-state install can never receive the fix — and re-running configure reports success"
fi

_sync_fn() { awk '/^_pgrst_sync_openapi_uri\(\) \{/,/^\}/' "$_LIB"; }

start_test "it patches one key rather than rewriting the secret"
# _pgrst_create_secret would rewrite PGRST_DB_URI, which on this path is the
# live credential. Merge-patching leaves the other keys alone.
if _sync_fn | grep -qF -- '--type=merge'; then
    pass_test
else
    fail_test "the sync rewrites the whole secret and would touch the live database URI"
fi

start_test "an empty derivation CLEARS a stale address rather than skipping"
# If the public domain is removed, the spec must stop advertising it. Skipping
# on empty would leave the old host published forever.
if _sync_fn | grep -qF 'Cleared the published API address'; then
    pass_test
else
    fail_test "removing the public domain would leave the old address in the spec"
fi

start_test "a sync failure warns and does not discard the grants that converged"
# The grants on this path DID apply. Failing the command over the spec would
# throw away work that succeeded.
if grep -A6 '_pgrst_sync_openapi_uri "\$secret_name"' "$_LIB" | grep -qF 'log_warn'; then
    pass_test
else
    fail_test "a spec-sync failure aborts a configure whose grants already converged"
fi

print_summary
