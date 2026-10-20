# Plan: Epinio install (no identity, no custom storage/registry wiring)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed — verified live by imac on a real Rancher Desktop cluster, 2026-10-20

**Goal**: `uis deploy epinio` installs Epinio against this platform's existing Traefik,
with Epinio's own bundled defaults for everything this PLAN deliberately does not touch.
First of three ordered PLANs splitting
[INVESTIGATE-service-epinio-deploy-path](../backlog/INVESTIGATE-service-epinio-deploy-path.md) —
see that doc for the full decision record (`urb-agents#1909/#1910/#1915/#1917`).

**Prerequisites**: [PLAN-system-cert-manager-001-install](./PLAN-system-cert-manager-001-install.md)
must ship first — Epinio's chart requires cert-manager's CRDs before its own install pass.

**Last Updated**: 2026-10-20

---

## Scope — deliberately narrow

This PLAN proves one thing: **Epinio installs and comes up healthy.** It does NOT:

- Wire Epinio's bundled Dex to this platform's identity providers (GitHub/Authentik/Okta)
  — that's `PLAN-service-epinio-003-identity`, and needs the gate-17/18 findings
  (`urb-agents#1917`) plus Terje's reuse-vs-fresh decision (`urb-agents#1919`) to not go
  stale before it's written.
- Wire Epinio's object storage to this platform's Garage, or its registry to Forgejo —
  Epinio uses its own bundled SeaweedFS + bundled registry here, exactly as the lab PoC's
  own gate-1 install did (deliberately, per the PoC's own `epinio-poc-values.yaml` header:
  prove the install first, without pre-deciding later gates' open questions).
- Add the `uis epinio push/list/logs/namespace` CLI surface —
  `PLAN-service-epinio-002-namespace-and-push`.

## What this PLAN ships

- `provision-host/uis/services/management/service-epinio.sh` — `uis deploy epinio` /
  `uis undeploy epinio`, `SCRIPT_REQUIRES="cert-manager"`.
- `ansible/playbooks/625-setup-epinio.yml` — refuses up front if `cert-manager`'s `uis-ca`
  ClusterIssuer isn't found (not just relying on `SCRIPT_REQUIRES`'s own check — a second,
  more specific refusal naming the actual missing thing), then installs the
  `epinio/epinio` Helm chart with `certManager.install: false` / `enabled: true` and
  `ingressClassName: traefik` on both `server` and `ingress`.
- `ansible/playbooks/625-remove-epinio.yml`.
- `DEFAULT_EPINIO_DOMAIN=apps.localhost` added to
  `provision-host/uis/templates/secrets-templates/00-common-values.env.template` —
  deliberately NOT bare `localhost`, since every other UIS service already claims
  `<service>.localhost` directly and a developer-chosen Epinio app name could collide with
  an existing service name in that same namespace.

## Grounded in the proven PoC reference (2026-10-20 correction)

`urb-agents#1917`'s handoff named `terchris/home`'s `service-epinio-poc.yml` directly —
this repo's chart version (first written as a guess, `1.12.0`) is now `1.14.3`, the exact
value that playbook's own comment records as "verified live 2026-10-19 (helm search repo
epinio -l)" for gate 1. The health-check path is now the root `/`, not `/ready` — the PoC's
own gate-1 acceptance check is exactly that request.

## Two real bugs found live, both fixed (`urb-agents#1921`)

1. **`uis deploy epinio` could never pass its own `urbalurba-secrets` existence check on
   a fresh cluster.** `00-master-secrets.yml.template` had no `epinio` namespace/Secret
   block, so the generic secrets pipeline never created one, and the namespace didn't
   exist yet at that point in the deploy either. Confirmed nothing reads a *value* from
   it — a pure existence gate nothing satisfied. Fixed by adding the block (reserved for
   `PLAN-service-epinio-003-identity`'s Dex/OAuth secrets), same pipeline every other UIS
   service goes through.
2. **`epinio_chart_version: "1.12.0"` bundled MinIO, not SeaweedFS** — those pinned MinIO
   images are no longer pullable anonymously from `quay.io` (`401 Unauthorized`), so the
   Helm release's own post-install hook timed out waiting on them. Already corrected to
   `1.14.3` for an unrelated reason (grounding values in the PoC's proven install) before
   this was found; imac's independent check of the live Helm index confirms `1.14.3` is
   the right fix (drops `minio:` entirely, ships `seaweedfs.enabled: true`).

## ✅ Verified live, imac, 2026-10-20 (re-test with both fixes on `main`)

`uis deploy epinio`: **SUCCESS.** All 9 pods (dex, epinio-server, epinio-ui, reflector,
registry, seaweedfs-filer/master/s3/volume) came up Ready. `https://epinio.apps.localhost/`
→ HTTP 200. `uis undeploy epinio`: **SUCCESS**, removed cleanly (the empty namespace itself
is left behind, same as every other UIS undeploy on this cluster — not a defect).

**The default-credential secret name/label in the playbook's final output message is
still an unconfirmed guess** — not blocking, but worth fixing the message text once
someone actually checks it against a real install.

## Acceptance Criteria

- [x] `uis deploy cert-manager && uis deploy epinio` succeeds on a fresh Rancher Desktop
      cluster
- [x] `kubectl get pods -n epinio` shows the server pod Running and Ready
- [x] `https://epinio.apps.localhost/` responds (corrected from `/ready` — see above)
- [x] `uis undeploy epinio` removes it cleanly
- [x] Docs page (`website/docs/services/management/epinio.md`, auto-generated) renders
      correctly

## Next steps

- [x] imac ran this against a real cluster, found and both bugs above are fixed
- [ ] `PLAN-service-epinio-002-namespace-and-push` — not started
- [ ] `PLAN-service-epinio-003-identity` waits on the secrets ops is delivering per
      `urb-agents#1919` (destination given, not yet confirmed received)
