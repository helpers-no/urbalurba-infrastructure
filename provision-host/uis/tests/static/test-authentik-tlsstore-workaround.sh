#!/bin/bash
# test-authentik-tlsstore-workaround.sh — the TLSStore workaround is wired consistently
#
# See INVESTIGATE-system-traefik-incluster-sni.md: tls.secretName on Authentik's own
# IngressRoute never loads a certificate on this cluster (confirmed live via imac's debug
# capture, urb-agents#2046) — a first fix attempt (tls.domains, PR #647) was shipped,
# re-tested live, and retracted (PR #648). This exercises a different, source-verified
# code path (the TLSStore CRD) instead. This cannot prove it actually works against a real
# cluster — only imac's live test can — it proves the files agree with each other and that
# this does not quietly get reframed as "the fix" before that live test confirms it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MANIFEST="$REPO/manifests/076-authentik-tlsstore.yaml"
SETUP="$REPO/ansible/playbooks/070-setup-authentik.yml"
REMOVE="$REPO/ansible/playbooks/070-remove-authentik.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== Authentik TLSStore workaround: wired consistently ==="

[[ -f "$MANIFEST" && -f "$SETUP" && -f "$REMOVE" ]] || {
    fail "every file this workaround needs exists" "one or more missing: $MANIFEST / $SETUP / $REMOVE"
    echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
}

# ── the manifest itself: right kind, right name, right secret ──

_YAMLCHECK=""
if [[ -f "$REPO/website/node_modules/js-yaml/package.json" ]]; then
    _YAMLCHECK="node -e \"
      const y=require('$REPO/website/node_modules/js-yaml');
      const fs=require('fs');
      const d=y.load(fs.readFileSync('$MANIFEST','utf8'));
      console.log(JSON.stringify(d));
    \""
fi

if [[ -n "$_YAMLCHECK" ]]; then
    _doc="$(eval "$_YAMLCHECK" 2>/tmp/tlsstore-yaml-err)"
    if [[ -z "$_doc" ]]; then
        fail "the manifest parses as YAML" "$(cat /tmp/tlsstore-yaml-err)"
    else
        pass "the manifest parses as YAML"
        _check="$(node -e "
          const d=$_doc;
          const ok = d.apiVersion === 'traefik.io/v1alpha1'
            && d.kind === 'TLSStore'
            && d.metadata.name === 'default'
            && d.metadata.namespace === 'authentik'
            && d.spec.defaultCertificate.secretName === 'authentik-server-tls';
          console.log(ok ? 'OK' : 'BAD');
        ")"
        if [[ "$_check" == "OK" ]]; then
            pass "it is a TLSStore named 'default' pointing at authentik-server-tls, in namespace authentik"
        else
            fail "it is a TLSStore named 'default' pointing at authentik-server-tls, in namespace authentik" "got: $_doc"
        fi
    fi
else
    # text fallback, no js-yaml on this host
    _n=0
    grep -qE '^kind:\s*TLSStore' "$MANIFEST" && _n=$((_n+1))
    grep -qE '^\s*name:\s*default\s*$' "$MANIFEST" && _n=$((_n+1))
    grep -qE '^\s*namespace:\s*authentik\s*$' "$MANIFEST" && _n=$((_n+1))
    grep -qE '^\s*secretName:\s*authentik-server-tls\s*$' "$MANIFEST" && _n=$((_n+1))
    if [[ "$_n" -eq 4 ]]; then
        pass "it is a TLSStore named 'default' pointing at authentik-server-tls, in namespace authentik (text scan)"
    else
        fail "it is a TLSStore named 'default' pointing at authentik-server-tls, in namespace authentik (text scan)" "only $_n of 4 markers found"
    fi
fi

# ── this is not silently reframed as "fixed"/"confirmed" ──
# 🔴 the exact discipline this whole chain exists to enforce, after PR #647's wrong
# "root cause confirmed" claim had to be retracted live — any future edit to this
# manifest that drops the "unverified live" framing should fail loudly, not quietly ship.
if grep -qi "unverified live" "$MANIFEST" && grep -qi "do not treat this as \"the fix\"" "$MANIFEST"; then
    pass "the manifest does not claim this is confirmed working"
else
    fail "the manifest does not claim this is confirmed working" "the 'unverified live' caveat is missing or was weakened"
fi

if grep -qi "cluster-wide default" "$MANIFEST" || grep -qi "cluster-wide, not a per-route fix" "$MANIFEST"; then
    pass "the single-slot / cluster-wide-default caveat is documented"
else
    fail "the single-slot / cluster-wide-default caveat is documented" "no warning found — a future reader would assume this scales to a second service"
fi

# ── setup playbook applies it, after the cert is confirmed Ready ──

if grep -qF 'authentik_tlsstore_file: "{{ manifests_folder }}/076-authentik-tlsstore.yaml"' "$SETUP"; then
    pass "setup declares authentik_tlsstore_file pointing at the real manifest"
else
    fail "setup declares authentik_tlsstore_file pointing at the real manifest" "var missing or path wrong"
fi

if grep -qF 'kubectl apply -f {{ authentik_tlsstore_file }}' "$SETUP"; then
    pass "setup applies the TLSStore manifest"
else
    fail "setup applies the TLSStore manifest" "no apply task found"
fi

# Ordering: the apply task must come AFTER the "wait for cert Ready" task, since
# buildTLSStores() fetches the Secret by name and a not-yet-issued cert would fail it.
_cert_wait_line="$(grep -n '36.2. Wait for the certificate to be issued' "$SETUP" | head -1 | cut -d: -f1)"
_tlsstore_line="$(grep -n 'kubectl apply -f {{ authentik_tlsstore_file }}' "$SETUP" | head -1 | cut -d: -f1)"
if [[ -n "$_cert_wait_line" && -n "$_tlsstore_line" && "$_tlsstore_line" -gt "$_cert_wait_line" ]]; then
    pass "the TLSStore is applied after the certificate is confirmed Ready, not before"
else
    fail "the TLSStore is applied after the certificate is confirmed Ready, not before" "cert-wait at line ${_cert_wait_line:-?}, apply at line ${_tlsstore_line:-?}"
fi

# ── remove playbook tears it down too ──

if grep -qF 'authentik_tlsstore_file: "{{ manifests_folder }}/076-authentik-tlsstore.yaml"' "$REMOVE"; then
    pass "remove declares authentik_tlsstore_file"
else
    fail "remove declares authentik_tlsstore_file" "var missing in remove playbook"
fi

if grep -qF 'src: "{{ authentik_tlsstore_file }}"' "$REMOVE"; then
    pass "remove tears down the TLSStore"
else
    fail "remove tears down the TLSStore" "no absent task referencing authentik_tlsstore_file"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
