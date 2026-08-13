# Investigate: Set Gravitee config correctly at deploy time (no post-deploy patching)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Closed (2026-05-05) — all in-scope findings resolved

All actionable findings shipped or accept-with-doc'd via PLAN-gravitee-disable-hpa-dev (Finding 8), PLAN-001-gravitee-org-name (Finding 3), and PLAN-002-gravitee-db-baked-urls (Finding 2). Finding 4-Console + 4-Portal closed inline (relative baseURLs, sub-path consolidation). Finding 1 closed as a side-effect of Finding 4-Portal. Finding 5 demoted (does not reproduce). Findings 6 and 7 confirmed out-of-scope / non-actionable. Finding 4-api-side accept-with-doc'd in `gravitee.md` ("Cross-domain redirects use chart-baked URLs") — chart has no surface for `forwardHeadersStrategy` and the api pod's Spring URI constructor rejects relative `installation.api.url`; closing this for cross-domain installs requires an upstream Gravitee patch. Round 9 also surfaced an unrelated upstream chart bug (`templates/api/api-deployment.yaml` emits a literal-dot `portal.entrypoint` env var that POSIX rules silently strip) worth filing against `gravitee-io/helm-charts` when convenient.

This document is preserved as the diagnostic trail. PLAN-002 carries the close-out summary; this file's status reflects the broader investigation.



**Goal**: Close the in-scope gaps surfaced by the post-merge browser audit of Gravitee APIM 4.11 by **setting every value correctly the first time** — through chart values, helm flags, env vars, init containers, or custom Liquibase changesets — rather than by patching values via post-deploy management-API calls. The drop-database test (below) must pass: after wiping `graviteedb` and `./uis deploy gravitee`, every in-scope audit-verified surface comes up correct without any subsequent management-API mutation. (Findings 6 SMTP and 7 admin-email are explicitly out-of-scope / non-actionable; see those sections.)

**Last Updated**: 2026-05-03

**Request origin**: Browser-tester audit run after PR #137 (gravitee deploy) and PR #139 (undeploy route count) merged. Audit report and tester response live in the contributor's testing area outside this repo (`/learn/helpers/testing/uis1/talk/gravitee-config-audit.md` and `/learn/helpers/testing/uis1/talk/talk.md`); the relevant excerpts that informed the findings below are quoted inline rather than referenced. The audit verified 11 of 13 surfaces correct; the remaining items are tracked here. Maintainer reframed the investigation: "i want the investigation to focus on how to set the variables correct in the first place and not how to change what we have so that it is correct."

**Depends on**: [INVESTIGATE-service-email-smtp.md](../backlog/INVESTIGATE-service-email-smtp.md) for the SMTP gap (Gravitee email is one of several services that needs a UIS-level SMTP relay). Everything else in this plan is local to Gravitee.

**Phase 0 status (2026-05-04, all open questions resolved)**: nine open questions answered across tester rounds 1, 1.5 (read-only experiments + fresh-DB baseline), 3 (OQ4 — Console relative baseURL), 5 (OQ8 + system-wide `DEFAULT_AUTOSCALING` — shipped via PLAN-gravitee-disable-hpa-dev), and 6/6.5 (OQ5 — Portal sub-path consolidation). OQ1 and OQ2 demoted to fallbacks and not run. Finding 1 resolved as a side effect of OQ5. Finding 5 demoted (does not reproduce as a functional bug). Finding 8 shipped. **All chart/ingress experiments closed; next step is PLAN-001+ for the remaining deploy-time fixes (Findings 2 + 3 + Finding 4 api-side).**

---

## The acceptance test (the drop-database test)

A change to UIS Gravitee deployment is correct when, starting from any state, this sequence ends with all in-scope audit findings green **without any post-deploy patching**.

**Test environment assumption:** the script hits `http://127.0.0.1:80` with custom `Host:` headers to exercise Traefik routing for synthetic hostnames. This works on Rancher Desktop where Traefik is exposed on the host network. On other clusters (kind, microk8s, k3d, port-forward) the bind address may differ — adjust the URL or run from inside the cluster. The basic `gravitee.localhost` checks don't have this dependency.

**Runtime:** `./uis undeploy --purge && ./uis deploy gravitee` takes ~1–2 minutes wall-clock (graviteedb is recreated, Liquibase runs from zero, all four pods cold-start). This is an integration test, not a unit test — expect to run it once per change, not in a loop.

```bash
# Bail on any unhandled error so setup failures don't masquerade as Finding
# failures further down.
set -eu

# Setup: source the credentials and intended values from the in-cluster secret
# (no hardcoded passwords; mirrors how the playbook reads them).
ADMIN_PASS=$(./uis exec kubectl get secret urbalurba-secrets -n gravitee \
              -o jsonpath='{.data.GRAVITEE_ADMIN_PASSWORD}' | base64 -d)
[ -n "$ADMIN_PASS" ] \
  || { echo "SETUP FAIL: GRAVITEE_ADMIN_PASSWORD missing from gravitee/urbalurba-secrets"; exit 1; }
ORG_NAME=$(./uis exec kubectl get secret urbalurba-secrets -n gravitee \
              -o jsonpath='{.data.GRAVITEE_ORG_NAME}' | base64 -d)
[ -n "$ORG_NAME" ] \
  || { echo "SETUP FAIL: GRAVITEE_ORG_NAME missing from gravitee/urbalurba-secrets (check that DEFAULT_ORGANIZATION_NAME flows through)"; exit 1; }

# 1. Wipe everything Gravitee-side. Also drops the graviteedb so Liquibase
#    runs from zero on the next deploy — exercises the bootstrap path.
./uis undeploy gravitee --purge \
  || { echo "SETUP FAIL: undeploy --purge failed; cluster state unknown"; exit 1; }

# 2. Fresh deploy. This is the only mutation allowed.
./uis deploy gravitee \
  || { echo "SETUP FAIL: ./uis deploy gravitee failed; subsequent checks would be spurious"; exit 1; }

# 3. Verify (no PUT/POST/PATCH allowed — read-only checks).

# --- Finding 1: constants.json should not have duplicate portal.entrypoint keys.
#     A naive jq '.portal.entrypoint' silently picks the last duplicate, so use
#     a count-of-keys query instead.
DUP=$(curl -fsS http://gravitee.localhost/constants.json \
  | jq '[.portal | to_entries[] | select(.key=="entrypoint")] | length')
[ "$DUP" = "1" ] || { echo "FAIL: constants.json has $DUP entrypoint keys"; exit 1; }

# --- Finding 3: organisation name reflects DEFAULT_ORGANIZATION_NAME, not the
#     chart placeholder.
curl -fsS -u admin:"$ADMIN_PASS" \
  http://gravitee.localhost/management/organizations/DEFAULT \
  | jq -e --arg n "$ORG_NAME" '.name == $n' \
  || { echo "FAIL: org name not '$ORG_NAME'"; exit 1; }

# --- Finding 2: environment-level portalEntrypoint must not be the chart
#     placeholder, AND the api pod must construct outbound URLs from
#     X-Forwarded-Host (not from a baked-in DB column). The first half is
#     a sanity check; the second half is the load-bearing assertion.

# 2a. Sanity: DB column is not the chart placeholder.
curl -fsS -u admin:"$ADMIN_PASS" \
  http://gravitee.localhost/management/organizations/DEFAULT/environments/DEFAULT/settings \
  | jq -e '.portal.entrypoint | test("api\\.company\\.com") | not' \
  || { echo "FAIL: portalEntrypoint still has the chart placeholder"; exit 1; }

# 2b. Load-bearing: the api pod must echo the requesting host in any URL it
#     emits. Trigger a redirect (the portal-redirect endpoint emits a Location
#     header) and inspect what hostname comes back.
#
#     Assumption (see Open Question 9): /portal/redirect returns 3xx with an
#     absolute Location header. The audit confirmed it redirects to
#     gravitee-portal.localhost on the current install, but the absolute-vs-
#     relative shape is verified at PLAN-phase, not assumed.
#
#     A request via Host: gravitee.test.example must Location-redirect to a
#     URL whose host matches *test.example, NOT *.localhost. Localhost in
#     the response means the api ignored X-Forwarded-Host.
# Note: -f is dropped here on purpose — we need to capture the status code
# even when it's 4xx/5xx so the case statement below can produce a meaningful
# diagnostic. With -f, curl writes nothing on errors and STATUS would be empty.
RESP=$(curl -sS -o /dev/null -D - -w 'STATUS=%{http_code}\n' \
  -H "Host: gravitee.test.example" \
  -H "X-Forwarded-Host: gravitee.test.example" \
  -H "X-Forwarded-Proto: https" \
  -u admin:"$ADMIN_PASS" \
  http://127.0.0.1/management/organizations/DEFAULT/environments/DEFAULT/portal/redirect)
STATUS=$(echo "$RESP" | awk -F= '/^STATUS=/{print $2}')
LOC=$(echo "$RESP" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')

case "$STATUS" in
  3??) ;;
  *) echo "FAIL: /portal/redirect returned status $STATUS (expected 3xx with Location)"; exit 1 ;;
esac
[ -n "$LOC" ] || { echo "FAIL: /portal/redirect returned $STATUS but no Location header"; exit 1; }
case "$LOC" in
  /*) echo "INFO: relative Location ($LOC) — same-origin, X-Forwarded-Host moot for this endpoint" ;;
  *test.example*) echo "PASS: api honoured X-Forwarded-Host" ;;
  *localhost*) echo "FAIL: api ignored X-Forwarded-Host (Location: $LOC)"; exit 1 ;;
  *) echo "FAIL: unexpected Location host: $LOC"; exit 1 ;;
esac

# --- Finding 4: same constants.json must work on any hostname Traefik routes.
#     Compare the SHA256 of constants.json fetched via two different host
#     headers; they must be byte-identical.
HASH_LOCAL=$(curl -fsS -H "Host: gravitee.localhost" \
  http://127.0.0.1/constants.json | sha256sum | cut -d' ' -f1)
HASH_OTHER=$(curl -fsS -H "Host: gravitee.test.example" \
  http://127.0.0.1/constants.json | sha256sum | cut -d' ' -f1)
[ "$HASH_LOCAL" = "$HASH_OTHER" ] \
  || { echo "FAIL: constants.json differs between hostnames"; exit 1; }

# --- Finding 5: /ui/customization should ideally not 5xx. 200 / 404 = good;
#     503 = current upstream behaviour (documented, not blocking); anything
#     else (500 with stack trace, etc.) = regression worth investigating.
#     This check is informational only — Finding 5 is upstream-gated and
#     does NOT cause the test to fail. See Finding 5 for context.
# -f dropped (see Finding 2b explanation): we want the actual status code,
# including 503/500, so the case statement can categorise it correctly.
CUST_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' \
  -u admin:"$ADMIN_PASS" \
  http://gravitee.localhost/management/v2/organizations/DEFAULT/ui/customization \
  || echo "ERR")
case "$CUST_STATUS" in
  200|404) echo "Finding 5: PASS (upstream patched — endpoint returns $CUST_STATUS)" ;;
  503)     echo "Finding 5: KNOWN (current upstream behaviour, 503; not a regression)" ;;
  ERR)     echo "Finding 5: WARN — curl could not connect (network/Traefik issue, not a Gravitee bug)" ;;
  *)       echo "Finding 5: WARN — unexpected status $CUST_STATUS, investigate" ;;
esac

# --- Finding 8: no HPA objects should exist; exactly four Running pods.
#     The playbook's wait-for-readiness step should ensure the rollout has
#     settled before this test runs, but filter on Running phase anyway to
#     avoid double-counting Terminating old replicas during a redeploy race.
HPA_COUNT=$(./uis exec kubectl -n gravitee get hpa --no-headers 2>/dev/null | wc -l)
[ "$HPA_COUNT" = "0" ] \
  || { echo "FAIL: $HPA_COUNT HPA objects still present"; exit 1; }
POD_COUNT=$(./uis exec kubectl -n gravitee get pods --no-headers \
  --field-selector=status.phase=Running \
  -l app.kubernetes.io/instance=gravitee-apim | wc -l)
[ "$POD_COUNT" = "4" ] \
  || { echo "FAIL: $POD_COUNT Running pods (expected 4: api, gateway, ui, portal)"; exit 1; }

echo "All in-scope checks passed."
```

If any of those reads requires a follow-up `PUT` to fix, the deploy-time configuration is incomplete and the change does not land. Findings 6 (SMTP) and 7 (admin email) are intentionally absent from the test — see their sections.

---

## What the audit found, and where each value comes from

For each finding, the investigation must determine **the layer at which the wrong value originates**. The remediation chain to investigate is, in priority order:

1. **Chart values** in `manifests/090-gravitee-config.yaml` (helm renders them into `gravitee.yml` ConfigMap).
2. **`--set-string` / `--set` overrides** in `helm install/upgrade` (playbook task 24).
3. **Pod env vars** — Gravitee's Spring Boot stack maps any `GRAVITEE_<NESTED_KEY>` env var to a `gravitee.yml` property override; e.g. `GRAVITEE_INSTALLATION_API_URL` → `installation.api.url`. Worth checking which DB-backed values *also* support this override convention.
4. **Custom Liquibase changeset** mounted via init container or extra volume so it runs after the chart's seed migrations and overwrites the placeholders. Risky (chart upgrade may collide), but a real lever.
5. **Pre-install init container** that seeds the DB before the api pod starts. Same risk profile as #4.
6. **Post-deploy management-API PUT** (last resort — the approach this investigation explicitly rejects unless every other lever has been ruled out).

### Finding 1 — `constants.json` ships a duplicate `portal.entrypoint` key

**Symptom:** `curl http://gravitee.localhost/constants.json | jq '.portal'` shows two `entrypoint` entries — first the chart default `https://apim.example.com/`, then our `ui.portal.entrypoint` override `http://gravitee-portal.localhost/`. Browser parsers take the last value (works in practice), but the artefact is fragile.

**Where the value comes from:** the chart's `templates/_helpers.tpl` (chart 4.11.x) emits a hardcoded `entrypoint: https://apim.example.com/` then iterates over `.Values.ui.portal` to append more keys, double-emitting whenever `ui.portal.entrypoint` is set in values.

**Note:** Finding 4 (relative URLs) does *not* make this finding moot. Finding 4's relative-URL recommendation applies to `ui.baseURL` and `portal.baseURL`, not to `ui.portal.entrypoint` — `ui.portal.entrypoint` points at a *different hostname* (`gravitee-portal.<domain>`), where a relative URL doesn't resolve correctly. The duplicate-key issue here must be fixed independently.

**OQ7 resolved (Round 1, 2026-05-03):** the chart's `helm template` output (against our `090-gravitee-config.yaml`) emits the rendered `constants.json` with the chart-default literal `entrypoint: "https://apim.example.com/"` *first*, then iterates the user-supplied `ui.portal` keys, including our override `entrypoint: "http://gravitee-portal.localhost/"` *second*. Both entries appear in the same `portal:` JSON block. The duplicate-key emission is structural in the helper template — **no chart conditional or value path suppresses it.**

**Probe-design note** (Round 1.5): a `jq '... | length'` count probe on the served `constants.json` returns `1` because JSON parsers (including `jq`) deduplicate keys with last-wins semantics. The duplicate is real at the file level (verified in `helm template` output) but invisible to schema-aware parsers. Use a raw-text grep — `curl ... | grep -c '"entrypoint"'` — to detect it. Browser parsers behave the same way as `jq` (last-wins), so the duplicate is *fragile* (any parser that errors on duplicate keys would break) but not currently *broken*.

**Levers, given OQ7:**
- ~~Chart-side replacement-form override~~ — ruled out by OQ7.
- ~~`ui.portal.useDefaults: false`-style suppress knob~~ — ruled out by OQ7.
- **If Finding 4 path (a) wins** (Portal consolidated under `gravitee.<domain>/_portal/`, same-origin), `ui.portal.entrypoint` becomes a relative URL (`/_portal/`) and the duplicate-key is structurally harmless — the chart still emits both, but the *override* (which last-wins picks) is now a relative path that resolves to whichever hostname the page came from. Cleanest outcome. **Gated on OQ5** (does the Portal SPA tolerate a sub-path?).
- **Otherwise** — file an upstream issue against `gravitee-io/helm-charts` requesting a `useDefaults: false` knob (or a chart-helper change that wraps the literal in a `with` block). Document the duplicate-key as a known-but-harmless artefact in `gravitee.md` until upstream cooperates.

**Acceptance:** raw-text `curl ... | grep -c '"entrypoint"'` returns `1` (chart fix) **OR** returns `2` with the override being a relative path (Finding 4 path-a as side-effect) **OR** returns `2` with a documented upstream-issue link (file-upstream path).

**Status (2026-05-04, resolved as side effect of OQ5 / Round 6+6.5):** the second branch wins. The chart still emits both `entrypoint` keys (chart helper limitation, no chart-side suppress knob per OQ7), but our override `ui.portal.entrypoint` is now relative `/_portal/` (per Finding 4 / Round 6 Portal consolidation). Browsers and standard JSON parsers last-wins-pick the relative override, which resolves correctly against any hostname Traefik routes. The duplicate-key emission is structurally harmless; no upstream-issue file required, no chart-side fix needed. PLAN-001+ should add a one-line note in `gravitee.md` documenting that the duplicate is expected and benign.

### Finding 2 — `portalEntrypoint` in `graviteedb.environments.settings`

**Symptom:** `curl /management/organizations/DEFAULT/environments/DEFAULT/settings | jq '.portal.entrypoint'` returns `"https://api.company.com"` — a Gravitee placeholder that lands in the DB at first Liquibase migration and never gets touched again.

**Where the value comes from:** Gravitee's Liquibase seed for `environments.settings.portal_entrypoint` (table name approximate; verify by inspecting changelogs in the api pod's WAR or upstream `gravitee-rest-api` repo). It is *not* read from `gravitee.yml` at runtime — the api pod stores the seed once and reads from the DB thereafter.

**Important interaction with Finding 4:** Finding 4's design constraint is "one deploy, any number of hostnames." That rules out any solution to Finding 2 that bakes a single absolute URL into the DB and relies on it — because the right URL depends on which hostname the user accessed. So the *only* acceptable resolutions are ones where the api pod constructs outbound URLs from `X-Forwarded-Host` / `X-Forwarded-Proto` per request, ignoring (or harmlessly fallback-ing to) the DB column. If we can't get the api pod to do that, Finding 2 is unsolvable under Finding 4's constraint and we'd need to relax one.

**Test scope caveat:** the drop-database test's check 2b is a single-endpoint canary — it verifies that `/portal/redirect` honours `X-Forwarded-Host`. Gravitee's api pod renders absolute URLs in three known shapes (redirects, notification emails, webhook payloads), and they may be served by different Spring filter chains. A passing 2b check is *strong evidence* the redirect path is correct but not *proof* that email and webhook paths are. When SMTP eventually lands ([INVESTIGATE-service-email-smtp.md](../backlog/INVESTIGATE-service-email-smtp.md)), the PLAN for that work should add a corresponding email-rendering check (trigger a password-reset, capture the outbound mail in Mailpit, assert the link host echoes the requesting host). Webhooks are out of scope until anyone wires them.

**OQ6 resolved (Round 1, 2026-05-03):** the api pod does **NOT** honour `X-Forwarded-Host` / `X-Forwarded-Proto` for outbound URLs. A probe of `/management/.../portal/redirect` with `Host: gravitee.test.example` + `X-Forwarded-Host: gravitee.test.example` + `X-Forwarded-Proto: https` returned `Location: http://gravitee.localhost/portal/...` — both forwarded headers ignored, host *and* scheme baked in from the chart's `installation.standalone.console.urls[]` value. The same probe with the natural `Host: gravitee.localhost` (OQ9) produced an identically-shaped 307 with absolute Location at the chart-baked URL. **Confirms the api pod constructs outbound URLs from the helm-rendered `gravitee.yml`, not from the request.**

**Bad news for Finding 4's design constraint.** Anywhere the api emits an absolute URL — login redirect (`/portal/redirect`), notification-email links, webhook payloads — it'll always echo `gravitee.localhost`. Relative URLs in `constants.json` (the OQ4 path) can fix the Console SPA's own XHRs against the management API, but cannot fix the api pod's emitted absolute URLs.

**Levers, given OQ6:**
- ~~Spring Boot `server.forward-headers-strategy: framework`~~ — only useful if the api pod *would* read it. OQ6 shows it does not; either the property isn't set in the rendered `gravitee.yml`, or the relevant Vert.x filter chain doesn't honour it. Worth one more probe (read the chart-rendered `gravitee.yml` ConfigMap to confirm whether the property appears at all) but the empirical answer is already "no."
- **`installation.standalone.{console,portal}.urls[]` array form (fallback path)**: enumerate every supported hostname in chart values. Question becomes *whether the api pod picks the right tuple per-request based on `Host:` / `X-Forwarded-Host`*, or whether it just defaults to the first entry. If per-request: this works without a UIS variable, just a longer values list at deploy time. If first-entry-only: the array gives you nothing single-hostname-mode wouldn't.
- **Upstream patch** asking Spring/Vert.x filter chain to honour `X-Forwarded-Host` for absolute URL construction. File an issue against `gravitee-io/gravitee-api-management`. Slow path.
- ~~Custom Liquibase changeset~~ / ~~api re-reads gravitee.yml on start~~ — both bake a single hostname, violate Finding 4's design constraint. Off the table unless Finding 4 is relaxed.
- **Last resort:** post-deploy management-API PUT — explicitly rejected.

**Acceptance:** all three of the following pass in the drop-database test:
- **2a** — environment-level `portalEntrypoint` does not contain the chart placeholder `api.company.com`.
- **2b** — `/portal/redirect` with `X-Forwarded-Host: gravitee.test.example` returns a Location whose host echoes the requesting host (or a relative path — same-origin is also acceptable). A Location pointing at `*.localhost` when the request came in via `*.test.example` means the api pod ignored the forwarded-host header and Finding 2 is unsolved under Finding 4's design constraint.
- **Finding 4 cross-hostname check** — `constants.json` is byte-identical regardless of the hostname used to fetch it.

If 2a passes but 2b fails, Finding 2 is solved single-domain-only and the work hasn't met the Finding 4 design constraint.

### Finding 3 — Organisation name is `Default organization`

**Symptom:** `curl /management/organizations/DEFAULT | jq '.name'` returns `"Default organization"` — chart-default placeholder.

**Where the value comes from:** Liquibase seed inserts the row `(id=DEFAULT, name='Default organization')` on first install.

**Variable layering — use UIS's existing `DEFAULT_*` pattern.** Organisation name is **not Gravitee-specific** — Authentik tenants, Grafana orgs, Backstage `app.title`, OpenMetadata workspaces, and any future identity-aware service in UIS will all want the same label. Adding a Gravitee-only `GRAVITEE_ORG_NAME` would mean a different variable for every service that grows the same need. The right shape matches the existing pattern (`DEFAULT_ADMIN_EMAIL` flows to 8+ per-service vars including `GRAVITEE_ADMIN_EMAIL`):

1. **Add to `provision-host/uis/templates/default-secrets.env`:**
   ```
   DEFAULT_ORGANIZATION_NAME=UIS Local Dev
   ```
2. **Reference in `00-master-secrets.yml.template`** for every namespace that needs an org name. For Gravitee, under `gravitee/urbalurba-secrets`:
   ```yaml
   GRAVITEE_ORG_NAME: "${DEFAULT_ORGANIZATION_NAME}"
   ```
   (Other services that have an analogous knob get their own per-service line in their namespace block — same shape as `GRAVITEE_ADMIN_EMAIL`, `AUTHENTIK_BOOTSTRAP_EMAIL`, `PGADMIN_DEFAULT_EMAIL` deriving from `${DEFAULT_ADMIN_EMAIL}` today.)
3. The Gravitee setup playbook reads `GRAVITEE_ORG_NAME` from the namespace secret and applies it through whichever lever wins below.

**Levers to investigate (for the actual *application* of the value, given it lands in `gravitee/urbalurba-secrets:GRAVITEE_ORG_NAME`):**
- **Chart value:** does the chart expose anything like `installation.organizations[0].name` or `defaultOrganization.name`? Search `values.yaml` for the chart version we pin. (Probably no — Gravitee's per-org name is treated as user data, not infra config.)
- **Helm `--set-string`:** if a chart value exists, set it via the helm CLI in playbook task 24, sourced from the secret.
- **Env var on the api pod:** unlikely (DB-backed), but worth grepping `gravitee.yml` example for any `installation.*.name` knob.
- **Custom Liquibase changeset** that updates `organizations.name` on first start. Cleanest if the chart cooperates with `extraInitContainers` / `api.extraVolumes`.
- **An init container** that runs `psql -c "UPDATE organizations SET name = '$GRAVITEE_ORG_NAME' WHERE id = 'DEFAULT'"` after Liquibase but before the api pod fully starts. Idempotent — safe to run on every deploy, not just the first.
- **Last resort:** post-deploy `PUT /management/organizations/DEFAULT {"name": ...}` — explicitly rejected unless all of the above are ruled out.

**Acceptance:** drop-database test produces `"name"` matching `${DEFAULT_ORGANIZATION_NAME}` (e.g. `"UIS Local Dev"` by default).

**Out of scope for this Gravitee-specific investigation, but worth noting:** once `DEFAULT_ORGANIZATION_NAME` exists, other services that currently hardcode an org/tenant/workspace name should be migrated to source from it too. That migration shouldn't bundle into this Gravitee-specific PLAN — file as a small follow-up "wire DEFAULT_ORGANIZATION_NAME through Authentik/Grafana/Backstage/OpenMetadata" plan when those services next get touched.

### Finding 4 — Domain agility (one deploy, any number of hostnames)

**Symptom:** chart values currently bake `http://gravitee.localhost` into `constants.json` and `gravitee.yml`. Switching to `gravitee.mydomain.com` via cloudflared/tailscale requires editing chart values and redeploying.

**Design constraint (per maintainer):** Gravitee must follow the same domain-handling pattern as every other UIS service. *No variable, no envsubst, no redeploy* should be required when a user adds cloudflared/tailscale and wants to access the cluster via `gravitee.mydomain.com` instead of (or alongside) `gravitee.localhost`. A single deploy must serve any number of hostnames.

**The UIS pattern this targets:**
1. Traefik IngressRoute uses `HostRegexp(\`<service>\..+\`)` so any subdomain that matches the prefix routes to the same pods. *(Solved already — `091-gravitee-ingress.yaml`.)*
2. Apps use **same-origin / relative URLs** in their served-to-browser config so the SPA picks up its hostname from the page URL at fetch time.
3. Apps that emit absolute URLs in API responses honour `X-Forwarded-Host` / `X-Forwarded-Proto` (Traefik sets these on every forwarded request by default).

Items 2 and 3 are what this finding must close, **at deploy time, with no domain-specific UIS variable.**

**Round 1 / 1.5 partial outcomes (2026-05-03):**

- The Console's `constants.json` is currently served byte-identically across hostnames — but that's a property of the ui pod's nginx serving a static ConfigMap, not domain agnosticism. The `baseURL` *value* itself is `http://gravitee.localhost/management` (absolute, domain-baked at chart-render time), so the Console SPA's XHRs always target `gravitee.localhost` regardless of which hostname the page was loaded from.
- The api pod ignores `X-Forwarded-Host` / `X-Forwarded-Proto` for outbound absolute URLs (see Finding 2 / OQ6). Login redirects, email links, etc. always emit the chart-baked URL.
- So Finding 4's design constraint is **partially solvable via relative `baseURL` (OQ4 path) for the Console-SPA-to-management-API path, but unsolvable on the api pod's emitted absolute URLs without an upstream patch or the `urls[]` array fallback.**

**Levers to investigate:**

- **Relative `baseURL`** (preferred for the Console SPA's own XHRs; gated on OQ4): change chart values to
  ```yaml
  ui:
    baseURL: /management
  portal:
    baseURL: /portal
  ```
  The Console SPA fetches `/constants.json`, reads `baseURL`, and uses `fetch('${baseURL}/v2/...', { credentials: 'include' })`. Relative URLs resolve against the current page origin, so a single `constants.json` works on any hostname Traefik routes. **Question:** does the SPA tolerate a relative `baseURL`? Verify by editing the ConfigMap, restarting the ui pod, and watching DevTools. If yes — done, no UIS variable needed.

- **`X-Forwarded-Host` honour for absolute URLs emitted by the api pod** (complementary): for code paths in the api pod that *must* emit an absolute URL (notification email links, redirect headers, webhook payloads), the api must construct it from Traefik-provided headers, not from `installation.api.url`. Check Spring Boot `server.forward-headers-strategy: framework` (or `native` in Spring Boot 3+) is set in the chart-rendered `gravitee.yml`, and that Vert.x respects it.

- **`installation.standalone.{console,portal}.urls[]` array form** (fallback): the chart accepts multiple `(orgId, url)` tuples. Inspect whether the api pod actually picks the right tuple per request based on `X-Forwarded-Host`, or whether it defaults to the first entry. If the former, this is a viable fallback that still requires no UIS variable (just a longer chart-values list enumerating localhost + tailscale + cloudflared hostnames at deploy time).

- **`ui.portal.entrypoint` (the "Open Developer Portal" link in the Console nav):** points at a *different* hostname (`gravitee-portal.<domain>`). A relative URL doesn't help here — the Portal lives on a different origin. Two paths:
  - (a) **Consolidate the Portal under `gravitee.<domain>/_portal/`** so it's same-origin and a relative URL works. This is a **non-trivial architectural change** that touches: `091-gravitee-ingress.yaml` (drop the `gravitee-portal.<domain>` IngressRoute, add path-based routing under `gravitee.<domain>` similar to how `/management/*` already works), `manifests/090-gravitee-config.yaml` (chart values for portal serving sub-path), and `website/docs/services/integration/gravitee.md` (the Architecture section currently documents three user-visible hostnames; this collapses to two — the `gravitee-portal.<domain>` URL pattern disappears). PLAN must coordinate all three. Open question: does the Portal SPA tolerate serving from a sub-path? (See "Open questions" below.)
  - (b) **Keep separate hostnames** and resolve the entrypoint client-side from `window.location.host`. Would require chart-side support (the Console SPA picking up the entrypoint from runtime JS rather than from the static `constants.json`) or a custom Console build — likely not worth it.
  - Path (a) is simpler **if** the Portal SPA tolerates a sub-path; the architectural impact is acceptable because UIS owns the routing layer. Path (b) is essentially a non-starter without upstream cooperation.

**Acceptance criteria for Finding 4:**
- Drop-database test runs once on a vanilla cluster → `gravitee.localhost` works.
- Without any redeploy or config edit to Gravitee, deploy cloudflared with its existing `BASE_DOMAIN_CLOUDFLARE` setting (this is the cloudflared tunnel's *own* domain knob — not a Gravitee variable; it already exists in `00-master-secrets.yml.template`), open `https://gravitee.<that-domain>` → Console renders, login works, all SPA XHRs target the *current* hostname (no `gravitee.localhost` strings in DevTools Network when accessed externally).
- `constants.json` is byte-identical regardless of which hostname is used to fetch it.
- No new `BASE_DOMAIN`-style variable is introduced for Gravitee specifically. (Reusing the existing cloudflared/tailscale tunnel variables is fine and unavoidable — Gravitee just inherits whatever domain Traefik routes.)

### Finding 5 — `503` on `/management/v2/organizations/DEFAULT/ui/customization` (DEMOTED — does not reproduce)

**Audit symptom:** noisy 503 reported by browser tester in DevTools and api-pod logs on every page load. Hypothesised root cause: the api pod's Spring controller for `v2/.../ui/customization` is the EE Cockpit endpoint and the OSS install was assumed to be 503-ing because of a missing `@ConditionalOnProperty` guard.

**Round 1 / 1.5 outcome (2026-05-03, curl basic-auth):** the endpoint returns **`204 No Content`** on both a stale (33h-old) install and a fresh-DB redeploy. The audit's 503 does not reproduce when probed this way.

**Browser-tester observation (Round 3 Section B, 2026-05-04, Chromium with cookie-session auth):** the endpoint returns **`503` on the first cold-start hit, then `204` on an immediate retry**. The SPA continues to render normally — the 503 is transparent to the user and the retry succeeds. So the audit's original 503 was real, but **cold-start-only and self-recovering**, not the persistent error a missing-conditional Spring controller would produce.

**Most likely cause** (still hypothesis, no upstream code-read done): the EE Cockpit controller's lazy-init path returns 503 while the bean is still warming up, then 204 once initialised. Either way, the user-visible behaviour is fine because the SPA's retry handler papers over it.

**This finding stays out of scope.** No upstream issue to file (the cold-start 503 is annoying log noise but not a functional bug — the SPA retry mechanism handles it), no chart change, no playbook change. One-line note in `gravitee.md` covers the diagnostic chain so a future contributor seeing the 503 in DevTools console doesn't dig in fresh.

**Future re-verification.** If the 503 reappears in any future round (browser tester or contributor), capture the request as cookie-session-auth + auth-cookie value + UA string, paste into a fresh INVESTIGATE entry, and re-evaluate. Until then, no action.

**Drop-database test treatment.** The test's Finding 5 step is informational-only — emits `Finding 5: PASS (204)`, `KNOWN (503)`, or `WARN (other)`. None gate the PLAN. The check stays in the script as a regression detector: if the endpoint starts returning a stack-trace 500, that's worth catching.

### Finding 8 — Chart-default HPA on `ui`/`portal` leaks into local-dev installs

**Symptom (from `talk/talk.md:2825-2901`):** a fresh `./uis deploy gravitee` on Rancher Desktop produces **6 pods**, three of which are `gravitee-apim-ui` replicas. They idle at ~145Mi each (~450Mi total for nothing) because the chart's default HorizontalPodAutoscaler targets 80% memory, the per-pod baseline RSS already exceeds the 128Mi request, so the HPA pegs at `max=3` and stays there with zero load.

```
$ kubectl -n gravitee get hpa
NAME                  TARGETS                         MINPODS  MAXPODS  REPLICAS
gravitee-apim-portal  memory: 28%/80%, cpu: 0%/50%    1        3        1
gravitee-apim-ui      memory: 117%/80%, cpu: 0%/50%   1        3        3   ← always at max
```

**Root cause: values-file asymmetry.** `manifests/090-gravitee-config.yaml` explicitly disables autoscaling on `api` and `gateway` but leaves `ui` and `portal` to the chart default (`autoscaling.enabled: true`, min=1, max=3, mem 80%). `replicaCount: 1` is meaningless once an HPA exists — only `autoscaling.enabled: false` actually keeps a Deployment at one pod.

**Maintainer's direction (verbatim from talk.md):** *"we don't need hpa when this is running in development on the local rancher desktop cluster. we should rather have something in the config files that can be switched on to run hpa. for local development we need a functional but minimal install."*

So this isn't just a Gravitee asymmetry fix — it's the first concrete instance of a UIS-wide question: **how do we ship a minimal-but-functional local-dev default while letting prod opt in to HPA, larger requests, and other production-shaped knobs?**

**Levers to investigate (Gravitee-scope, deploy-time):**

- **Symmetry fix only** (smallest possible change): add `autoscaling.enabled: false` blocks to `ui:` and `portal:` in `manifests/090-gravitee-config.yaml` for symmetry with `api`/`gateway`. Two lines of YAML + a comment per block. Drop-database test passes immediately because chart values are read fresh on every deploy. Does *not* answer the "switch on for prod" half.

- **Single values file, documented prod-flip**: same as above, but the comment explicitly tells operators which lines to flip and what other values (memory request, etc.) need raising before HPA makes sense. No new files, no playbook changes. Cheapest "switchable" — switching means editing the file, not toggling a config knob. Closest to the maintainer's quote.

- **Values overlay pattern**: ship `manifests/090-gravitee-config.yaml` (minimal local-dev defaults) plus an opt-in overlay `manifests/090-gravitee-config.prod.yaml` (HPA on, larger requests). Playbook task 24 picks the right `-f` based on a UIS-level variable (e.g. `UIS_PROFILE=dev|prod`, default `dev`). Adds a new abstraction; touches the playbook; introduces a profile concept that isn't in UIS today. Probably the right shape long-term but bigger than just Gravitee.

- **Helm `--set` overrides driven by a UIS-level variable**: `./uis deploy gravitee --enable-hpa` flag → playbook adds `--set ui.autoscaling.enabled=true --set portal.autoscaling.enabled=true` (and probably memory-request overrides). Per-deploy, no overlay file. Less reusable across services.

**Recommendation for this investigation:** scope only the **symmetry fix + documented prod-flip** here. The maintainer's broader concern — a UIS-wide profile/overlay pattern for "functional but minimal local dev" vs "production-shaped" — is bigger than Gravitee and deserves its own investigation (see "Out of scope" below). Tackling Gravitee's HPA asymmetry first proves the baseline before generalising.

**Acceptance:**
- Drop-database test ends with **4 pods** (one each of `api`, `gateway`, `ui`, `portal`), no HPA objects in the namespace, no HPA-driven scaling regardless of memory pressure.
- The values file's HPA blocks are commented in a way that makes "how do I turn this on for prod?" obvious to a future contributor.

**Status (2026-05-04): resolved via PLAN-gravitee-disable-hpa-dev** (now in `completed/`). Approach: system-wide `DEFAULT_AUTOSCALING=false` in `default-secrets.env`, propagated through every setup playbook by the wrapper, mapped per-service via `_gravitee_autoscaling` in `090-setup-gravitee.yml`, applied via four helm `--set` lines on install. Single-knob, future-services-can-adopt design.

**Corollary surfaced by Round 5 override probe (worth recording for the prod-flip path):** the chart has HPA templates for **all four components** (api, gateway, ui, portal), not just ui+portal as initially assumed. With `_gravitee_autoscaling=true`, all four HPAs are created. Empirically, both `ui` (~115%/80%) **and `gateway`** (~131%/80%) exceed the chart's default 80% memory target with idle RSS — meaning a naive prod flip enables four HPAs but two of them (ui, gateway) immediately peg at max=3, producing 10 pods (3 api + 3 gateway + 1 portal + 3 ui). Anyone enabling autoscaling for prod-shape needs to raise `gateway.resources.requests.memory` and `ui.resources.requests.memory` above their actual idle RSS first. Not actionable in the local-dev fix; documented here so the prod-flip docs reckon with it.

---

## Non-actionable findings (preserved for diagnosis trail)

> Finding 5 was originally in this section's scope but has been documented in-place above (DEMOTED — does not reproduce). Findings 6 and 7 keep their original numbers (matching audit ordering) but are grouped here, separate from the actionable set.

### Finding 6 — SMTP placeholder

Tracked separately: see [INVESTIGATE-service-email-smtp.md](../backlog/INVESTIGATE-service-email-smtp.md). Once UIS has a shared SMTP layer, Gravitee picks up `SMTP_HOST/PORT/USER/PASSWORD/FROM_ADDRESS` like every other service. Until then, Gravitee email flows silently fail. **Out of scope** for this investigation; not part of the drop-database test.

### Finding 7 — Admin email mismatch

Audit reported `admin@example.com` instead of an expected user email. Root cause: the user's `.uis.secrets/.../00-common-values.env` has `DEFAULT_ADMIN_EMAIL=admin@example.com`. Deployment reflects user config correctly — **no action needed**, line is preserved for the diagnosis chain so this doesn't get re-raised as a bug. Not part of the drop-database test.

> Findings 6 and 7 keep their original numbers (matching the audit ordering) but are grouped here, separate from the actionable findings (1–5, 8), so the in-scope work flows without interruption. Cross-references in the doc continue to use "Finding 6" and "Finding 7".

---

## Variables proposed by this investigation

Two-layer pattern, matching the existing `DEFAULT_*` flow (`DEFAULT_ADMIN_EMAIL` → `GRAVITEE_ADMIN_EMAIL`, etc.). "Layer" refers to *where the variable is defined*, not work priority.

**Layer 1 — central UIS default in `provision-host/uis/templates/default-secrets.env`:**

| Variable | Default | Used by |
|---|---|---|
| `DEFAULT_ORGANIZATION_NAME` | `"UIS Local Dev"` | Single source of truth for the organisation/tenant label across UIS. Other services that currently hardcode an org name (Authentik, Grafana, Backstage, OpenMetadata, …) should migrate to source from this in their own future plans — not bundled here. |

**Layer 2 — per-service derivative in `00-master-secrets.yml.template`:**

| Variable (in `gravitee/urbalurba-secrets`) | Value | Resolves which finding |
|---|---|---|
| `GRAVITEE_ORG_NAME` | `"${DEFAULT_ORGANIZATION_NAME}"` | Finding 3 — applied via whichever lever wins during PLAN. |

**Domain agility (Finding 4):** zero new variables — relative `ui.baseURL`/`portal.baseURL` (gated on OQ4) + chart's `urls[]` array as fallback for absolute URLs from the api pod (gated on whether the api picks per-request — separate sub-question, see Finding 4). `X-Forwarded-Host` honour by api pod is **ruled out** by OQ6 — not a viable lever without an upstream patch.

**SMTP (Finding 6):** out of scope — see [INVESTIGATE-service-email-smtp.md](../backlog/INVESTIGATE-service-email-smtp.md). When that lands, the same `default-secrets.env` → per-namespace pattern applies to `DEFAULT_SMTP_HOST` → `GRAVITEE_SMTP_HOST` etc.

### Plumbing chain verification (2026-05-03)

The Layer 1 → Layer 2 → Layer 3 chain was verified by maintainer-side reads of `provision-host/uis/lib/first-run.sh:304-354` (`generate_kubernetes_secrets()`), `first-run.sh:244-298` (`copy_secrets_templates()`), `provision-host/uis/templates/default-secrets.env`, `00-common-values.env.template`, and `00-master-secrets.yml.template`. The flow:

1. `default-secrets.env` defines `DEFAULT_*` keys (image-shipped, single source of truth).
2. On first init, `copy_secrets_templates()` copies `00-common-values.env.template` to `.uis.secrets/secrets-config/`, then runs `sed` rules at `first-run.sh:282-291` to overwrite each `DEFAULT_*=...` line in the user's copy with values from `default-secrets.env`. **`00-common-values.env.template` is *not* re-synced after first init** — only `00-master-secrets.yml.template` is auto-synced when image versions change (`first-run.sh:250-258`).
3. `generate_kubernetes_secrets()` does `set -a; source 00-common-values.env.template; set +a` then `envsubst < 00-master-secrets.yml.template > kubernetes-secrets.yml`. Only common-values is sourced — `default-secrets.env` is *not*.
4. `./uis secrets apply` applies the generated YAML.

The existing gravitee block at `00-master-secrets.yml.template:500-533` already wires up `${DEFAULT_ADMIN_EMAIL}` / `${DEFAULT_ADMIN_PASSWORD}` (lines 528-529). Adding `GRAVITEE_ORG_NAME: "${DEFAULT_ORGANIZATION_NAME}"` follows the same pattern and works automatically *for fresh installs*.

**Existing-install gap (must be addressed in the PLAN-001 that wires `DEFAULT_ORGANIZATION_NAME`):** because `00-common-values.env.template` is only copied once on first init, an existing user install has no `DEFAULT_ORGANIZATION_NAME=...` line in their copy. Sourcing produces an unset variable; envsubst expands `${DEFAULT_ORGANIZATION_NAME}` to the empty string; `GRAVITEE_ORG_NAME: ""` lands in the generated YAML; the drop-database test's empty-string guard fires SETUP FAIL.

**Fix (recommended for PLAN-001):** modify `generate_kubernetes_secrets()` so it sources `default-secrets.env` *first*, then `00-common-values.env.template` (which overrides). New `DEFAULT_*` keys ship with the image and "just work" for existing installs without a manual migration. Two-line patch in `first-run.sh:328-335`. Cleaner than (a) adding a one-shot common-values sync step or (b) requiring users to manually edit their common-values file.

---

## Open questions

### Resolved during Phase 0

Run by tester via `talk.md`; outcomes folded into the relevant Findings above.

- **OQ3 (Round 1, 2026-05-03) — chart `extra*` capability.** The chart exposes only `extraVolumes` and `extraVolumeMounts` (commented examples in `api`, `gateway`, `ui`, `portal` blocks). **No `extraInitContainers`, no `extraContainers`, no `extraEnvs`** keys present in upstream values for chart 4.11.3. Custom Liquibase changeset via `extraVolumes`-mounted changelog is feasible (api pod can mount a config-map of additional changesets). A psql-update-as-init-container would have to come from a separate kustomize-style Deployment patch, not chart values.
- **OQ4 (Round 3 + browser test, 2026-05-04) — Console SPA tolerates relative `ui.baseURL`: yes.** Chart `ui.baseURL` flipped from `http://gravitee.localhost/management` to `/management`. UIS tester confirmed CLI-side: `constants.json` reflects the relative value, Console HTML returns 200, management API responds 200 at the relative path. Browser tester then drove DevTools verification on Chromium: 58 XHRs on full reload, **zero** pointing to a wrong host or to `apim.example.com`, zero CORS errors, navigation works, refresh-while-logged-in works. The B6 multi-domain probe (manual hosts-file edit + load via synthetic hostname) was skipped because the automation environment can't edit `/etc/hosts`; B3's exhaustive 58-request check provides strong indirect evidence the SPA correctly resolves the relative URL against the page origin. **Finding 4's Console-SPA half is solved by this one-line chart change.** B6 left as an optional manual confirmation by the maintainer if belt-and-suspenders is desired; not blocking.
- **OQ6 (Round 1, 2026-05-03) — api pod X-Forwarded-Host honour.** Probe of `/portal/redirect` with `Host: gravitee.test.example` + `X-Forwarded-Host: gravitee.test.example` + `X-Forwarded-Proto: https` returned `Location: http://gravitee.localhost/...`. Both forwarded headers ignored, host *and* scheme baked in. **The api pod constructs outbound absolute URLs from the chart-rendered `gravitee.yml`, not from the request.** Material constraint on Finding 4.
- **OQ7 (Round 1, 2026-05-03) — chart helper-template duplicate-key origin.** `helm template` against `090-gravitee-config.yaml` shows the chart helper emits `entrypoint: "https://apim.example.com/"` as a hardcoded literal *before* iterating user-supplied `ui.portal` keys. Both literals end up in the same rendered `portal:` JSON block. **No chart conditional or value path suppresses the hardcoded default.** Finding 1's chart-side fix is ruled out — only paths are upstream patch, accept-with-doc, or relative-override-via-Path-(a).
- **OQ8 (Round 5, 2026-05-04) — raising ui memory request to 256Mi keeps HPA at min=1 idle.** Question became moot: maintainer chose Path B (system-wide `DEFAULT_AUTOSCALING=false` toggle, see `PLAN-gravitee-disable-hpa-dev` in `completed/`) over Path A (raise memory). Path B ships, Path A's experiment skipped. Corollary observation: chart provisions HPA templates for **all four** components (api, gateway, ui, portal), and `gateway` has the same memory-headroom problem as `ui` — relevant when prod-shape clusters flip `DEFAULT_AUTOSCALING=true`. Already noted in Finding 8.
- **OQ5 (Round 6 + 6.5 + browser test, 2026-05-04) — Portal SPA tolerates serving from `gravitee.<domain>/_portal/`: yes.** Two-piece fix shipped: chart `portal.baseURL: /portal`, `PORTAL_BASE_HREF: /_portal/`, `ui.portal.entrypoint: /_portal/`; ingress consolidated (separate `gravitee-portal.<domain>` IngressRoute removed) with new path-based route `HostRegexp(\`gravitee\..+\`) && PathPrefix(\`/_portal\`)` referencing a `Middleware/gravitee-portal-strip` resource (`stripPrefix: { prefixes: [/_portal] }`). Round 6 initial attempt missed the StripPrefix middleware and saw a SPA-fallback masking 404s on every asset request — Round 6.5 added the middleware after `uis-user1`'s clean three-probe diagnostic (identical 6592-byte responses for `/`, `/assets/config.json`, `/config.json` proved the masked failure). Browser tester confirmed P2-P6 PASS: Portal renders, all 27 assets load with `/_portal/` prefix, all API XHRs target `gravitee.localhost/portal/...`, navigation maintains the prefix, Console → Portal link works **and same-origin cookie sharing carries the Console-authenticated session into the Portal automatically** (the actual prize from consolidation). Hostname table collapsed from 3 user-visible hostnames to 2. **Finding 1 also resolved as a side effect**: `ui.portal.entrypoint` is now relative `/_portal/`, so the chart's hardcoded duplicate `entrypoint: "https://apim.example.com/"` in `constants.json` is structurally harmless (last-wins to the relative path).
- **OQ9 (Round 1, 2026-05-03) — `/portal/redirect` Location shape.** Returns 307 with **absolute** Location header. Combined with OQ6, the absolute URL is constructed from chart-baked sources, not the request.

### Demoted to fallback (not run)

OQ1 and OQ2 only matter as fallbacks if Finding 4's design constraint were relaxed — given Findings 4-Console (OQ4) and 4-Portal (OQ5) are both resolved without single-hostname trade-offs, neither needs to be run.

- **OQ1 — does the api pod re-read `gravitee.yml` on each start?** Demoted: only relevant if a single-hostname mode were accepted. Not running.
- **OQ2 — Spring `GRAVITEE_<KEY>` env override for DB-backed settings?** Demoted: only relevant as a Finding 3 fallback if other levers fail. Possibly revisited during PLAN-001-gravitee-org-name if the lever choice surfaces a need.

**All actionable open questions resolved.** PLAN-001+ files (org name, DB-baked URLs) become writeable with deterministic tasks. See *Scope* and *Variables proposed* for what each PLAN should ship.

---

## Scope

- **In scope:** Findings 1, 2, 3, 4, 8 — each with a deploy-time-correct mechanism. The drop-database test is the gate. (Finding 5 was originally in-scope but Round 1.5 confirmed the audit's 503 does not reproduce — see Finding 5 for the demotion rationale.)
- **Status (2026-05-04):** Findings 1 + 4-Console + 4-Portal + 8 shipped. Findings 2 + 3 + 4-api-side remain — all to be implemented via PLAN-001+ (org name first, DB-baked URLs second).
- **Out of scope:**
  - SMTP (Finding 6) — separate [INVESTIGATE-service-email-smtp.md](../backlog/INVESTIGATE-service-email-smtp.md).
  - Admin email mismatch (Finding 7) — non-actionable, user config reflects intent.
  - Authentik OIDC integration (separate plan when prioritised).
  - License / EE feature unlock.
  - Multi-environment per org (`DEFAULT/DEV/STAGING/PROD`).
  - API governance defaults (categories, tags, quality rules — wait until someone asks).
  - `installation.standalone.console.urls[]` multi-tuple unless Finding 4's fallback path is triggered.
  - **The broader UIS-wide "minimal-dev vs prod-overlay" question** raised by Finding 8. Gravitee-scope symmetry fix lands here; the larger pattern (per-service profile / overlay / `UIS_PROFILE` variable / Helm-flag toggle) deserves its own investigation. A separate file `INVESTIGATE-uis-dev-vs-prod-profiles.md` would be the right home — *not yet created* (no stub on disk); to be opened when this concern is escalated to a real plan. That investigation should look at every service whose chart defaults assume production sizing and lay out a single coherent toggle pattern UIS can adopt across services rather than each service inventing its own.
- **Explicitly rejected as the lead approach:** post-deploy management-API PUT/POST/PATCH calls. Only acceptable as a documented last resort for any specific finding where every chart-value, helm-flag, env-var, init-container, and Liquibase-changeset lever has been investigated and ruled out.
