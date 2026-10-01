#!/bin/bash
# test-extensions-are-one-list.sh - the extension list exists once, and reaches every database
#
# Terje, 2026-09-29: "i want the extensions activated so that they can be used
# by anyone that want the functionality."
#
# 🔴 Before this, the eight extensions UIS advertises reached NO application
# database: CREATE EXTENSION ran only in the chart's initdb script against
# `postgres`, and an app database is cloned from template1, which never had
# them (atlas, urb-agents#1741).
#
# Three places can now name extensions, and they must agree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    ROOT="/mnt/urbalurbadisk"
else
    ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
CONF="$ROOT/provision-host/uis/lib/postgres-extensions.conf"
PG_LIB="$ROOT/provision-host/uis/lib/configure-postgresql.sh"
DEPLOY_PB="$ROOT/ansible/playbooks/040-database-postgresql.yml"
CHART="$ROOT/manifests/042-database-postgresql-config.yaml"

print_test_section "Postgres extensions: one list, reaching every database"

start_test "The list exists as a file"
assert_file_exists "$CONF" && pass_test || fail_test "No $CONF"

# Parse it the way the handler does.
mapfile -t WANTED < <(grep -vE '^[[:space:]]*(#|$)' "$CONF" | tr -d '[:blank:]')

start_test "It is not empty"
if [[ ${#WANTED[@]} -ge 1 ]]; then pass_test; else fail_test "Parsed 0 extensions from $CONF"; fi

start_test "It contains the eight the documentation advertises"
missing=""
for e in vector postgis hstore ltree uuid-ossp pg_trgm btree_gin pgcrypto; do
    printf '%s\n' "${WANTED[@]}" | grep -qx "$e" || missing="$missing $e"
done
if [[ -z "$missing" ]]; then pass_test; else fail_test "Missing from the list:$missing"; fi

start_test "🔴 The Helm values file names exactly the same set — it cannot read the list"
# 042 is a chart values file, so it carries its own copy for initdb. Drift
# between the two is the thing this catches.
mapfile -t IN_CHART < <(grep -oE 'CREATE EXTENSION IF NOT EXISTS "?[a-z_-]+"?' "$CHART" \
    | sed -E 's/.*EXISTS "?([a-z_-]+)"?/\1/' | sort -u)
mapfile -t SORTED_WANTED < <(printf '%s\n' "${WANTED[@]}" | sort -u)
if [[ "$(printf '%s\n' "${SORTED_WANTED[@]}")" == "$(printf '%s\n' "${IN_CHART[@]}")" ]]; then
    pass_test
else
    fail_test "Chart and list disagree. list: ${SORTED_WANTED[*]} | chart: ${IN_CHART[*]}"
fi

# ── the two mechanisms that put them in a real database ──

start_test "The deploy seeds template1, so new databases inherit them"
if grep -q "8d. Activate the UIS extensions in template1" "$DEPLOY_PB"; then
    pass_test
else
    fail_test "No template1 seeding in $DEPLOY_PB"
fi

start_test "It targets template1, not postgres — cloning is the whole point"
blk="$(awk '/8d. Activate the UIS extensions in template1/,/8e\./' "$DEPLOY_PB")"
if echo "$blk" | grep -qE '^\s+- template1$'; then
    pass_test
else
    fail_test "The seeding task does not target template1: $blk"
fi

start_test "It reads the one list rather than carrying a fourth copy"
if echo "$blk" | grep -qF "postgres-extensions.conf"; then
    pass_test
else
    fail_test "The playbook hardcodes extensions instead of reading the list"
fi

start_test "It stops on error — a half-activated template1 must not look fine"
if echo "$blk" | grep -qF "ON_ERROR_STOP=on"; then
    pass_test
else
    fail_test "No ON_ERROR_STOP: a failed CREATE EXTENSION would pass silently"
fi

start_test "configure activates them too, so an existing database is retro-fitted"
if grep -q "^_pg_ensure_extensions()" "$PG_LIB"; then
    pass_test
else
    fail_test "No _pg_ensure_extensions in $PG_LIB"
fi

start_test "🔴 On BOTH paths — this file has two tails and every fix has had to land on both"
n=$(grep -c '_pg_ensure_extensions "\$database_name" "\$admin_pass"' "$PG_LIB")
if [[ "$n" -eq 2 ]]; then
    pass_test
else
    fail_test "Called on $n of 2 paths (create, and database-already-exists)"
fi

start_test "It runs as admin — CREATE EXTENSION needs superuser, which is why an app cannot"
fn="$(awk '/^_pg_ensure_extensions\(\) \{/,/^\}/' "$PG_LIB")"
if echo "$fn" | grep -qF 'PG_ADMIN_USER'; then
    pass_test
else
    fail_test "_pg_ensure_extensions does not use the admin role: $fn"
fi

start_test "It refuses rather than guessing when the list is unreadable"
if echo "$fn" | grep -qiF "refusing to guess"; then
    pass_test
else
    fail_test "A missing list would silently activate nothing: $fn"
fi

start_test "A failure to activate fails the command — not a note"
# The dominant defect in this repository is a command reporting success while
# the thing it claimed had not happened.
n=$(grep -c 'Failed to activate extensions' "$PG_LIB")
if [[ "$n" -eq 4 ]]; then
    pass_test
else
    fail_test "Expected 2 paths x (json + human) = 4 failure reports; found $n"
fi

start_test "Extensions are activated BEFORE the init file, so init SQL can use the types"
if awk '/_pg_ensure_extensions/{seen++} /Applying init file from/{if(!seen) bad=1} END{exit bad+0}' "$PG_LIB"; then
    pass_test
else
    fail_test "An init file is applied before the extensions exist"
fi

# ── the documentation must not go back to overselling it ──

start_test "The docs state the property: activated in every database"
IDX="$ROOT/website/docs/services/databases/index.md"
n=0
grep -qiF "activated in every database" "$IDX" && n=$((n+1))
grep -qiF "uis configure postgresql" "$IDX" && n=$((n+1))
grep -qiF "has none" "$IDX" && n=0
if [[ $n -eq 2 ]]; then
    pass_test
else
    fail_test "index.md does not state that the extensions reach an app database"
fi


# ============================================================
# urb-agents#1743: 8d echoed the superuser password on failure
# ============================================================

start_test "🔴 The template1 tasks do not display their argv, which carries PGPASSWORD"
# Ansible echoes the whole `cmd` on failure. imac measured the superuser
# password once in a failing deploy log and zero times in two successful ones.
n=0
for t in "8d. Activate the UIS extensions in template1" "8e. Show which extensions template1 now has"; do
    blk="$(awk -v pat="$t" '$0 ~ pat {f=1} f && /^    - name: "8/ && $0 !~ pat {exit} f' "$DEPLOY_PB")"
    echo "$blk" | grep -q "no_log: true" && n=$((n+1))
done
if [[ $n -eq 2 ]]; then pass_test; else fail_test "only $n of 2 password-carrying tasks are no_log"; fi

start_test "But a failure is still reported with a cause, not censored"
# no_log alone turns a leak into "the output has been hidden" and no reason —
# the defect 070-verify-authentik task 16 spent two releases on.
if grep -q '8d2. Fail if the extensions could not be activated' "$DEPLOY_PB"; then
    pass_test
else
    fail_test "no_log with no follow-up failure task: a failure would be silent or unexplained"
fi

start_test "That failure prints psql's output, never the command"
blk="$(awk '/8d2. Fail if the extensions could not be activated/,/8e\./' "$DEPLOY_PB")"
if echo "$blk" | grep -qF "template1_ext.stderr" && ! echo "$blk" | grep -qF ".cmd"; then
    pass_test
else
    fail_test "8d2 does not report stderr, or reports the command: $blk"
fi

start_test "The activation task still fails the deploy — a leak fix must not become a silent pass"
if echo "$blk" | grep -qF "template1_ext.rc | default(1) != 0"; then
    pass_test
else
    fail_test "8d2 does not gate on the return code, defaulting to failure: $blk"
fi

start_test "Every kubectl task in the deploy still carries KUBECONFIG"
# ⚠️ Adding no_log cost 8d its `environment:` block in the first draft of this
# fix, which would have broken kubectl outright.
missing="$(python3 - "$DEPLOY_PB" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
bad = [t.split('\n')[0] for t in re.split(r'\n    - name: ', s)[1:]
       if re.search(r'^\s+- kubectl$', t, re.M) and 'KUBECONFIG' not in t]
print(' | '.join(bad))
PYEOF
)"
if [[ -z "$missing" ]]; then pass_test; else fail_test "kubectl without KUBECONFIG: $missing"; fi

print_summary
