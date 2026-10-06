#!/usr/bin/env bash
# Validate the IaC, then (after apply) check the domain is really live.
#   CLOUDFLARE_API_TOKEN=... ./validate.sh [--live]
# Static (no args): tofu init -backend=false + tofu validate. Needs no token, no real state.
# --live: assumes `tofu init` has ALREADY run against the real backend in this TF_DATA_DIR/working
# dir (create.sh does this before calling here) — it does NOT re-init with -backend=false, which
# would disconnect from that real state. It then checks each tunnel exists, is healthy, and its
# DNS CNAMEs point at it.
set -euo pipefail
cd "$(dirname "$0")"
fail=0

if [ "${1:-}" = "--live" ]; then
  : "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
  tofu validate -no-color || exit 1
  echo "OK  tofu validate"
else
  tofu init -backend=false -input=false >/dev/null
  tofu validate -no-color || exit 1
  echo "OK  tofu validate"
  exit 0
fi

api() { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/$1"; }
acct=$(tofu output -json account_id 2>/dev/null | tr -d '"' || true)
[ -n "$acct" ] || acct=$(awk -F'"' '/^variable "account_id"/{f=1} f&&/default/{print $2; exit}' variables.tf)

while read -r name id; do
  status=$(api "accounts/$acct/cfd_tunnel/$id" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["status"])')
  if [ "$status" = healthy ]; then echo "OK  tunnel $name healthy"; else echo "FAIL tunnel $name is $status (needs cloudflared running with its token)"; fail=1; fi
  while read -r host; do
    base=$(echo "$host" | sed 's/^\*\.//')
    zone=""
    while [ -z "$zone" ] && [[ "$base" == *.* ]]; do
      zone=$(api "zones?name=$base" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r[0]["id"] if r else "")')
      base=${base#*.}
    done
    got=$(api "zones/$zone/dns_records?name=$host&type=CNAME" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r[0]["content"] if r else "")')
    if [ "$got" = "$id.cfargotunnel.com" ]; then echo "OK  DNS $host -> tunnel"; else echo "FAIL DNS $host -> '${got:-none}'"; fail=1; fi
  done < <(tofu output -json hostnames | python3 -c 'import json,sys;[print(h) for h in json.load(sys.stdin)["'"$name"'"]]')
done < <(tofu output -json tunnel_ids | python3 -c 'import json,sys;[print(k,v) for k,v in json.load(sys.stdin).items()]')
exit "$fail"
