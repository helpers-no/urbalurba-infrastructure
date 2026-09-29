#!/bin/bash
# test-collection-pins-apply.sh — a pin that reads like a pin must be one
#
# 🔴 `install_collection community.postgresql "git+...,3.4.0"` READ as a pin and
# installed the bare name from Galaxy, which resolves to the latest release.
# The version was reached only if Galaxy returned HTTP 500 — so the pin applied
# exactly when Galaxy was DOWN and never otherwise.
#
# Measured 2026-09-29 (imac, urb-agents#1720):
#
#     collection             stated   installed
#     community.postgresql   3.4.0    5.0.0      ← two majors
#     kubernetes.core        6.2.0    6.6.0
#     community.general      8.6.0    13.4.0     ← five majors
#
# ⚠️ And it broke a service. 5.0.0 removed the `port` parameter for
# `login_port`, and four database playbooks still pass `port:` — so
# `uis deploy authentik` has failed on a fresh cluster since 5.x entered the
# image, unreported, because the guard against exactly this was decorative.
#
# 🔵 The verification matters as much as the pin. This defect WAS a pin that
# silently did not apply, so the fix cannot rest on the syntax being correct —
# that is the bet that lost. The installer reads back what landed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
KT="$REPO/provision-host/provision-host-02-kubetools.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== collection pins apply, and are read back ==="

[[ -f "$KT" ]] || { fail "file present" "missing: $KT"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
kt="$(grep -v '^[[:space:]]*#' "$KT")"

if grep -q 'install_collection' <<<"$kt"; then
    pass "control: the comment-stripped scan sees the installer"
else
    fail "control: the scan sees the installer" "stripping removed it — every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- 🔴 the regression: installing the bare collection name ---------------
if grep -qE 'ansible-galaxy collection install "\$collection" ' <<<"$kt"; then
    fail "the Galaxy install carries the version" \
         "it installs \$collection bare, which resolves to the LATEST release — the original defect"
else
    pass "the Galaxy install does not install the bare collection name"
fi

if grep -qF 'ansible-galaxy collection install "${collection}:==${version}"' <<<"$kt"; then
    pass "the Galaxy install pins an exact version"
else
    fail "the install pins an exact version" "no ==\${version} in the Galaxy install"
fi

# --- every call site must pass a version ----------------------------------
# ⚠️ Count the call sites and require each to carry a version argument. A
# single unpinned collection is the whole defect back again.
_calls="$(grep -cE '^\s*install_collection [a-z]' <<<"$kt")"
_pinned="$(grep -cE '^\s*install_collection [a-z][a-z_.]+[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+' <<<"$kt")"
if [[ "$_calls" -ge 3 && "$_calls" -eq "$_pinned" ]]; then
    pass "all $_calls collections are called with an explicit version"
else
    fail "every collection is pinned" "$_calls call sites, $_pinned carry a version"
fi

# --- 🔵 and the pin must be verified after installing ---------------------
if grep -q '_verify_collection_version' <<<"$kt"; then
    pass "the installer reads back what landed"
else
    fail "the pin is verified after install" \
         "this defect WAS a pin that did not apply — trusting the syntax repeats the bet that lost"
fi

# Both success paths — Galaxy and the GitHub fallback — must verify, or one of
# them can install anything and report success.
_verify_calls="$(grep -cE '_verify_collection_version "\$collection"' <<<"$kt")"
if [[ "$_verify_calls" -ge 2 ]]; then
    pass "both the Galaxy and GitHub success paths verify ($_verify_calls call sites)"
else
    fail "both success paths verify" "only $_verify_calls — the other can install any version and pass"
fi

# --- the postgresql pin must match what the playbooks are written for -----
# 🔴 `port` and `login_port` are NOT interchangeable: 3.4.0 accepts only
# `port`, 5.0.0 only `login_port`. So the pin and the playbooks must agree,
# and renaming cannot make them version-agnostic.
_pg_pin="$(grep -oE '^\s*install_collection community\.postgresql[[:space:]]+[0-9.]+' <<<"$kt" | awk '{print $3}')"
_uses_port=0
for f in "$REPO"/ansible/playbooks/utility/*-create-postgres.yml; do
    [[ -f "$f" ]] || continue
    grep -qE '^\s+port:' "$f" && _uses_port=1
done
if [[ "$_uses_port" -eq 1 && "$_pg_pin" == 3.* ]]; then
    pass "community.postgresql is pinned to 3.x, which is what the playbooks' 'port:' needs"
elif [[ "$_uses_port" -eq 0 && "$_pg_pin" == 5.* ]]; then
    pass "the playbooks use login_port and the pin is 5.x — consistent"
else
    fail "the pin and the playbooks agree" \
         "pin is '$_pg_pin' and playbooks using 'port:' = $_uses_port — authentik's database step will fail"
fi

# --- 🔴 and a failed pin must STOP THE BUILD ------------------------------
# A verification whose failure is a note is not a verification. This printed
# "Note: Playbooks requiring these collections won't work" and carried on, so
# the build succeeded and published an image whose playbooks could not run —
# the same shape as the defect above. `main` returns ${#ERRORS[@]} and the
# Dockerfile RUN fails on a non-zero exit, so the failure has to reach ERRORS.
_fail_blk="$(sed -n '/collections_failed" -eq 0/,/^        fi$/p' <<<"$kt")"
if grep -qF 'add_error "Ansible Collections"' <<<"$_fail_blk"; then
    pass "a failed collection is recorded as an error, which fails the build"
else
    fail "a failed collection fails the build" \
         "it is only a status line, so the image publishes with the wrong collections"
fi

# ⚠️ And the error path must not still describe itself as a note.
if grep -qF "Note: Playbooks requiring these collections won't work" <<<"$kt"; then
    fail "the failure is not downgraded to a note" "the old wording is back, and it shipped images"
else
    pass "the failure is not downgraded to a note"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
