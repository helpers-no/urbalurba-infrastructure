#!/bin/bash
# test-registry-cache-read.sh — one registry read per command, and an age we
# either measured or refuse to state.
#
# 🔴 1.6.59 made a cached registry read visible. imac then read the OUTPUT and
# found three things the change itself had introduced or left standing (#719):
#
#   1. `Registry: cached…` printed TWICE per invocation, because every command
#      fetches and then its reader fetches again. On a cold cache that is two
#      network round trips for one command.
#   2. The staleness warning fired at 0 minutes — immediately after `--refresh`,
#      about the one copy known to be current. A warning that cries wolf on
#      fresh data is one people learn to skip, which is the single outcome this
#      fix cannot afford.
#   3. `stat ... || echo 0` turned a failed stat into an age of ~29 million
#      minutes, reported as confidently as a real measurement.
#
# ⚠️ The functions are EXTRACTED AND EXECUTED against a counting curl stub. A
# grep would pass against a memoisation that never fires — and the defect being
# fixed here is precisely a guard that was never exercised.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)/template.sh"

print_test_section "Registry cache: read once, and say what we know"

start_test "the library defines the registry read path"
_fns="$(sed -n '/^_registry_cache_path() {/,/^}/p' "$LIB")
$(sed -n '/^_registry_is_cacheable() {/,/^}/p' "$LIB")
$(sed -n '/^_registry_cache_age_sec() {/,/^}/p' "$LIB")
$(sed -n '/^_registry_cache_fresh() {/,/^}/p' "$LIB")
$(sed -n '/^_registry_staleness_hint() {/,/^}/p' "$LIB")
$(sed -n '/^_fetch_registry() {/,/^}/p' "$LIB")
$(sed -n '/^_fetch_registry_uncached() {/,/^}/p' "$LIB")"
if [[ -n "$_fns" ]] && grep -q '_fetch_registry_uncached' <<<"$_fns"; then
    pass_test
else
    fail_test "registry functions not found in $LIB"; print_summary; exit $?
fi

log_error() { echo "ERROR: $*" >&2; }
eval "$_fns"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
REGISTRY_URL_PRIMARY="https://example.invalid/registry.json"
REGISTRY_URL_FALLBACK="https://example.invalid/fallback.json"
REGISTRY_CACHE_TTL=3600

# CURL_N counts network reads; CURL_RC decides whether they succeed.
curl() {
    CURL_N=$(( CURL_N + 1 ))
    local out=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == "-o" ]] && { out="$2"; shift 2; continue; }
        shift
    done
    if [[ "${CURL_RC:-0}" -eq 0 ]]; then
        [[ -n "$out" ]] && echo '{"templates":[],"categories":[]}' > "$out"
        return 0
    fi
    return 22
}

reset_state() {
    CURL_N=0; CURL_RC=0
    unset _REGISTRY_FETCHED _REGISTRY_FETCH_RC
    unset REGISTRY_FROM_CACHE REGISTRY_CACHE_AGE_MIN REGISTRY_CACHE_AGE_SEC
    REGISTRY_REFRESH=false
    REGISTRY_CACHE="$TMPD/registry.json"
    rm -f "$REGISTRY_CACHE"
}

# ── positive control: the stub counts, so a "0 fetches" result means something ──
start_test "control: the curl stub counts a real read"
reset_state
curl -sfL "$REGISTRY_URL_PRIMARY" -o "$REGISTRY_CACHE" >/dev/null 2>&1
[[ "$CURL_N" -eq 1 && -s "$REGISTRY_CACHE" ]] && pass_test || fail_test "stub did not record a fetch (n=$CURL_N)"

# ── 1. one read per command ────────────────────────────────────────────────────
start_test "🔴 a cold cache is fetched ONCE even though two readers ask"
reset_state
_fetch_registry >/dev/null 2>&1   # what cmd_template_list does
_fetch_registry >/dev/null 2>&1   # what _list_uis_templates then does
[[ "$CURL_N" -eq 1 ]] && pass_test || fail_test "expected 1 network read, got $CURL_N"

start_test "🔴 the 'Registry:' line is printed once, not twice"
reset_state
touch -d '@'"$(( $(date +%s) - 600 ))" "$TMPD/warm.json" 2>/dev/null || touch "$TMPD/warm.json"
REGISTRY_CACHE="$TMPD/warm.json"; echo '{}' > "$REGISTRY_CACHE"
touch -d "@$(( $(date +%s) - 600 ))" "$REGISTRY_CACHE"
_err=$( { _fetch_registry; _fetch_registry; } 2>&1 >/dev/null )
_n=$(printf '%s\n' "$_err" | grep -c '^Registry: cached')
[[ "$_n" -eq 1 ]] && pass_test || fail_test "expected 1 'Registry: cached' line, got $_n"

start_test "a memoised read still reports the same result to the second caller"
reset_state
_fetch_registry >/dev/null 2>&1
_fetch_registry >/dev/null 2>&1 && pass_test || fail_test "second call must return the first call's rc"

start_test "🔴 a FAILED fetch is memoised — one command, one attempt"
reset_state
CURL_RC=22
_fetch_registry >/dev/null 2>&1; _rc1=$?
_fetch_registry >/dev/null 2>&1; _rc2=$?
# primary + fallback = 2 attempts on the first call, none on the second
[[ "$_rc1" -ne 0 && "$_rc2" -ne 0 && "$CURL_N" -eq 2 ]] && pass_test \
    || fail_test "rc1=$_rc1 rc2=$_rc2 fetches=$CURL_N (expected non-zero, non-zero, 2)"

# ── 2. the age we report is the age we measured ────────────────────────────────
start_test "a fresh cache reports its age in seconds, not '0 min'"
reset_state
REGISTRY_CACHE="$TMPD/fresh.json"; echo '{}' > "$REGISTRY_CACHE"
_err=$(_fetch_registry 2>&1 >/dev/null)
grep -q 's ago — fresh' <<<"$_err" && pass_test || fail_test "got: $_err"

start_test "an hour-old-ish cache reports minutes and offers --refresh"
reset_state
REGISTRY_CACHE="$TMPD/old.json"; echo '{}' > "$REGISTRY_CACHE"
touch -d "@$(( $(date +%s) - 1800 ))" "$REGISTRY_CACHE"
_err=$(_fetch_registry 2>&1 >/dev/null)
grep -q '30 min ago (--refresh to re-read)' <<<"$_err" && pass_test || fail_test "got: $_err"

start_test "🔴 the staleness hint is SILENT on a copy read seconds ago"
reset_state
REGISTRY_CACHE="$TMPD/fresh2.json"; echo '{}' > "$REGISTRY_CACHE"
_fetch_registry >/dev/null 2>&1
_hint=$(_registry_staleness_hint "atlas" 2>&1)
[[ -z "$_hint" ]] && pass_test || fail_test "hint fired on a fresh copy: $_hint"

start_test "the staleness hint DOES fire on an old copy"
reset_state
REGISTRY_CACHE="$TMPD/old2.json"; echo '{}' > "$REGISTRY_CACHE"
touch -d "@$(( $(date +%s) - 1800 ))" "$REGISTRY_CACHE"
_fetch_registry >/dev/null 2>&1
_hint=$(_registry_staleness_hint "atlas" 2>&1)
grep -q '30-minute-old cache' <<<"$_hint" && pass_test || fail_test "hint did not fire: $_hint"

start_test "the hint names the id it was GIVEN, not one from the caller's scope"
template_id="wrong-id-from-enclosing-scope"
_hint=$(_registry_staleness_hint "atlas" 2>&1)
if grep -q 'uis template install atlas --refresh' <<<"$_hint" && ! grep -q 'wrong-id' <<<"$_hint"; then
    pass_test
else
    fail_test "got: $_hint"
fi
unset template_id

start_test "the hint is silent when the answer came from the NETWORK"
reset_state
_fetch_registry >/dev/null 2>&1
_hint=$(_registry_staleness_hint "atlas" 2>&1)
[[ -z "$_hint" ]] && pass_test || fail_test "hint fired on a network read: $_hint"

# ── 3. an age we cannot measure is not an age ──────────────────────────────────
start_test "🔴 a failed stat is not reported as a 29-million-minute-old cache"
reset_state
REGISTRY_CACHE="$TMPD/unstattable.json"; echo '{}' > "$REGISTRY_CACHE"
stat() { return 1; }
_age_rc=0
_registry_cache_age_sec "$REGISTRY_CACHE" >/dev/null 2>&1 || _age_rc=$?
_err=$(_fetch_registry 2>&1 >/dev/null)
unset -f stat
if [[ "$_age_rc" -ne 0 ]] && ! grep -qE '[0-9]{6,} min ago' <<<"$_err"; then
    pass_test
else
    fail_test "age rc=$_age_rc, output: $_err"
fi

start_test "an unmeasurable cache is RE-READ rather than trusted"
reset_state
REGISTRY_CACHE="$TMPD/unstattable2.json"; echo '{}' > "$REGISTRY_CACHE"
stat() { return 1; }
_fetch_registry >/dev/null 2>&1
unset -f stat
[[ "$CURL_N" -eq 1 ]] && pass_test || fail_test "expected a re-read (1 fetch), got $CURL_N"

start_test "a non-numeric mtime is refused too"
stat() { echo "not-a-number"; }
_registry_cache_age_sec "$TMPD/fresh.json" >/dev/null 2>&1 && _r=0 || _r=1
unset -f stat
[[ "$_r" -eq 1 ]] && pass_test || fail_test "a non-numeric mtime must not become an age"

# ── 4. --refresh ───────────────────────────────────────────────────────────────
start_test "--refresh discards the copy and re-reads exactly once"
reset_state
REGISTRY_CACHE="$TMPD/refresh.json"; echo '{}' > "$REGISTRY_CACHE"
touch -d "@$(( $(date +%s) - 60 ))" "$REGISTRY_CACHE"
REGISTRY_REFRESH=true
# ⚠️ NOT `$( ... )`: CURL_N is incremented by the stub, and a subshell would
# count the fetches and then throw the count away — which is how this test
# failed on its first run, claiming 0 fetches for two real ones.
_fetch_registry 2>"$TMPD/refresh.err" >/dev/null
_fetch_registry 2>>"$TMPD/refresh.err" >/dev/null
_err=$(cat "$TMPD/refresh.err")
grep -q 'cache discarded (--refresh)' <<<"$_err" && [[ "$CURL_N" -eq 1 ]] && pass_test \
    || fail_test "fetches=$CURL_N output: $_err"

start_test "a file:// registry is still never cached"
reset_state
REGISTRY_URL_PRIMARY="file://$TMPD/local.json"
echo '{}' > "$REGISTRY_CACHE"
_registry_cache_fresh && _r=0 || _r=1
REGISTRY_URL_PRIMARY="https://example.invalid/registry.json"
[[ "$_r" -eq 1 ]] && pass_test || fail_test "a file:// registry must not be served from cache"

print_summary
