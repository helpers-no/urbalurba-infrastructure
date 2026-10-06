# Cloudflare tunnel + DNS for a domain (OpenTofu)

One remotely managed cloudflared tunnel per entry in `var.tunnels`, its routes (`<domain>`, `*.<domain>` ->
Traefik in the cluster), proxied CNAMEs, and `out/<name>.key` in the #1876 format (ENV, TUNNEL_NAME, TUNNEL_ID,
ACCOUNT_ID, TUNNEL_SECRET = the token's "s" field verbatim).

Normally you don't run `tofu` directly — `uis network create cloudflare --env <name> --domain <domain>`
wraps everything below (token resolution, per-env state directory, plan confirmation, and feeding the
resulting key file straight into `uis network init cloudflare --env <name> --from-key ...`). This module
and these scripts are what that command runs; they're documented standalone here for anyone validating
or debugging the IaC directly.

## 0. Create the Cloudflare API token (once; done by hand in the dashboard)
Dashboard > My Profile > API Tokens > Create Token > Create Custom Token (https://dash.cloudflare.com/profile/api-tokens).
- Name: `opentofu-urbalurba-tunnels`
- Permissions (3 rows):
  1. Account | Cloudflare Tunnel | Edit
  2. Zone | DNS | Edit
  3. Zone | Zone | Read
- Account Resources: Include > the account (Cloudflare Tunnel applies account-wide).
- Zone Resources: Include > Specific zone, once per domain (e.g. `urbalurba.no`, `urbalurba.eu`). Do NOT use "All zones"
  (that would allow DNS edits on domains this token has no business touching). Add each new domain to the token before
  running the install command for it.
- No IP filtering, no TTL. Continue to summary > Create Token.
- Cloudflare shows the token (`cfut_...`) ONCE. Store it as documented in
  `provision-host/uis/templates/uis.secrets/service-keys/cloudflare-api.env.template` (mode 600); never commit it,
  never post it. Lost it? Create a new one; the old one cannot be read back.
The token cannot be created by this IaC (that needs a broader token), so this step stays manual.

Install command, per domain (via UIS):
```bash
uis network create cloudflare --env test --domain urbalurba.eu
```

Running `tofu` by hand instead (for debugging — not the normal path):
```bash
export CLOUDFLARE_API_TOKEN=...   # the token from step 0
cp terraform.tfvars.example <domain>.tfvars   # set name/domain/env
tofu init && tofu apply -var-file=<domain>.tfvars
./validate.sh --live              # static validate + tunnel healthy + CNAMEs point at the tunnel
```
`./validate.sh` alone runs only `tofu init -backend=false` + `tofu validate` (needs no token). `./validate.sh --live`
assumes a real `tofu init` already ran in this working directory/`TF_DATA_DIR` — it does not re-init with
`-backend=false`, which would disconnect from the real state (`create.sh` handles this ordering).

Notes: an existing record on `@` makes apply fail by design (it never overwrites). Tunnel shows Inactive/Down until
cloudflared runs with the token. The secret lands in state: keep state private, enable OpenTofu state encryption.
Subdomain of an existing zone: add `zone = "example.com"` to the entry (domain = "app.example.com").
`uis network create cloudflare` keeps each environment's state under
`.uis.secrets/cloudflare/tofu/<env>/` on the host (via `TF_DATA_DIR` + a `-backend-config` path override) rather than
next to this module — this module's own directory is baked into the provision-host image and isn't host-persistent.

Tested end to end on the real account with a throwaway tunnel `iac-test` (iactest.urbalurba.eu): `tofu apply` (5 resources),
key file written (mode 600, 5 fields), `./validate.sh --live` failed correctly while the tunnel was inactive (exit 1) and passed
(exit 0) with cloudflared connected using a token rebuilt from the .key fields; then destroyed and verified gone.

Health check any time (read-only, no tofu needed): `./tunnel-health.sh [--http <host>] [tunnel-name ...]`
