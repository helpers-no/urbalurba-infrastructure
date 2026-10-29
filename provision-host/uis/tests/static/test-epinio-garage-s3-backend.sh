#!/bin/bash
# test-epinio-garage-s3-backend.sh — Epinio's S3 backend is this platform's own Garage,
# via a dedicated key, not the chart's bundled SeaweedFS and not the Garage bootstrap key.
#
# urb-agents#2040 (migrating urb-agents#1909/#1911's PoC gate 6). The bootstrap key
# (GARAGE_ACCESS_KEY/SECRET_KEY) is denied create-bucket permission right after Garage's
# own setup (047-setup-garage.yml, urb-agents#1802) - by design, so no second consumer
# can mint itself a bucket with it. Epinio's own EPINIO_GARAGE_ACCESS_KEY/SECRET_KEY must
# be imported as a NEW key instead, scoped to its own bucket.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOK="$REPO_ROOT/ansible/playbooks/625-setup-epinio.yml"

print_test_section "Epinio's S3 backend is Garage, via its own dedicated key"

start_test "the playbook is where this test thinks it is"
[[ -f "$PLAYBOOK" ]] && pass_test || { fail_test "missing: $PLAYBOOK"; print_summary; exit $?; }

start_test "control: the Helm values block this test inspects still exists"
_values_block="$(sed -n '/dest: \/tmp\/epinio-values.yaml/,/mode: /p' "$PLAYBOOK")"
if [[ -n "$_values_block" ]]; then
    pass_test
else
    fail_test "control" "the Helm values block was not found — has it moved? every check below is vacuous"
    print_summary
    exit 1
fi

start_test "🔴 seaweedfs is disabled — the chart's bundled object store must not also be running"
grep -qE '^\s*enabled:\s*false\s*$' <<< "$(sed -n '/seaweedfs:/,/^\s*s3:/p' <<< "$_values_block")" \
    && pass_test \
    || fail_test "seaweedfs.enabled: false missing" "Epinio would run two object stores at once, writing data nobody reads"

start_test "🔴 s3.accessKeyID/secretAccessKey read EPINIO_GARAGE_*, never GARAGE_ACCESS_KEY/SECRET_KEY directly"
if grep -qE 'accessKeyID:\s*"\{\{\s*epinio_garage_access_key\s*\}\}"' <<< "$_values_block" \
    && grep -qE 'secretAccessKey:\s*"\{\{\s*epinio_garage_secret_key\s*\}\}"' <<< "$_values_block"; then
    pass_test
else
    fail_test "s3 credentials wired to the dedicated fact, not the raw bootstrap secret" \
        "using GARAGE_ACCESS_KEY/SECRET_KEY directly would reuse the account-wide bootstrap key here"
fi

start_test "the Helm-values task carries no_log (the rendered content includes a real secret)"
_task_block="$(sed -n '/name: 9\. Write temporary Helm values/,/mode: .0600./p' "$PLAYBOOK")"
grep -qE '^\s*no_log:\s*true\s*$' "$PLAYBOOK" \
    && pass_test \
    || fail_test "no_log: true not found anywhere in the playbook" "the secret value could land in Ansible's own verbose/diff output"

start_test "the dedicated key is imported via 'garage key import' (never 'garage key new', which would discard the pre-generated secret)"
pb="$(grep -v '^[[:space:]]*#' "$PLAYBOOK")"
grep -qF '/garage key import' <<< "$pb" \
    && pass_test \
    || fail_test "garage key import not found" "epinio_garage_secret_key would never actually reach Garage"

start_test "key import is guarded by an existence check on the key ID (idempotent, and correct after the ID rotates)"
if grep -qF 'when: epinio_garage_access_key not in epinio_garage_key_list.stdout' <<< "$pb"; then
    pass_test
else
    fail_test "import not guarded by ID" "a name check skips importing a ROTATED key ID whenever an old key still carries the name, leaving the configured key unknown to Garage (urb-agents#2057)"
fi

start_test "...and the guard does NOT compare the key name"
if grep -qF 'epinio_garage_key_name not in epinio_garage_key_list' <<< "$pb"; then
    fail_test "name-based guard is back" "found live (urb-agents#2057): after an ID rotation the old key keeps the name, so the new ID is never imported and every push fails with a 403"
else
    pass_test
fi

start_test "the key is granted read+write on its OWN bucket only (--key + a bucket name, not account-wide)"
if grep -qE '/garage bucket allow\s*$' <<< "$pb" && grep -qF -- '--key {{ epinio_garage_access_key }} --read --write {{ epinio_garage_bucket }}' <<< "$pb"; then
    pass_test
else
    fail_test "bucket allow not scoped correctly" "the key could end up with no access, or with account-wide rights — or, granted by name, hit the wrong key once two share it"
fi

print_summary
