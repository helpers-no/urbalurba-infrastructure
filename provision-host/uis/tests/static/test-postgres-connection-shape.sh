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
# Only lines that RUN psql. Comment lines and prose are excluded; a printed
# command is still checked, because a user is meant to run it.
offenders=$(grep -rn "psql " \
      "$ROOT/ansible/playbooks" \
      "$ROOT/provision-host/uis/lib" \
      "$ROOT/provision-host/uis/manage" \
      --include='*.sh' --include='*.yml' 2>/dev/null \
    | grep -vE '\-h |--host' \
    | grep -vE ':[[:space:]]*#' \
    | grep -vE 'psql exit|Hint:|^\S+:[0-9]+:[[:space:]]*(- )?"?(Check|•)' \
    `# psql given a connection URI already carries the host` \
    | grep -vE 'psql "(\{\{|postgres)' \
    `# prose and help text that merely mentions psql, rather than running it` \
    | grep -vE '#[^"]*psql|echo "[^"]*psql' \
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
