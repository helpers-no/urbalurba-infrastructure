#!/usr/bin/env bash
# Read-only health check for Cloudflare tunnels. No OpenTofu or state needed.
#   CLOUDFLARE_API_TOKEN=... ./tunnel-health.sh [options] [tunnel-name ...]
# With no names it checks every tunnel in the account. Exit 0 = all checked tunnels healthy (and HTTP checks passed),
# 1 = at least one problem, 2 = usage/API error.
#   --http <host>   also request https://<host>/ and fail on 5xx from Cloudflare's tunnel errors (530, 1033, 502, 503, 504).
#                   Repeatable. A 404 from the origin is fine: it proves the path tunnel -> Traefik works.
#   --account <id>  Cloudflare account id (default: $CF_ACCOUNT_ID or the urbalurba account)
#   --json          machine-readable output
# Needs: curl, python3. Token permission: Account > Cloudflare Tunnel (Read is enough).
set -uo pipefail
ACCOUNT="${CF_ACCOUNT_ID:-97e30a13fdbed4f09e53db9aba18d144}"
json=0; hosts=(); names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --http) hosts+=("$2"); shift 2 ;;
    --account) ACCOUNT="$2"; shift 2 ;;
    --json) json=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) names+=("$1"); shift ;;
  esac
done
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"

resp=$(curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/cfd_tunnel?is_deleted=false&per_page=100") || { echo "API request failed" >&2; exit 2; }

NAMES="${names[*]:-}" HOSTS="${hosts[*]:-}" JSON=$json RESP="$resp" python3 - <<'PY'
import json, os, subprocess, sys
r = json.loads(os.environ["RESP"])
if not r.get("success"):
    print("API error:", r.get("errors"), file=sys.stderr); sys.exit(2)
want = os.environ["NAMES"].split()
tunnels = [t for t in r["result"] if not want or t["name"] in want]
missing = [n for n in want if n not in {t["name"] for t in tunnels}]
out, bad = [], bool(missing)
for t in tunnels:
    conns = t.get("connections") or []
    ok = t["status"] == "healthy" and len(conns) > 0
    bad |= not ok
    out.append({"kind": "tunnel", "name": t["name"], "id": t["id"], "status": t["status"],
                "connections": len(conns), "colos": sorted({c.get("colo_name", "?") for c in conns}), "ok": ok})
for n in missing:
    out.append({"kind": "tunnel", "name": n, "status": "not found", "ok": False})
for h in os.environ["HOSTS"].split():
    try:
        code = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-m", "15", "-w", "%{http_code}", f"https://{h}/"],
                              capture_output=True, text=True).stdout.strip() or "000"
    except Exception:
        code = "000"
    ok = code not in ("000", "502", "503", "504", "530") and not code.startswith("52")
    bad |= not ok
    out.append({"kind": "http", "host": h, "code": code, "ok": ok})
if os.environ["JSON"] == "1":
    print(json.dumps({"ok": not bad, "checks": out}, indent=2))
else:
    for o in out:
        tag = "OK  " if o["ok"] else "FAIL"
        if o["kind"] == "tunnel":
            extra = f'{o["connections"]} connection(s) {",".join(o["colos"])}' if "connections" in o else ""
            print(f'{tag} tunnel {o["name"]}: {o["status"]} {extra}'.rstrip())
        else:
            print(f'{tag} https://{o["host"]}/ -> HTTP {o["code"]}')
sys.exit(1 if bad else 0)
PY
