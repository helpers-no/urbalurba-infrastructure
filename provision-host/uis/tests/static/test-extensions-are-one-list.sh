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

print_summary
