#!/bin/bash
# test-plan-equals-execution.sh — the printed plan IS the executed commands.
#
# 🔴 imac asked for exactly this, on urb-agents#481 round 3:
#
#   "one test that dry-runs an install, executes it, and diffs the printed
#    commands against the executed ones. That single assertion covers this
#    defect, the --database asymmetry, and every future divergence of the
#    same kind."
#
# The defect it exists for: 1.6.31 fixed the --database fallback in the dry-run
# printer and not in the executor, so the plan said
#   configure postgrest --app atlas-t --database atlas-t
# and the run executed the same command WITHOUT --database. Plan and execution
# had AGREED before that fix and disagreed after it — which is worse than the
# bug it replaced, because `--dry-run` is the instrument an operator uses to
# decide whether an install will touch a live tenant.
#
# ⚠️ PLAN-templates-002 already named "the printed plan equals the executed one"
# as this phase's falsification. It was documented and unenforced, exactly like
# the UIS_FORWARDED_ENV comment before it became a derived test. This enforces
# it.
#
# No cluster: `uis` is stubbed on PATH and records what it was called with.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
    UIS_ROOT="/mnt/urbalurbadisk/provision-host/uis"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
    UIS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
REPO_ROOT="$(cd "$UIS_ROOT/../.." && pwd)"

source "$UIS_LIB/logging.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

print_test_section "The printed plan equals the executed commands"

if ! command -v yq >/dev/null 2>&1 || ! command -v oras >/dev/null 2>&1; then
    for _ in 1 2 3 4; do skip_test "needs yq and oras (uis-provision-host 1.6.16+)"; done
    print_summary
    return 0 2>/dev/null || exit 0
fi

# ── a stub `uis` that records its arguments and answers configure with JSON ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/uis" <<'STUB'
#!/bin/bash
echo "$*" >> "$UIS_CALL_LOG"
if [[ "$1" == "configure" ]]; then
    echo '{"status":"ok","service":"'"$2"'"}'
fi
exit 0
STUB
chmod +x "$TMP/bin/uis"

# ── build the catalogue fixture (id and app_name deliberately differ) ────────
FIXTURE="$TMP/fixture"
if ! bash "$UIS_ROOT/tests/fixtures/catalogue/make-fixture.sh" "$FIXTURE" >/dev/null 2>&1; then
    for _ in 1 2 3 4; do skip_test "could not build the catalogue fixture"; done
    print_summary
    return 0 2>/dev/null || exit 0
fi

export SERVICES_JSON="$REPO_ROOT/website/src/data/services.json"
export STACKS_JSON="$REPO_ROOT/website/src/data/stacks.json"
[[ -f "$SERVICES_JSON" ]] || SERVICES_JSON="$UIS_ROOT/../../website/src/data/services.json"
export REGISTRY_URL_PRIMARY="file://$FIXTURE/registry.json"
export UIS_ORAS_OCI_LAYOUT=1
export EXTEND_DIR="$FIXTURE/extend"
export TEMPLATE_CACHE_DIR="$TMP/tcache"

source "$UIS_LIB/template.sh"

# ── 1. capture the PRINTED plan ──────────────────────────────────────────────
PRINTED="$TMP/printed.txt"
( cmd_template_install uisfix --dry-run ) >"$PRINTED" 2>/dev/null
printed_cfg=$(grep -oE 'uis configure .*' "$PRINTED" | sed 's/^uis //' | sort)

# ── 2. capture the EXECUTED commands, with uis stubbed ───────────────────────
export UIS_CALL_LOG="$TMP/calls.txt"; : > "$UIS_CALL_LOG"
rm -rf "$TMP/tcache"
( PATH="$TMP/bin:$PATH"; cmd_template_install uisfix ) >/dev/null 2>&1
executed_cfg=$(grep '^configure ' "$UIS_CALL_LOG" 2>/dev/null | sed 's/ --json//' | sort)

start_test "the dry run printed at least one configure command"
[[ -n "$printed_cfg" ]] && pass_test || fail_test "no configure lines in the plan: $(head -30 "$PRINTED")"

start_test "the install executed at least one configure command"
[[ -n "$executed_cfg" ]] && fail_or=0 || fail_or=1
[[ $fail_or -eq 0 ]] && pass_test || fail_test "nothing was executed; stub log: $(cat "$UIS_CALL_LOG" 2>/dev/null | head -5)"

start_test "🔴 every configure command printed is a command executed"
if [[ "$printed_cfg" == "$executed_cfg" ]]; then
    pass_test
else
    fail_test "plan and execution differ.
  printed : $(echo "$printed_cfg" | tr '\n' '|')
  executed: $(echo "$executed_cfg" | tr '\n' '|')"
fi

start_test "and --database in particular reaches BOTH services"
n_printed=$(echo "$printed_cfg" | grep -c -- "--database" || true)
n_exec=$(echo "$executed_cfg" | grep -c -- "--database" || true)
if [[ "$n_printed" == "$n_exec" && "$n_printed" -ge 1 ]]; then
    pass_test
else
    fail_test "--database on $n_printed printed vs $n_exec executed"
fi

print_summary
