#!/bin/bash
# test-cloudflare-create.sh — `uis network create cloudflare` (OpenTofu-backed tunnel creation).
#
# WHY THIS EXISTS. Tunnel creation itself used to be 100% manual (a human, or a
# browser-controlling LLM per urb-agents#1876, clicking through the dashboard).
# create.sh automates it via a vendored OpenTofu module, then hands the result
# to init.sh's --from-key path — the same sanctioned writer the manual path
# already used. These tests pin that create.sh rejects bad input BEFORE it
# ever reaches tofu/the Cloudflare API (the same "fail fast, before the real
# external command" convention test-cloudflare-multi-env.sh already
# established for the other scripts), and that it never guesses at state
# storage — every path it touches is computed from cloudflare-envs.sh and the
# per-env state directory, never a literal.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/networking/cloudflare/scripts" ]]; then
    CF_SCRIPTS="/mnt/urbalurbadisk/networking/cloudflare/scripts"
    TOFU_DIR="/mnt/urbalurbadisk/networking/cloudflare/tofu"
else
    CF_SCRIPTS="$(cd "$SCRIPT_DIR/../../../../networking/cloudflare/scripts" && pwd)"
    TOFU_DIR="$(cd "$SCRIPT_DIR/../../../../networking/cloudflare/tofu" && pwd)"
fi
CREATE_SH="$CF_SCRIPTS/create.sh"

print_test_section "Cloudflare tunnel creation (create.sh / OpenTofu) Tests"

start_test "create.sh exists and is executable"
if [[ -x "$CREATE_SH" ]]; then
    pass_test
else
    fail_test "missing or not executable: $CREATE_SH"
fi

start_test "create.sh sources cloudflare-envs.sh (one canonical list, not its own copy)"
if grep -q 'cloudflare-envs.sh' "$CREATE_SH"; then
    pass_test
else
    fail_test "create.sh does not source the canonical env list"
fi

start_test "create.sh requires --env (unlike init/up/down/verify/status, where it's optional)"
out="$(bash "$CREATE_SH" --domain example.com < /dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qi -- "--env is required" <<<"$out"; then
    pass_test
else
    fail_test "expected a clean '--env is required', got (rc=$rc): $out"
fi

start_test "create.sh rejects an unknown --env before touching tofu/the API"
out="$(bash "$CREATE_SH" --env not-a-real-env --domain example.com < /dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qi "Unknown --env" <<<"$out"; then
    pass_test
else
    fail_test "create.sh did not cleanly reject an unknown --env (rc=$rc): $out"
fi

start_test "create.sh requires --domain"
out="$(bash "$CREATE_SH" --env test < /dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -qi -- "--domain is required" <<<"$out"; then
    pass_test
else
    fail_test "expected a clean '--domain is required', got (rc=$rc): $out"
fi

start_test "create.sh checks for the tofu binary before doing anything else"
if grep -q 'command -v tofu' "$CREATE_SH"; then
    pass_test
else
    fail_test "no 'command -v tofu' guard — a missing binary would fail deep inside tofu init instead of with a clear message"
fi

start_test "create.sh resolves the API token from its own file, not the tunnel-token file"
if grep -q 'cloudflare-api.env' "$CREATE_SH" && ! grep -q 'service-keys/cloudflare.env' "$CREATE_SH"; then
    pass_test
else
    fail_test "create.sh should read cloudflare-api.env (a different credential), not cloudflare.env"
fi

start_test "create.sh computes STATE_DIR under .uis.secrets/cloudflare/tofu/<env>, not next to the vendored module"
if grep -q '\.uis\.secrets/cloudflare/tofu/\$CF_ENV_LOWER' "$CREATE_SH"; then
    pass_test
else
    fail_test "state directory is not computed per-env under .uis.secrets — it would land in the baked-in image path instead"
fi

start_test "create.sh passes var.out_dir so the generated .key never lands in the image-baked module path"
if grep -q 'out_dir=\$STATE_DIR/out' "$CREATE_SH"; then
    pass_test
else
    fail_test "missing -var out_dir=... — the .key file (containing TUNNEL_SECRET) would be written under networking/cloudflare/tofu/out/, which is baked into the image and not host-persistent"
fi

start_test "create.sh asks for confirmation before tofu apply unless --yes is given"
if grep -qE 'Apply this plan' "$CREATE_SH" && grep -q -- '--yes' "$CREATE_SH"; then
    pass_test
else
    fail_test "no confirm-before-apply gate — this creates real, billable, DNS-affecting cloud resources"
fi

start_test "create.sh refuses to apply without --yes when stdin is not a TTY"
out="$(echo "" | bash "$CREATE_SH" --env test --domain example.com 2>&1)"; rc=$?
# Fails earlier (no tofu installed in this test environment) is also an acceptable, equally-safe
# outcome — the point is it must NOT silently proceed to apply.
if [[ $rc -ne 0 ]]; then
    pass_test
else
    fail_test "create.sh exited 0 with no confirmation and no --yes — that must never happen"
fi

start_test "create.sh wires the result into init.sh's --from-key path, not a second writer"
if grep -q 'init.sh' "$CREATE_SH" && grep -q -- '--from-key' "$CREATE_SH"; then
    pass_test
else
    fail_test "create.sh should hand off to init.sh --from-key — writing the secrets files itself would duplicate that logic"
fi

start_test "create.sh does not chain into up.sh/verify.sh (prints next steps, stops)"
if ! grep -qE '\bup\.sh\b|\bverify\.sh\b' "$CREATE_SH"; then
    pass_test
else
    fail_test "create.sh appears to invoke up.sh/verify.sh directly — confirmed decision was to stop after creation and print next steps"
fi

# ---------------------------------------------------------------------------
# The vendored OpenTofu module itself — static checks only (no `tofu` binary
# assumed present in this test environment; real plan/apply is a live,
# account-touching check done separately, not here).
# ---------------------------------------------------------------------------
start_test "tofu module directory was vendored"
if [[ -d "$TOFU_DIR" ]]; then
    pass_test
else
    fail_test "missing: $TOFU_DIR"
fi

for f in README.md versions.tf variables.tf main.tf outputs.tf terraform.tfvars.example validate.sh tunnel-health.sh .gitignore modules/tunnel/main.tf modules/tunnel/variables.tf modules/tunnel/outputs.tf; do
    start_test "tofu/$f exists"
    assert_file_exists "$TOFU_DIR/$f" && pass_test
done

start_test "main.tf's key file uses var.out_dir, not a hardcoded path.module/out"
if grep -q 'local.out_dir' "$TOFU_DIR/main.tf" && ! grep -qE '"\$\{path\.module\}/out/\$\{each\.key\}' "$TOFU_DIR/main.tf"; then
    pass_test
else
    fail_test "main.tf still hardcodes its output path — create.sh's out_dir override would do nothing"
fi

start_test "validate.sh's --live branch does not re-init with -backend=false"
# A single `tofu init -backend=false` call guards the static-only branch (exits before --live
# is even checked); this counts actual invocations, not the comments explaining why — more
# than one real call here would mean the --live branch also re-runs it, which would disconnect
# from the real state create.sh already set up.
if [[ "$(grep -cE '^\s*tofu init .*-backend=false' "$TOFU_DIR/validate.sh")" -eq 1 ]]; then
    pass_test
else
    fail_test "expected exactly one 'tofu init ... -backend=false' call (the static-only branch); --live must trust the caller's existing tofu init"
fi

print_summary
