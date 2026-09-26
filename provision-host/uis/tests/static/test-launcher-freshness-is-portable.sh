#!/bin/bash
# test-launcher-freshness-is-portable.sh — the guard must work where operators are
#
# 🔴 `_launcher_freshness` required `sha256sum`, which macOS does not ship
# (it has `shasum`). On a Mac the check returned "unknown" on every run, so
# the warning "Image is up to date — but this launcher is NOT" could never
# fire on the platform most operators here use.
#
# ⚠️ It was HONEST about it — "could not be checked — not the same as current"
# — which is the worst combination: a guard that cannot alarm and cannot be
# accused of lying. Nothing downstream reports an inert guard.
#
# 🔵 `update_launcher`, the half that actually replaces the file, has always
# used `cmp -s` and carries no such dependency. Two functions doing the same
# comparison, one of them with a portability problem the other had already
# solved (urb-agents#1581).
#
# This also asserts the delivery path itself, because #1581 was opened on the
# premise that `uis pull` does not update the launcher. It does — and that is
# load-bearing enough to be protected rather than rediscovered.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
UIS="$REPO/uis"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== the launcher freshness guard runs without coreutils ==="

[[ -f "$UIS" ]] || { fail "launcher present" "missing: $UIS"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# The defect is named in this file's comments and the launcher's, so assert
# against CODE lines only — a file-wide grep would pass with the fix reverted.
code="$(grep -v '^[[:space:]]*#' "$UIS")"

if grep -q '_launcher_freshness' <<<"$code"; then
    pass "control: the comment-stripped scan still sees code"
else
    fail "control: the scan sees code" "stripping removed everything — all checks below vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- no hash-tool dependency anywhere in the launcher ----------------------
if grep -qE '\bsha256sum\b|\bshasum\b' <<<"$code"; then
    fail "the guard needs no hash binary" "a tool dependency is back; macOS ships neither by default"
else
    pass "the guard needs no hash binary"
fi

# --- and it compares the files directly ------------------------------------
_fresh="$(sed -n '/^_launcher_freshness()/,/^}/p' "$UIS" | grep -v '^[[:space:]]*#')"
if grep -qF 'cmp -s' <<<"$_fresh"; then
    pass "freshness compares the two files with cmp"
else
    fail "freshness uses cmp" "without a comparison it cannot answer the question at all"
fi

# --- all three verdicts must survive ---------------------------------------
# 🔴 'unknown' is the load-bearing one: an unreachable network or an unreadable
# file must never read as 'current'.
_n=0
for v in current behind unknown; do grep -qF "echo \"$v\"" <<<"$_fresh" && _n=$((_n+1)); done
if [[ "$_n" -eq 3 ]]; then
    pass "current, behind and unknown are all still reachable"
else
    fail "three verdicts survive" "only $_n of 3 — 'could not tell' collapsing into a claim"
fi

# --- a mangled download must not raise an alarm ----------------------------
if grep -qF 'bash -n "$remote_tmp"' <<<"$_fresh"; then
    pass "a download that will not parse reads as unknown, not behind"
else
    fail "a mangled download is not called stale" "a flaky connection turns the guard into noise"
fi

# --- the delivery path #1581 doubted --------------------------------------
_pull="$(sed -n '/^pull_container()/,/^}/p' "$UIS" | grep -v '^[[:space:]]*#')"
if grep -qF 'update_launcher' <<<"$_pull"; then
    pass "uis pull updates the launcher (the premise of #1581, protected)"
else
    fail "pull refreshes the launcher" "launcher-only releases would genuinely be undeliverable"
fi

# --- and the update itself stays dependency-free ---------------------------
_upd="$(sed -n '/^update_launcher()/,/^}/p' "$UIS" | grep -v '^[[:space:]]*#')"
_n=0
grep -qF 'cmp -s' <<<"$_upd" && _n=$((_n+1))
grep -qF 'bash -n' <<<"$_upd" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "update_launcher still compares with cmp and refuses what will not parse"
else
    fail "the update path is intact" "only $_n of 2 — it would install a broken launcher, or never compare"
fi

# ---------------------------------------------------------------------------
# 🔴 RUN IT. The whole reason this defect survived is that the guard was only
# ever read, never exercised — it returned "unknown" forever on macOS and
# nothing downstream reports an inert guard. Text assertions would not have
# caught that either, so the function is extracted and actually called.
# ---------------------------------------------------------------------------
_TD="$(mktemp -d)"
trap 'rm -rf "$_TD"' EXIT
sed -n '/^_launcher_freshness()/,/^}/p' "$UIS" > "$_TD/fn.sh"

# A curl stub, so no network and no repository are involved. It writes
# whatever $STUB_BODY holds, or fails when $STUB_FAIL is set.
mkdir -p "$_TD/bin"
cat > "$_TD/bin/curl" <<'STUB'
#!/bin/bash
[ -n "$STUB_FAIL" ] && exit 22
out=""
while [ $# -gt 0 ]; do [ "$1" = "-o" ] && { out="$2"; shift; }; shift; done
[ -n "$out" ] || exit 1
printf '%s' "$STUB_BODY" > "$out"
STUB
chmod +x "$_TD/bin/curl"

_verdict() {  # $1 = local file contents, env STUB_BODY / STUB_FAIL set by caller
    printf '%s' "$1" > "$_TD/local"
    (
        PATH="$_TD/bin:$PATH"
        UIS_LAUNCHER_PATH="$_TD/local"
        UIS_RAW_BASE="http://stub.invalid"
        export PATH UIS_LAUNCHER_PATH UIS_RAW_BASE STUB_BODY STUB_FAIL
        # shellcheck disable=SC1090
        . "$_TD/fn.sh"
        _launcher_freshness
    )
}

_SAME='#!/bin/bash
echo hello'
_DIFF='#!/bin/bash
echo goodbye'

start() { :; }

STUB_FAIL="" STUB_BODY="$_SAME"
got="$(_verdict "$_SAME")"
if [[ "$got" == "current" ]]; then
    pass "RUN: identical files report current"
else
    fail "identical files report current" "got '$got'"
fi

STUB_FAIL="" STUB_BODY="$_DIFF"
got="$(_verdict "$_SAME")"
if [[ "$got" == "behind" ]]; then
    pass "RUN: a different upstream file reports behind"
else
    fail "a different upstream reports behind" "got '$got' — the guard cannot fire"
fi

STUB_FAIL=1 STUB_BODY=""
got="$(_verdict "$_SAME")"
if [[ "$got" == "unknown" ]]; then
    pass "RUN: an unreachable network reports unknown, never current"
else
    fail "unreachable reports unknown" "got '$got' — offline would read as up to date"
fi

STUB_FAIL="" STUB_BODY=""
got="$(_verdict "$_SAME")"
if [[ "$got" == "unknown" ]]; then
    pass "RUN: an empty download reports unknown, not behind"
else
    fail "empty download reports unknown" "got '$got' — a truncated fetch becomes a false alarm"
fi

STUB_FAIL="" STUB_BODY='#!/bin/bash
if [ then fi ('
got="$(_verdict "$_SAME")"
if [[ "$got" == "unknown" ]]; then
    pass "RUN: a mangled download reports unknown, not behind"
else
    fail "mangled download reports unknown" "got '$got' — the guard becomes noise on a flaky link"
fi

# 🔴 THE CASE THAT WOULD HAVE CAUGHT THE ORIGINAL DEFECT.
#
# Every run above happens on a machine that HAS sha256sum, where the old code
# worked — which is precisely why this survived: it failed only where the tool
# is absent, and nobody runs the test suite there. So build a PATH containing
# only what the function legitimately needs, with no sha256sum in it, and
# require the guard to still fire.
_MIN="$_TD/min"; mkdir -p "$_MIN"
for t in cmp mktemp rm cat printf bash sh; do
    _src="$(command -v "$t" 2>/dev/null)" && [ -n "$_src" ] && ln -sf "$_src" "$_MIN/$t"
done
ln -sf "$_TD/bin/curl" "$_MIN/curl"

if command -v sha256sum >/dev/null 2>&1 && ! PATH="$_MIN" command -v sha256sum >/dev/null 2>&1; then
    pass "control: the restricted PATH really does hide sha256sum"
else
    fail "the restricted PATH hides sha256sum" "this host has no sha256sum to hide, so the next check proves nothing"
fi

printf '%s' "$_SAME" > "$_TD/local"
got="$(
    PATH="$_MIN" UIS_LAUNCHER_PATH="$_TD/local" UIS_RAW_BASE="http://stub.invalid" \
    STUB_BODY="$_DIFF" STUB_FAIL="" bash -c '. "$1"; _launcher_freshness' _ "$_TD/fn.sh" 2>/dev/null
)"
if [[ "$got" == "behind" ]]; then
    pass "RUN: the guard still fires with no sha256sum on PATH (the macOS case)"
else
    fail "the guard works without sha256sum" "got '$got' — inert on macOS, which is where the operators are"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
