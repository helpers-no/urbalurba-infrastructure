#!/bin/bash
# test-postgres-connection-shape.sh
#
# Guards the assumption that broke four times in one day: UIS code reaching
# PostgreSQL in a way that only works on the in-cluster topology.
#
# Two shapes are rejected:
#   1. psql with no -h / --host  → uses the local unix socket, which does not
#      exist in the external-services proxy (client tooling, no server)
#   2. a hardcoded `postgresql-0` pod name → a StatefulSet artefact; the proxy
#      is a Deployment, so that pod does not exist
#
# Both are invisible on Rancher Desktop, which is exactly why they shipped.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /mnt/urbalurbadisk ]]; then ROOT=/mnt/urbalurbadisk
else ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"; fi

fails=0
note() { echo "  $*"; }

# --- 1. psql without a host -------------------------------------------------
# ⚠️ This used to be a BLOCKLIST of prose shapes: exclude `# ... psql`, exclude
# `echo "... psql ..."`, and so on. Every new way of *mentioning* psql in a
# string needed a new exclusion, and on 2026-08-25 one arrived that nobody had
# enumerated —
#
#     why="psql produced no error text"
#
# — which is an assignment, not an invocation. The gate failed on it and left
# `main` RED for over a day. That is the same allowlist-that-new-things-never-
# join defect this suite exists to catch, in the suite itself.
#
# So decide STRUCTURALLY instead: strip comments and quoted string literals,
# then ask whether `psql` still stands as a word. Code survives that; prose does
# not. New ways of writing prose need no new rule.
_real_psql_lines() {
    awk '
    {
        # strip the grep "file:line:" prefix so colons in code do not confuse us
        i1 = index($0, ":");           rest = substr($0, i1 + 1)
        i2 = index(rest, ":");         code = substr(rest, i2 + 1)

        out = ""; inq = 0; q = ""
        n = length(code)
        for (i = 1; i <= n; i++) {
            c = substr(code, i, 1)
            if (inq) { if (c == q) inq = 0; continue }          # inside a string: drop it
            if (c == "\"" || c == "'"'"'") { inq = 1; q = c; continue }
            if (c == "#") break                                  # comment: rest is prose
            out = out c
        }
        if (out ~ /(^|[^A-Za-z0-9_.\/-])psql([^A-Za-z0-9_.-]|$)/) print $0
    }'
}

# The matcher must fail loudly if it ever stops matching. A gate that silently
# matches nothing reports PASS forever - the exact "succeeded having done
# nothing" shape that keeps costing us rounds.
_self_check() {
    local bad='x.sh:1:    psql -c "select 1"'
    local prose='x.sh:2:    why="psql produced no error text"'
    local comment='x.sh:3:    # run psql by hand'
    local ok=0
    [[ -n "$(printf '%s\n' "$bad"     | _real_psql_lines)" ]] || { echo "SELF-CHECK FAIL: matcher missed a real psql invocation"; ok=1; }
    [[ -z "$(printf '%s\n' "$prose"   | _real_psql_lines)" ]] || { echo "SELF-CHECK FAIL: matcher flagged a quoted string"; ok=1; }
    [[ -z "$(printf '%s\n' "$comment" | _real_psql_lines)" ]] || { echo "SELF-CHECK FAIL: matcher flagged a comment"; ok=1; }
    return $ok
}

if ! _self_check; then
    note "The psql matcher is broken; its verdict cannot be trusted."
    fails=$((fails+1))
fi

# The structural filter REPLACES the prose blocklist that missed `why="..."`.
# The two greps kept below are not prose rules: one is the actual condition
# being tested (-h present), the other is a URI that already carries the host.
# The `Check|•` line is operator help text printed by a playbook - it is a
# documented kubectl-exec recipe, and re-litigating it belongs with the
# topology investigation, not with a launcher fix.
offenders=$(grep -rn "psql " \
      "$ROOT/ansible/playbooks" \
      "$ROOT/provision-host/uis/lib" \
      "$ROOT/provision-host/uis/manage" \
      --include='*.sh' --include='*.yml' 2>/dev/null \
    | _real_psql_lines \
    | grep -vE '\-h |--host' \
    | grep -vE 'psql exit|Hint:|^\S+:[0-9]+:[[:space:]]*(- )?"?(Check|•)' \
    `# a connection URI already carries the host` \
    | grep -vE 'psql "?(\{\{|postgres)' \
    || true)

if [[ -n "$offenders" ]]; then
    echo "FAIL: psql invoked without -h (breaks on the proxied topology):"
    echo "$offenders" | sed 's/^/    /'
    note "Use -h \"\$PG_PSQL_HOST\" (shell) or -h 127.0.0.1 (playbooks)."
    note "See provision-host/uis/lib/pg-connection.sh for why."
    fails=$((fails+1))
else
    echo "PASS: every psql invocation passes a host"
fi

# --- 2. hardcoded postgres pod name -----------------------------------------
hardcoded=$(grep -rn "postgresql-0" \
      "$ROOT/ansible/playbooks" \
      "$ROOT/provision-host/uis/lib" \
      "$ROOT/provision-host/uis/manage" \
      --include='*.sh' --include='*.yml' 2>/dev/null \
    | grep -vE ':[[:space:]]*#' \
    || true)

if [[ -n "$hardcoded" ]]; then
    echo "FAIL: hardcoded 'postgresql-0' (does not exist on the proxied topology):"
    echo "$hardcoded" | sed 's/^/    /'
    note "Discover it: -l app.kubernetes.io/name=postgresql"
    fails=$((fails+1))
else
    echo "PASS: no hardcoded postgres pod name"
fi

exit $fails
