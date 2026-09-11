#!/bin/bash
# test-forwarded-env.sh — an operator-settable override must reach the container
#
# `docker exec` does not inherit the caller's environment, so the launcher
# forwards an allow-list. A variable the libraries read but the launcher does not
# forward is SILENTLY IGNORED from the host — the only place a user sets it —
# while working perfectly inside the container. That failure mode has now
# happened twice:
#
#   1.6.9  TEMPLATE_REPO      documented, unforwarded    (imac, urb-agents#335)
#   1.6.20 UIS_ORAS_OCI_LAYOUT new, unforwarded          (imac, urb-agents#367)
#
# After the first, a comment was added to UIS_FORWARDED_ENV recording exactly
# this. The second happened anyway. So this test derives the candidates from the
# code rather than restating them: any `${UIS_*|TEMPLATE_*|REGISTRY_*:-}` read in
# provision-host/uis/lib must be either forwarded or listed below as internal,
# WITH a reason. A new override therefore forces a decision instead of defaulting
# to silence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LAUNCHER="$REPO_ROOT/uis"
LIB_DIR="$REPO_ROOT/provision-host/uis/lib"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; PASS=$((PASS+1)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; [ -n "${2:-}" ] && echo -e "    \033[0;31m→ $2\033[0m"; FAIL=$((FAIL+1)); }

# Internal to the container: setting these from the host is meaningless, so they
# are deliberately not forwarded. Each needs a reason, not just an entry.
#   UIS_BASE, UIS_BASE_PATH  container filesystem layout, not an operator knob
#   TEMPLATE_CACHE_DIR       a path inside the container
#   UIS_BANNER_PRINTED       an internal once-only flag
#   REGISTRY_CACHE           a path inside the container; a host value would
#                            name a file the container cannot see. It exists as
#                            an override so a TEST can pin the path, not so an
#                            operator can. REGISTRY_CACHE_TTL, by contrast, IS
#                            forwarded — `REGISTRY_CACHE_TTL=0 ./uis template
#                            list` is a real thing to want after editing a
#                            registry.
# ⚠️ Every exemption needs a reason, and "it is not an operator knob" is the only
# one accepted here. A variable a person might reasonably set on the host MUST be
# forwarded, or it is silently ignored inside the container.
#
#   UIS_BASE, UIS_BASE_PATH, TEMPLATE_CACHE_DIR  — resolved in-container
#   UIS_BANNER_PRINTED, REGISTRY_CACHE           — computed, not settable
#   REGISTRY_REFRESH                             — set by `--refresh`; the FLAG is
#       the interface. Forwarding it would give one behaviour two switches, and
#       the env form would be invisible in the command a person later re-reads.
#   REGISTRY_FROM_CACHE                          — an OUTPUT of _fetch_registry,
#       read by the staleness hint. Settable only to lie to yourself.
#       ⚠️ REGISTRY_CACHE_AGE_MIN is deliberately NOT listed: it is never read in
#       the `${VAR:-}` form the candidate scan looks for, so exempting it would
#       be a stale exemption — and the second assertion below catches that.
EXEMPT="UIS_BASE UIS_BASE_PATH TEMPLATE_CACHE_DIR UIS_BANNER_PRINTED REGISTRY_CACHE REGISTRY_REFRESH REGISTRY_FROM_CACHE"

echo "=== Forwarded environment overrides ==="

if [[ ! -f "$LAUNCHER" ]]; then
    fail "launcher present" "no $LAUNCHER"
else
    forwarded="$(sed -n '/^UIS_FORWARDED_ENV=(/,/^)/p' "$LAUNCHER" \
                 | grep -oE '^[[:space:]]+[A-Z_]+' | tr -d ' ' | sort -u)"

    candidates="$(grep -rhoE '\$\{(UIS|TEMPLATE|REGISTRY)_[A-Z_]+:-' "$LIB_DIR"/*.sh 2>/dev/null \
                  | sed 's/^\${//; s/:-$//' | sort -u)"

    missing=""
    for v in $candidates; do
        case " $EXEMPT " in *" $v "*) continue ;; esac
        grep -qx "$v" <<< "$forwarded" || missing="$missing $v"
    done

    if [[ -z "$missing" ]]; then
        pass "every operator-settable override in lib/ is forwarded"
    else
        fail "every operator-settable override in lib/ is forwarded" \
             "not forwarded and not exempt:$missing — add to UIS_FORWARDED_ENV in ./uis, or to EXEMPT here with a reason"
    fi

    # The exemptions must stay honest: an exempt variable that is no longer read
    # is dead weight that makes the list look considered when it is stale.
    stale=""
    for v in $EXEMPT; do
        grep -qx "$v" <<< "$candidates" || stale="$stale $v"
    done
    if [[ -z "$stale" ]]; then
        pass "no exemption is stale"
    else
        fail "no exemption is stale" "exempt but no longer read:$stale — remove from EXEMPT"
    fi
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
