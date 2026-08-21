# Analysis: NAIS and UIS — what transfers, what doesn't, and what UIS already does better

**Status: Analysis, 2026-08-15**

A capability-by-capability comparison of [NAIS](https://nais.io/) — Nav's
application platform for the Norwegian public sector — with UIS. NAIS claims are
cited to `doc.nais.io`; UIS claims are cited to files in this repository, read on
2026-08-15 at `0769b9c`.

This is an analysis, not a plan. Nothing here is approved work. Where a
recommendation would become real work, section 4 says which existing
investigation it belongs to.

---

## Executive summary

- **The comparison is lopsided in an instructive way.** NAIS's centre of gravity
  is the *application* contract — one YAML file, `nais.yaml`, from which an
  operator generates ~20 Kubernetes objects. UIS's centre of gravity is the
  *platform service* contract — `service-<id>.sh` plus an Ansible playbook. UIS
  is strong exactly where NAIS is thin (packaging infrastructure) and absent
  exactly where NAIS is strongest (packaging an application).
- **UIS has no workload abstraction at all.** A user application registered via
  `./uis argocd register` ships a raw `manifests/deployment.yaml`
  ([dev-templates.md](../../../developing/dev-templates.md)). Every app author
  writes Kubernetes by hand — which sits awkwardly against the platform's own
  stated promise of "a platform you use *without* knowing Kubernetes"
  ([INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md) Part 2).
- **The single highest-leverage idea to steal is `envFrom: [secret: <name>]`** —
  NAIS's user-defined-secret mechanism. It is one line of YAML, needs no platform
  code beyond what Kubernetes already does, and it directly answers SEC-F5 in
  [INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md)
  (adding one secret currently means editing three shared files totalling 1073 lines).
- **UIS's `configure` verb is the right shape but half-built.** Eight services
  declare `SCRIPT_CONFIGURABLE="true"`; only two have handlers. The other six
  fail with "Handler not yet implemented" (see 2.2).
- **Zero-trust networking is a genuine, cheap, currently-zero capability.**
  `grep -r NetworkPolicy` across `manifests/`, `ansible/playbooks/` and
  `provision-host/uis/` returns nothing. NAIS's default-deny plus `accessPolicy`
  is the one security idea that transfers to a laptop essentially unchanged.
- **Auto-instrumentation is the observability idea worth copying**, not more
  dashboards. NAIS injects OpenTelemetry agents from three lines of YAML with no
  code change; UIS has Tempo running and receiving nothing (OBS-F3).
- **Most of NAIS does not transfer.** Teams-as-GCP-projects, Aiven-backed Kafka,
  four Norwegian national identity providers, per-team cost attribution and a
  dedicated platform team are all properties of a funded multi-tenant cloud
  platform. UIS is single-tenant, laptop-first and self-hosted.
- **Three UIS ideas have no NAIS equivalent and are better for its context:**
  Principle 0 (everything runs on a laptop), the external-service proxy
  convention (`PGHOST` resolves identically in both topologies), and the required
  `why:` field on external dependencies.

---

## 1. What the two platforms actually are

Before comparing capabilities, the asymmetry needs stating, because half the
"gaps" below are consequences of it rather than defects.

| | NAIS | UIS |
|---|---|---|
| Substrate | GKE, one cluster per environment ([under-the-hood](https://doc.nais.io/explanations/under-the-hood/)) | Rancher Desktop / k3s dev, k3s on Proxmox prod ([production/index.md](../../../production/index.md)) |
| Primary unit | An **application** (`kind: Application`) | A **platform service** (`service-<id>.sh`) |
| Tenancy | Multi-tenant: teams, namespaces, GCP projects | Single-tenant; most services land in `default` |
| Who operates it | A dedicated platform team at Nav | The installation's owner, part-time |
| Backing services | Managed cloud (Cloud SQL, Aiven, GCS, BigQuery) ([persistence](https://doc.nais.io/persistence/)) | Helm charts, or an external host behind a proxy |
| Licence / portability | Components MIT (e.g. [naiserator](https://github.com/nais/naiserator)); the platform is not turnkey-installable | Whole stack installs from one script |
| Stated philosophy | "functionality that just works™"; "building blocks… you select the ones that fit" ([explanations/nais](https://doc.nais.io/explanations/nais/)) | "a complete datacenter on a laptop" |

NAIS's own framing is worth quoting because it is close to UIS's:

> It's built around the idea that **an unobstructed team of people, able and
> willing to take responsibility for the things they make, perform better than
> any alternative**.
> — [doc.nais.io/explanations/nais](https://doc.nais.io/explanations/nais/)

For accuracy: **NAIS does not use the phrase "golden path"** anywhere this
research could find. The equivalent phrasing is "functionality that just works™"
and "det skal være lett å gjøre rett" (it should be easy to do right,
[nais.io](https://nais.io/)). Do not attribute "golden path" to them.

---

## 2. Capability by capability

### 2.1 The workload contract

**NAIS.** One file, `.nais/app.yaml`, `apiVersion: nais.io/v1alpha1`,
`kind: Application`. The
[application spec](https://doc.nais.io/workloads/application/reference/application-spec/)
carries `image`, `port`, `replicas`, `resources`, `liveness`/`readiness`/`startup`,
`ingresses`, `env`, `envFrom`, `filesFrom`, `accessPolicy`, `gcp`, `kafka`,
`valkey`, `openSearch`, `azure`, `idporten`, `tokenx`, `maskinporten`, `login`,
`observability`, `prometheus`, `strategy`, `preStopHook`,
`terminationGracePeriodSeconds`, `leaderElection`, and `vault` (on-prem only).
A second kind, `Naisjob`, covers cron and one-shot work.

[Naiserator](https://github.com/nais/naiserator) (MIT) is the operator that turns
that one object into the rest. Its README lists what it generates: Deployment /
Job / CronJob, HorizontalPodAutoscaler, Ingress, **NetworkPolicy**,
PodDisruptionBudget, PodMonitor, Role/RoleBinding, Secret, ServiceAccount and
Service — plus NAIS-specific CRs (AivenApplication, AzureAdApplication,
IDPortenClient, MaskinportenClient, Jwker, Stream) and Google CNRM resources
(SQLInstance / SQLUser / SqlDatabase, StorageBucket, BigQueryDataset,
IAMServiceAccount, IAMPolicy, PubSubSubscription).

Every workload also gets default env vars without asking: `NAIS_CLUSTER_NAME`,
`NAIS_NAMESPACE`, `NAIS_APP_NAME`, `NAIS_CLIENT_ID` (`<cluster>:<namespace>:<app>`),
`NAIS_POD_NAME`, `PORT`, `BIND_ADDRESS`, `NAIS_APP_IMAGE`
([default-variables](https://doc.nais.io/workloads/reference/default-variables/)).

**UIS today.** Two unrelated deployment paths, and the split is documented in
[adding-a-service.md](../../../contributors/guides/adding-a-service.md)
("Two deployment paths"):

1. **Platform services** — `./uis deploy <id>`. Metadata in
   `provision-host/uis/services/<category>/service-<id>.sh` (shell `KEY="value"`
   lines, parsed line-by-line without sourcing, by
   `provision-host/uis/lib/service-scanner.sh`), deployment by an Ansible
   playbook in `ansible/playbooks/`. Around 30 services across 10 categories.
2. **User applications** — `./uis argocd register <name> <repo-url>`. The repo
   ships `manifests/deployment.yaml` and `manifests/kustomization.yaml`; ArgoCD
   syncs them; UIS creates the namespace and an IngressRoute
   ([argocd-commands.md](../../../developing/argocd-commands.md),
   [argocd-pipeline.md](../../../developing/argocd-pipeline.md)).

**Gap.** For path 2 there is *no abstraction whatsoever*. The dev templates hand
the developer a raw Deployment plus Service
([template-catalog.md](../../../developing/template-catalog.md)) and the platform
adds routing. There is no place to declare "I need a database", "I need auth",
"scrape my metrics", "who may call me" — the six or seven things NAIS makes
one-liners. Everything a UIS app needs beyond a container and a URL is
out-of-band.

For path 1 the metadata file is genuinely good, but it is *platform-operator*
metadata (which playbook, which check command, which category), not *workload*
metadata (what this thing needs in order to run).

**Honest caveat:** an `Application` CRD plus operator is a large build. Section 4
proposes a much smaller first step and explicitly ranks the CRD last.

### 2.2 Declaring infrastructure dependencies

**NAIS.** The developer writes the dependency into the same manifest and the
platform provisions it and injects the credentials. Postgres, verbatim from
[persistence/cloudsql](https://doc.nais.io/persistence/cloudsql/):

```yaml
gcp:
  sqlInstances:
    - type: POSTGRES_17
      tier: db-f1-micro
      databases:
        - name: mydb
```

The pod then receives `NAIS_DATABASE_<APP>_<DB>_{HOST,PORT,DATABASE,USERNAME,
PASSWORD,URL,JDBC_URL,SSLROOTCERT,SSLCERT,SSLKEY,SSLMODE}`, with the prefix
overridable via `envVarPrefix`
([cloudsql reference](https://doc.nais.io/persistence/cloudsql/reference/)).
Kafka works the same way — `AivenApplication` → Aivenator → a secret →
`KAFKA_BROKERS`, `KAFKA_CERTIFICATE`, `KAFKA_KEYSTORE_PATH`, and so on
([persistence/kafka](https://doc.nais.io/persistence/kafka/),
[kafka env vars](https://doc.nais.io/persistence/kafka/reference/environment-variables/)).
Buckets, BigQuery, OpenSearch and Valkey follow the same declare-and-receive
shape ([persistence](https://doc.nais.io/persistence/)).

Two properties matter beyond the mechanism: credentials are **rotated** (Kafka on
each deploy; OpenSearch and Valkey "on a regular basis"), and provisioning is
**eventually consistent** — the docs warn that a first Cloud SQL deploy "takes…
as much as 8-10 minutes, and the first deploy will usually time out and be marked
as failed"
([troubleshooting](https://doc.nais.io/workloads/how-to/troubleshooting/)).

**UIS today.** Two half-mechanisms, neither reaching the application.

- `SCRIPT_REQUIRES` declares *service-to-service* ordering, and the deploy path
  verifies it (`provision-host/uis/lib/service-deployment.sh`). Fifteen services
  use it, e.g. `service-openmetadata.sh` declares `"postgresql elasticsearch"`.
  This is real and it works — but it is about *which platform services must
  exist*, not about giving an application a database of its own.
- `./uis configure <service> --app <name>` is the closest analogue to
  `gcp.sqlInstances`, and its shape is right.
  `provision-host/uis/lib/configure-postgresql.sh` creates a per-app database and
  role, writes a Kubernetes Secret containing a `DATABASE_URL` key
  (`_pg_create_secret`), auto-exposes a host port, and returns connection details
  as JSON.

**Gap, measured.** `SCRIPT_CONFIGURABLE="true"` is set on **eight** services —
postgresql, mysql, mongodb, redis, elasticsearch, qdrant, authentik — plus
postgrest. Only **two** handlers exist in `provision-host/uis/lib/`:
`configure-postgresql.sh` and `configure-postgrest.sh`. `configure.sh` line 231
resolves `configure-<id>.sh` and, when absent, fails with:

```
No configure handler for '<id>'. Handler not yet implemented.
```

So `./uis configure redis --app atlas` advertises itself through `services.json`
and then fails. This is the same defect shape already catalogued twice in this
backlog — metadata claiming a capability that a second, unrelated registration
point does not provide (compare `VERIFY_SERVICES` in
[PLAN-cli-verify-registration-fix](./PLAN-cli-verify-registration-fix.md)).

Second gap: `configure` is **imperative and out-of-band**. NAIS's developer
records the dependency in a file that lives with the app, is reviewed, and is
replayed on every deploy. UIS's developer runs a command once; nothing in the
app's repository records that the database exists, and nothing re-creates it on a
rebuild.

Third gap: **no rotation**. `configure-postgresql.sh` generates a fresh password
on re-configure, but nothing schedules that, and the value lands in a static
Secret.

### 2.3 Secrets

**NAIS.** Two clean categories
([services/secrets](https://doc.nais.io/services/secrets/)):

- *Platform-provided* — minted by operators for databases, Kafka and auth
  providers. Named by prefix (`google-sql-…`, `aiven-…`, `azure-…`, `tokenx-…`,
  `idporten-…`), owned by the CR that created them, never touched by the
  developer.
- *User-defined* — created by the team in Console (or `kubectl`), stored as
  ordinary `Opaque` Kubernetes Secrets in the team's namespace.

Consumption is one line
([secrets reference](https://doc.nais.io/services/secrets/reference/)):

```yaml
spec:
  envFrom:
    - secret: <secret-name>
```

or as files:

```yaml
spec:
  filesFrom:
    - secret: <secret-name>
      mountPath: /var/run/secrets/<secret-name>
```

Editing a secret in Console restarts the consuming workloads automatically
([console how-to](https://doc.nais.io/services/secrets/how-to/console/)). There
is no external vault in the runtime path; HashiCorp Vault survives only as
`spec.vault` on the legacy on-prem environments, and the GCP migration page
states the replacement plainly: *"Secrets: are now stored as native secrets in
the cluster, rather than externally in Vault"*
([migrating-to-gcp](https://doc.nais.io/workloads/explanations/migrating-to-gcp/)).

**UIS today.** One Secret shape for everything, distributed to every namespace.
`provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
(729 lines) defines **15 Secret documents across 13 namespaces**, all named
`urbalurba-secrets`, rendered by `envsubst` from `00-common-values.env.template`
(274 lines) with fallbacks in `default-secrets.env` (70 lines) — the pipeline is
documented in
[contributors/architecture/secrets.md](../../../contributors/architecture/secrets.md).
The production picture is stated bluntly in
[production/secrets.md](../../../production/secrets.md): *"one Secret containing
54 keys, base64 only, replicated into 13 namespaces — so read access in any
namespace yields every credential."*

`validate_secrets` in `provision-host/uis/lib/secrets-management.sh` checks seven
hardcoded variable names and warns on six more; it is **not** called from
`provision-host/uis/lib/service-deployment.sh`, so it never runs on
`./uis deploy`. All of this is already measured as SEC-F1 through SEC-F6 in
[INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md).

**Gap — the most valuable one in this document.** NAIS's two categories map
cleanly onto UIS's actual situation, and the *consumption* side is free:
`envFrom: [secret: <name>]` is plain Kubernetes, not a NAIS invention. What NAIS
adds is only the discipline.

| | NAIS | UIS today |
|---|---|---|
| Unit of secret | one named Secret per purpose | one `urbalurba-secrets` per namespace, 54 keys |
| Blast radius | the app that names it | every workload in 13 namespaces |
| Where declared | in the app's own manifest | in three shared files, 1073 lines (SEC-F5) |
| Who may edit | the owning team, in Console | whoever holds the install |
| On change | consumers auto-restart | nothing |

That table is the argument for the per-service `secrets/<id>.yaml` proposal
already drafted in
[INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md)
Part 2b. NAIS is independent evidence that the shape is right, and it goes one
step further than that proposal: NAIS *also* splits the Secret object itself, not
just the declaration.

One nuance UIS should copy: NAIS's platform-provisioned secrets are
distinguishable from user-defined ones by `ownerReferences`, which is what stops
Console editing them. UIS has no equivalent marker separating "the platform
minted this" from "the operator supplied this".

**Note on OpenBao.** NAIS's trajectory is *away* from a vault in the runtime
path, toward native Kubernetes Secrets plus operators. That is not an argument
against [INVESTIGATE-service-openbao](./INVESTIGATE-service-openbao.md) — UIS's
vault is justified by bootstrap and multi-cluster reasons NAIS solves with GCP
IAM — but it does support that investigation's Option C conclusion: the interface
the developer touches should be an ordinary Kubernetes Secret, with the store as
topology.

### 2.4 Identity and authentication

**NAIS.** Four providers, chosen by audience ([auth](https://doc.nais.io/auth/)):
Entra ID (employees, internal services), ID-porten (citizens), TokenX
(on-behalf-of citizens between internal apps), Maskinporten (cross-organisation
machine-to-machine).

The developer writes a boolean:

```yaml
spec:
  tokenx:
    enabled: true
```

and the platform provisions a client, mints a secret, and injects env vars. The
modern model is **Texas** — *Token Exchange as a Service* — a sidecar exposing
three HTTP endpoints so the application never handles OAuth itself
([auth/explanations](https://doc.nais.io/auth/explanations/#texas)):

> Texas runs as a sidecar together with your application and offers HTTP
> endpoints for: getting machine tokens; exchanging user tokens into
> on-behalf-of tokens; token validation with introspection.

Reduced to three env vars: `NAIS_TOKEN_ENDPOINT`, `NAIS_TOKEN_EXCHANGE_ENDPOINT`,
`NAIS_TOKEN_INTROSPECTION_ENDPOINT`
([auth reference](https://doc.nais.io/auth/reference/#texas)).

For browser login there is the **login proxy (Wonderwall)** — an opt-in sidecar
that intercepts requests, runs the OIDC flow, keeps the session server-side, and
attaches `Authorization: Bearer <JWT>` before proxying to the app. It exposes
`/oauth2/login`, `/oauth2/logout`, `/oauth2/session` and
`/oauth2/session/refresh`, and it explicitly **does not validate tokens** — that
stays the app's job
([auth reference](https://doc.nais.io/auth/reference/#endpoints)).

**UIS today.** Authentik plus a Traefik forward-auth middleware. A protected
IngressRoute references `authentik-forward-auth`, and the service receives
`X-Forwarded-User`, `-Email`, `-Groups`, `-Name`, `-Preferred-Username` and
`-User-Id` headers
([contributors/rules/ingress-traefik.md](../../../contributors/rules/ingress-traefik.md)).
Protected services are listed in `AUTH10_PROTECTED_SERVICES` inside
`00-master-secrets.yml.template`, and OAuth app blueprints live in `manifests/`
— which
[INVESTIGATE-service-authentik-user-config](./INVESTIGATE-service-authentik-user-config.md)
already flags as the wrong home for user data.

**Gap.** UIS covers exactly one of NAIS's cases — *browser login in front of a
web UI* — and it covers it well and cheaply. What it has nothing for is
**service-to-service identity**: no per-workload identity, no token issuance, no
token exchange, no introspection endpoint. Any UIS app calling another app today
uses a shared static credential out of `urbalurba-secrets`.

There is also a known hole: forward-auth **does not apply to Tailscale Funnel**,
because the operator's per-service proxy bypasses Traefik
([networking/index.md](../../../networking/index.md)). A service exposed that way
must enforce auth itself.

**Realism.** Texas is elegant and largely does not transfer: it exists to paper
over four national identity providers UIS has no relationship with. The
transferable fragment is much smaller — see 3a.

### 2.5 Ingress and exposure

**NAIS.** A list of URLs, and the platform does the rest:

```yaml
spec:
  ingresses:
    - https://myapplication.nav.no
```

Domains are fixed per environment and encode audience: `nav.no` (internet),
`intern.nav.no` (internal networks including naisdevice), `ansatt.nav.no`
(authenticated humans on compliant devices)
([environments](https://doc.nais.io/workloads/reference/environments/)).
Internet-facing domains **block `/metrics`, `/actuator` and `/internal`** at the
edge. The generic cross-tenant pattern is
`external.<env>.<tenant>.cloud.nais.io` for public and
`<env>.<tenant>.cloud.nais.io` for internal. Naiserator emits one Kubernetes
Ingress per class (`external-haproxy` / `internal-haproxy`)
([ingress reference](https://doc.nais.io/workloads/application/reference/ingress/)).
Only one subdomain level is allowed, and paths are passed through unstripped
([how-to/expose](https://doc.nais.io/workloads/application/how-to/expose/)).

NAIS pushes *away* from ingress for internal traffic:

> **Service discovery is the recommended way to communicate between applications
> running in the same environment.** … **Access policies do not restrict inbound
> traffic through ingresses.**
> — [explanations/expose](https://doc.nais.io/workloads/application/explanations/expose/)

**UIS today.** Traefik `IngressRoute` CRDs, `traefik.io/v1alpha1`, with
`HostRegexp` as the house pattern so one route serves `.localhost`, `.ts.net` and
a Cloudflare domain simultaneously
([ingress-traefik.md](../../../contributors/rules/ingress-traefik.md)). CoreDNS
rewrites map `*.localhost` to in-cluster FQDNs so the same hostname resolves from
both a browser and a pod — which is what makes local OIDC flows work. TLS is
terminated at the Cloudflare or Tailscale edge; there is no cert-manager in the
repo (verified: no match for `cert-manager` or `letsencrypt` under `manifests/`
or `ansible/playbooks/`).

**Gap.** Small, and mostly the other way round. Two ideas are worth taking:

- **Audience is not expressible.** NAIS's three domains make "who can reach this"
  a property of the URL you chose. In UIS every service is reachable by anything
  that can reach Traefik; public-versus-internal is a per-service decision
  encoded by hand in whether you added forward-auth or a Funnel.
- **Blocking `/metrics`, `/actuator` and `/internal` at the edge** is a one-line
  Traefik middleware and closes a real exposure class for any UIS install with a
  Cloudflare tunnel.

UIS's `HostRegexp` multi-domain trick has no NAIS equivalent and is better suited
to a platform whose domain differs per install.

### 2.6 Zero-trust networking

**NAIS.** Default deny, in every environment:

> Every workload is isolated from _all_ other workloads with Kubernetes network
> policies. Access is denied by default, unless explicitly allowed.
> — [under-the-hood](https://doc.nais.io/explanations/under-the-hood/)

Opening a path is declarative and symmetric — the caller declares outbound, the
callee declares inbound:

```yaml
spec:
  accessPolicy:
    inbound:
      rules:
        - application: app-a                  # same namespace and cluster
        - application: app-b
          namespace: other-namespace
        - application: app-c
          namespace: other-namespace
          cluster: other-cluster
```

The same block doubles as the *authorisation* model for Entra ID
machine-to-machine: a consumer listed there receives the `access_as_application`
role, and `permissions.roles` / `permissions.scopes` allow finer grants
([entra-id reference](https://doc.nais.io/auth/entra-id/reference/)). One
declaration, two enforcement points — network and token.

**UIS today.** Nothing. Verified:

```
grep -rn "NetworkPolicy" manifests/ ansible/playbooks/ provision-host/uis/   # no matches
```

Every pod can reach every other pod and every Service. Combined with 2.3's single
54-key Secret in 13 namespaces, a compromised workload has both the network reach
and the credentials to use it.

**Gap — the cleanest transfer in this document.** NetworkPolicy is plain
Kubernetes, needs no operator, and k3s / Rancher Desktop enforce it. UIS already
knows the graph: `SCRIPT_REQUIRES` records which service talks to which (15
services declare it), and `SCRIPT_PROVIDES_APIS` / `SCRIPT_CONSUMES_APIS` exist
in the metadata for Backstage. A generator could emit a default-deny policy per
namespace plus allow-rules derived from `SCRIPT_REQUIRES` without any new
declaration from service authors.

**Honest cost.** Default-deny breaks things loudly and is a poor first experience
on a laptop if it lands enabled. It needs a phased rollout (audit mode, then
opt-in, then default) and it will expose undeclared dependencies — which is the
point, but it is a week of chasing them, not an afternoon.

### 2.7 Observability

**NAIS.** Three lines of YAML, no code change
([auto-instrumentation](https://doc.nais.io/observability/how-to/auto-instrumentation/)):

```yaml
spec:
  observability:
    autoInstrumentation:
      enabled: true
      runtime: java   # nodejs | python | dotnet | sdk
```

The platform injects an OpenTelemetry agent and sets `OTEL_SERVICE_NAME`,
`OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.nais-system:4317`,
`OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_PROPAGATORS` and `OTEL_RESOURCE_ATTRIBUTES`
([auto-config reference](https://doc.nais.io/observability/reference/auto-config/)).
HTTP servers and clients, JDBC, Kafka, gRPC and Redis are instrumented out of the
box. For a public-sector platform, note the collector **redacts Norwegian
personal identity numbers** from `url.path`, `db.statement`,
`messaging.kafka.message.key` and others.

Logs go to Loki by default, selectable per workload
([logging](https://doc.nais.io/observability/logging/)):

```yaml
spec:
  observability:
    logging:
      destinations:
        - id: loki        # or team_logs for private/sensitive logs
```

Metrics are scraped by Grafana Alloy into Mimir from `spec.prometheus.enabled`.
Alerts are **plain `monitoring.coreos.com/v1` PrometheusRule** objects deployed
alongside the app, with required `severity` and `namespace` labels and
`runbook_url` / `dashboard_url` annotations that become links in the Slack
notification
([prometheusrule reference](https://doc.nais.io/observability/alerting/reference/prometheusrule/)).
The alerting section itself is SRE philosophy — SLIs as ratios, SLOs, precision
and recall ([alerting](https://doc.nais.io/observability/alerting/)).

**UIS today.** The stack exists and is empty. From
[INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md),
measured on the production k3s cluster: zero alert rules loaded (OBS-F1); Loki
containing only its own test data because nothing shipped logs (OBS-F2, now being
closed by Alloy in `service-alloy.sh` and PLAN-001); Tempo receiving only the E2E
validation trace, with an application team shipping to Grafana Cloud because no
local path was documented (OBS-F3); only in-cluster targets scraped (OBS-F4).

UIS *has* started the right convention: probes and dashboards ship beside the
service — `provision-host/uis/services/observability/probes/grafana.yaml`,
`provision-host/uis/services/databases/dashboards/postgresql.json`.

**Gap.** Two, of very different sizes.

- **Auto-instrumentation is the missing piece, not more dashboards.** OBS-F3's
  root cause is that "how does my app emit a trace" is undocumented and unwired.
  NAIS's answer — the platform sets the OTEL env vars, the app changes nothing —
  is directly reusable and is precisely what PLAN-005 (app telemetry) gestured at.
- **Alerts as an artifact shipping with the workload.** NAIS's use of the stock
  `PrometheusRule` CRD, with a *required* `runbook_url`, is the same
  "ship the shape with the thing" convention UIS already uses for probes and
  dashboards, and the required-annotation discipline mirrors UIS's own required
  `why:`.

### 2.8 Teams, namespaces, tenancy

**NAIS.** A team is the organising unit for everything
([explanations/team](https://doc.nais.io/explanations/team/)). Creating one in
Console gives you a namespace in every environment, a matching GitHub team with
synchronised membership, roles and permissions, and a dedicated GCP project per
environment. Owners manage members; access to a namespace is exactly team
membership; `kubectl` in prod is read/write only in your own namespace.

**UIS today.** No tenancy model. `PROJECT_NAME` in
`provision-host/uis/templates/uis.extend/cluster-config.sh.default` is used for
labels; namespaces are per-*service*, not per-team, and most workloads land in
`default`. RBAC objects exist only for three specific components
(`manifests/652-backstage-rbac.yaml`,
`manifests/230-uptime-kuma-discovery-rbac.yaml`, and Unity Catalog).
ArgoCD-registered apps do get their own namespace, but with no ownership or
access semantics attached.

**Gap — and mostly a non-gap.** UIS is single-tenant by design and by audience.
The one idea that survives shrinking is **namespace-as-boundary**: today it is a
packaging accident (13 namespaces, each holding a full copy of every credential),
whereas in NAIS it is a security boundary. Making the namespace mean something is
a precondition for 2.3 and 2.6 to be worth much.

### 2.9 Environments and dev/prod parity

**NAIS.** Environment equals cluster. `dev-gcp` and `prod-gcp` are separate GKE
clusters with separate GCP projects; `dev-fss` / `prod-fss` are the legacy on-prem
pair and are marked *"not recommended for new workloads"*
([environments](https://doc.nais.io/workloads/reference/environments/)). The same
manifest is parameterised with **Handlebars 3.0** templating in the deploy action
([templating](https://doc.nais.io/build/how-to/templating/)):

```yaml
metadata:
  name: {{app}}
  namespace: {{team}}
spec:
  ingresses:
  {{#each ingresses as |url|}}
    - {{url}}
  {{/each}}
```

with variables supplied via `VARS`/`VAR` and previewable by
`nais validate --verbose --vars vars.yaml nais.yaml`.

**UIS today.** One cluster per installation. `cluster-config.sh` holds a single
`CLUSTER_TYPE`, `BASE_DOMAIN` and `TARGET_HOST`; `./uis platform use` switches
the active platform (`platforms/azure-aks`, `platforms/rancher-desktop`).
Dev/prod difference is expressed as *topology* — the external-service proxy
convention in `provision-host/uis/lib/external-services.sh` and
`.uis.extend/external-services.yaml`, shipped in
[PLAN-system-external-services-001](../completed/PLAN-system-external-services-001-proxy-convention.md).

**Gap, in both directions.** NAIS has no laptop story at all; UIS's parity model
is stronger *conceptually* — "interface identical, topology may differ" is a
sharper rule than "here are two clusters, template your YAML". But UIS has no
equivalent of `VARS`: an installation cannot parameterise anything per
environment except through `.uis.extend/` files written by hand, and there is
nothing like `nais validate` to preview what will be applied.

The concrete thing missing is a **dry-run**. `nais validate` renders and checks
before anything touches a cluster; `./uis deploy` has no `--dry-run`. (Compare
`DRY_RUN` and `PRINT_PAYLOAD` on the deploy action.) `./uis test-all --dry-run`
exists but only prints a test plan.

### 2.10 CLI, Console, developer portal

**NAIS.** The `nais` CLI ([cli.nais.io](https://cli.nais.io)) is broad and
noun-first: `nais app` (list / log / status / restart / env / set / delete),
`nais job`, `nais postgres` (psql / proxy / prepare / grant / migrate /
password rotate), `nais kafka`, `nais opensearch`, `nais valkey`, `nais secret`
(create / get / list / set / unset / delete), `nais members`, `nais device`,
`nais validate`, `nais kubeconfig`, `nais vulnerability`, `nais api`, plus an
experimental MCP server (`nais alpha mcp serve`).

[Nais Console](https://doc.nais.io/operate/console/) is the web surface:

> The Console is designed to be self-service, meaning that you can manage your
> workloads and services without needing to involve the Nais team.

It creates teams, authorises GitHub repositories for deployment, manages secrets
and config, provisions OpenSearch and Valkey, and shows Cost and Utilization.
Behind it is a GraphQL API at `console.nav.cloud.nais.io/graphql` (beta).

**UIS today.** `./uis` is comparably broad — `deploy`, `undeploy`, `configure`,
`expose`, `connect`, `verify`, `secrets`, `stack`, `template`, `platform`,
`network`, `host`, `argocd`, `test-all`, `docs`
(`provision-host/uis/manage/uis-cli.sh`). Its grammar is inconsistent, which is
the subject of
[INVESTIGATE-cli-grammar-harmonization](./INVESTIGATE-cli-grammar-harmonization.md)
— `platform` and `network` are noun-first, around 12 legacy verbs are not. NAIS
is a useful external data point for that investigation: its CLI is almost
entirely `nais <noun> <verb>`, which is the direction UIS is already heading.

The Console analogue is **Backstage** (`service-backstage.sh`, Red Hat Developer
Hub), which today provides a software catalog and Kubernetes visibility generated
from `SCRIPT_*` metadata, with guest access
([backstage.md](../../../services/management/backstage.md),
[INVESTIGATE-service-backstage-auth](./INVESTIGATE-service-backstage-auth.md)).

**Gap.** Backstage *reads*; Console *writes*. Everything self-service in NAIS —
create a team, add a secret, authorise a repo, provision a cache — is a write
operation from a browser. UIS has no write surface outside the CLI, and the CLI
runs inside a container the developer must have running. Whether UIS wants one is
a genuine product question, not an obvious gap: a single-tenant platform operated
by its owner has much less need for self-service than a platform with dozens of
teams.

The narrower, clearly-good ideas are `nais validate` (see 2.9) and
`nais app status` / `nais log` — per-workload introspection that UIS partly has
via `./uis status` and `./uis verify` but not for ArgoCD-registered applications.

### 2.11 Deploy pipeline

**NAIS.** Composable GitHub Actions, not a monolith
([build](https://doc.nais.io/build/)): `nais/docker-build-push` then
`nais/deploy/actions/deploy@v2`, with `CLUSTER`, `RESOURCE`, `WORKLOAD_IMAGE`,
`VARS`, `WAIT`, `TIMEOUT`, `DRY_RUN` and `PRINT_PAYLOAD`
([nais-deploy reference](https://doc.nais.io/build/reference/nais-deploy/)).
Authorisation is per-repository, granted once in Console's Repositories tab, with
`permissions: id-token: write` in the workflow.

Server side is `hookd` then gRPC then `deployd`
([nais/deploy](https://github.com/nais/deploy)): deployd assumes the team's
identity, applies the resources, **waits for rollout**, and reports success /
failure / error back as GitHub Deployment statuses. `nais/what-changed` skips the
image rebuild when only the manifest changed.

**UIS today.** GitHub Actions builds and pushes to GHCR with a unique
`{sha}-{timestamp}` tag, then **commits the new tag back into
`manifests/deployment.yaml`**, and ArgoCD notices and syncs
([argocd-pipeline.md](../../../developing/argocd-pipeline.md)). Loops are avoided
with a path filter and an author check.

**Gap.** Two real differences:

- **Rollout status does not return to the developer.** NAIS blocks and reports;
  UIS's workflow finishes when the commit lands, and whether the pod actually
  came up is discovered in ArgoCD's UI. A failed rollout looks like a green build.
- **The write-back-to-git step is a design smell NAIS avoids** by passing
  `WORKLOAD_IMAGE` at deploy time. UIS's approach is a legitimate GitOps pattern
  and has the advantage that the repo always states what is deployed — but it
  costs a bot commit per deploy and needs `contents: write` on every app repo.

UIS's approach is also *pull*-based, which is genuinely better for a self-hosted
cluster with no public ingress: ArgoCD reaches out, so CI never needs cluster
credentials. NAIS's `hookd` only works because Nav operates a public deploy
endpoint. **This one should not be "fixed" toward NAIS.**

### 2.12 Cost and utilisation feedback

**NAIS.** A per-team **Cost** tab (daily, broken down by GCP service) and a
**Utilization** tab (requested versus actually used CPU and memory per workload)
in Console, with explicit guidance — do not set CPU limits, recommended requests
of 20-30m for typical services, default 2-4 replicas, `min: 1` in dev
([cost-optimization](https://doc.nais.io/workloads/how-to/cost-optimization/)).

> The Utilization page shows how much you request and how much you use. The gap
> between these numbers is what you're overpaying for.

**UIS today.** `./uis platform status <provider>` shows a cost estimate for cloud
platforms. Nothing shows utilisation-versus-request. Sizing knowledge exists only
as prose in investigations (for example the observability stack measured at ~4 GB
RAM and ~40 GB storage).

**Gap.** Cost attribution does not transfer — there is no bill to attribute on a
laptop or an owned Proxmox host. **Utilisation does**, and it matters *more* on a
fixed-size box than in a cloud: the binding constraint on a 16 GB laptop is RAM,
and "this service requests 2 GB and uses 300 MB" is directly actionable. This is
a Grafana dashboard against metrics UIS already collects, once
[PLAN-system-observability-003](./PLAN-system-observability-003-service-dashboards.md)
lands.

---

## 3. The three-way split

### 3a. Ideas UIS should adopt

1. **Split `urbalurba-secrets` and let a workload name the secret it needs**
   (`envFrom: [secret: <name>]`). Pure Kubernetes; the win is blast radius and
   the death of the 1073-line three-file edit. Belongs to
   [INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md).
2. **Default-deny NetworkPolicy with declared exceptions.** UIS already has the
   dependency graph in `SCRIPT_REQUIRES`. Needs a new investigation.
3. **Auto-instrumentation: the platform sets the OTEL env vars.** Closes OBS-F3's
   root cause. Belongs to
   [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
   PLAN-005.
4. **Alerts as an artifact shipping with the service**, using the stock
   `PrometheusRule` CRD and a *required* `runbook_url` — matching the existing
   probes and dashboards convention and UIS's own required-`why:` discipline.
5. **Finish `uis configure`.** Six services advertise a capability that fails.
   Either write the handlers or stop claiming it in metadata.
6. **`./uis deploy --dry-run`**, modelled on `nais validate` and the deploy
   action's `DRY_RUN` / `PRINT_PAYLOAD`.
7. **Block `/metrics`, `/actuator` and `/internal` on externally-exposed routes.**
   One Traefik middleware; matters the moment a Cloudflare tunnel exists.
8. **Rollout status returned to the developer** after `argocd register`-driven
   deploys, instead of "the commit landed".
9. **Utilisation-versus-request visibility.** Cheap once service dashboards land,
   and more valuable on fixed hardware than in a cloud.
10. **Noun-first CLI grammar** — NAIS is external corroboration for
    [INVESTIGATE-cli-grammar-harmonization](./INVESTIGATE-cli-grammar-harmonization.md).

### 3b. Ideas that do not transfer

- **Teams as the organising unit, with GCP projects and GitHub-team sync.** UIS
  is single-tenant and operated by its owner. Building tenancy would add a
  concept with no second tenant to justify it.
- **Managed backing services** (Cloud SQL, Aiven Kafka / OpenSearch / Valkey,
  BigQuery, GCS). These are purchased capabilities. UIS's equivalent is "run the
  Helm chart, or point at the host beside the cluster" — a different trade, not a
  worse one. Note NAIS itself concedes an 8-10 minute first provision that times
  out the first deploy; UIS's `helm install` is faster and more predictable.
- **Texas and the four national identity providers.** ID-porten, Maskinporten and
  TokenX are Norwegian public-sector integrations requiring formal relationships.
  UIS cannot and should not reproduce them.
- **The `hookd` / `deployd` push pipeline.** It requires an internet-reachable
  deploy endpoint per installation. UIS's ArgoCD pull model is strictly better
  for self-hosted clusters (2.11).
- **Per-team cost attribution.** No bill to attribute.
- **naisdevice plus Kolide device compliance plus JITA.** A corporate
  fleet-management posture. UIS's Tailscale-based access is the proportionate
  equivalent.
- **A dedicated platform team, a Console with a GraphQL API, an APM product.**
  These are the outputs of sustained funded engineering. Listing them as "gaps"
  would be dishonest.

### 3c. Things UIS does that are better, or better-suited

- **Principle 0 — every service runs on a developer's laptop**
  ([kubernetes-deployment.md](../../../contributors/rules/kubernetes-deployment.md)).
  NAIS has no laptop story at all; local development against NAIS means mocks
  (`mock-oauth2-server`, `fakedings`). UIS's rule is stronger and is the whole
  product.
- **The external-service proxy convention.** A Service and labels identical to
  the real thing, so `PGHOST=postgresql.default` resolves in both topologies and
  *no consumer changes*
  ([PLAN-system-external-services-001](../completed/PLAN-system-external-services-001-proxy-convention.md)).
  NAIS solves the same problem by having only cloud, everywhere.
- **The required `why:` field** on `.uis.extend/external-services.yaml`, enforced
  in `provision-host/uis/lib/external-services.sh` — the deploy *fails* without
  it. NAIS has nothing comparable; its closest equivalent is the optional
  `runbook_url` annotation. Requiring a justification for an external dependency
  is a genuinely good idea that a bigger platform would struggle to enforce.
- **`HostRegexp` multi-domain routing.** One IngressRoute serving `.localhost`,
  `.ts.net` and a custom domain. NAIS's fixed per-environment domain list is
  simpler but only works when the platform owns the DNS.
- **Pull-based delivery.** See 2.11.
- **The investigation and plan workflow itself.** The `INVESTIGATE-*` →
  `PLAN-*` → `completed/` discipline in [ai-developer](../../README.md), with
  measured findings and explicit corrections of earlier claims, has no visible
  NAIS counterpart in public docs.
- **Being installable at all.** NAIS's components are open source, but the
  platform is not something a third party installs; it is offered to other
  Norwegian public agencies as a hosted arrangement in Nav-managed Google
  organisations. UIS's entire distribution model is one script.

---

## 4. Ranked adoptable ideas

Highest leverage first. Effort is engineering effort on the UIS codebase:
**S** is a day or two, **M** is about a week, **L** is multiple weeks.

| # | Idea | Why it ranks here | Effort | Where the work belongs |
|:--:|---|---|:--:|---|
| 1 | Per-workload named secrets (`envFrom: secret:`), splitting `urbalurba-secrets` | Cuts blast radius from 13 namespaces x 54 keys to one app's own keys, and kills the three-file edit (SEC-F5) in the same change | M | [INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md) — extends Part 2b |
| 2 | Secrets validation derived from the declaration, run on `uis deploy` | Already-diagnosed defect (SEC-F1/F2/F4); NAIS is corroboration, not the source | S | Same investigation, plan 1 |
| 3 | Default-deny NetworkPolicy generated from `SCRIPT_REQUIRES` | The only capability here that is currently *zero*, and it is plain Kubernetes; the dependency graph already exists | M | **New investigation** — no existing home |
| 4 | Finish or retract `SCRIPT_CONFIGURABLE` | Six services advertise a handler that does not exist; either resolution is fine, the mismatch is not | S | **New plan**, sibling of [PLAN-cli-verify-registration-fix](./PLAN-cli-verify-registration-fix.md) |
| 5 | Auto-instrumentation: platform sets `OTEL_*` for workloads | Fixes OBS-F3's cause rather than its symptom; an app team already fled to Grafana Cloud over this | M | [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md) PLAN-005 |
| 6 | `./uis deploy --dry-run` / render-and-print | Makes every other change here safer to land, and is the cheapest confidence win in the list | S | [INVESTIGATE-cli-deploy-no-playbook-semantics](./INVESTIGATE-cli-deploy-no-playbook-semantics.md) |
| 7 | Ship alert rules with the service, `runbook_url` required | Completes the probes/dashboards convention with the third artifact; stock CRD, no new machinery | S-M | [PLAN-system-observability-002](./PLAN-system-observability-002-alert-baseline.md) and [PLAN-system-observability-003](./PLAN-system-observability-003-service-dashboards.md) |
| 8 | Block `/metrics`, `/actuator`, `/internal` on externally-exposed routes | One middleware; real exposure the moment a tunnel exists | S | **New plan**, small; ingress rules |
| 9 | Return rollout status to the developer after an app deploy | Today a failed rollout looks like a green build | M | [INVESTIGATE-service-argocd-dct-deploy](./INVESTIGATE-service-argocd-dct-deploy.md) |
| 10 | Utilisation-versus-request dashboard | Matters more on fixed hardware than in cloud; nearly free once service dashboards exist | S | [PLAN-system-observability-003](./PLAN-system-observability-003-service-dashboards.md) |
| 11 | Distinguish platform-minted from operator-supplied secrets | Prerequisite for safe self-service editing later; NAIS uses `ownerReferences` | S | [INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md) |
| 12 | Per-environment variable substitution for `.uis.extend/` | UIS's parity model is good but has no `VARS` equivalent | M | [INVESTIGATE-system-external-or-in-cluster-services](./INVESTIGATE-system-external-or-in-cluster-services.md) |
| 13 | A workload manifest for user applications (a UIS `Application`) | Highest ceiling, highest cost; do not start it before 1, 3 and 5 have landed, because they define what it would need to express | L | **New investigation** — and it should be explicitly *deferred* |

Two deliberate notes on the ordering. **Item 13 is ranked last on purpose.** It
is the most NAIS-like idea and the most seductive, and it is also the one most
likely to produce a half-built abstraction. The right sequence is to make the
individual capabilities exist first (secrets, network policy, telemetry) and only
then ask whether they deserve a single declaration. NAIS built `nais.yaml` on top
of capabilities it already ran; UIS would be building the declaration first.

And **item 10 in 3a (CLI grammar) is not in this table** — it is already owned by
an existing investigation and needs no argument from this analysis beyond "NAIS
agrees".

---

## 5. What I could not verify

Stated explicitly rather than smoothed over.

**On the NAIS side:**

- **Ingress TLS certificate management is entirely undocumented.** No page
  describes issuance, renewal, or custom certificates. The strong implication
  (all ingresses must be `https://`, no `tls:` block in the generated Ingress
  example, developers never supply a cert) is platform-managed wildcard certs
  terminated at HAProxy — but that is inference, not a cited claim.
- **Rotation intervals for platform-provisioned credentials are never published.**
  The docs say "regularly", "relatively regularly", "on a regular basis". Kafka
  is the only concrete one: rotated on deploy.
- **The GitHub Actions to `hookd` OIDC exchange is not documented.** Current docs
  show `permissions: id-token: write` plus Console repo authorisation; the
  `nais/deploy` README still documents an older HMAC / API-key scheme. The two
  are not reconciled anywhere found.
- **`observability.tracing`** appears in the application spec's own top-level
  example but has no reference sub-section. Probably legacy; auto-instrumentation
  is the documented path.
- **Google Workspace / Entra group creation on team creation** is inferred from
  reconciler names in `nais/api-reconcilers`, not documented. Only the GitHub
  team is documented.
- **How an invalid ingress domain fails** (deploy rejection versus
  silently-broken ingress) is not stated, nor where the authoritative allow-list
  lives.
- **Non-GitHub-Actions CI** has no documented support path. A `deploy` CLI binary
  and a raw HTTP API exist as escape hatches. "Unconfirmed", not "unsupported".
- **`spec.gcp.buckets` authentication** — the how-to page does not say what is
  injected into the pod. Naiserator generates `IAMServiceAccount` / `IAMPolicy`,
  so Workload Identity is the near-certain mechanism, but no page stating it was
  found.
- The **`spec.gcp.sqlInstances` full field set** (`envVarPrefix`,
  `diskAutoresize`, `cascadingDelete`, `highAvailability`) is referenced by the
  persistence pages but was read here only via the minimal example plus the
  cost-optimization page's discussion of tiers and `diskAutoresizeLimit`. Treat
  the field list in 2.2 as partial.
- NAIS docs are **Jinja-templated per tenant**; the public rendering is the `nav`
  tenant. Anything under `auth/` other than the generic login proxy exists only
  for NAV. Claims here about auth are NAV-tenant claims.
- **The nais.yaml top-level field list in 2.1 is best-effort.** The full spec page
  is very long and was read in summary form; individual field semantics beyond
  those quoted should be re-checked against the page before being relied on.

**On the UIS side:**

- Everything asserted about UIS was read from the repository at `0769b9c` on a
  clean tree. **Nothing was executed against a cluster.** Specifically, the claim
  that `./uis configure redis --app X` fails is derived from reading
  `provision-host/uis/lib/configure.sh` (line 231) together with the absence of
  `configure-redis.sh` — it was not run.
- The `grep` results for `NetworkPolicy`, `cert-manager` and `letsencrypt` cover
  `manifests/`, `ansible/playbooks/` and `provision-host/uis/`. A policy created
  at runtime by a Helm chart's own templates would not appear in that search.
- Service counts (around 30 services, 15 declaring `SCRIPT_REQUIRES`, 7 declaring
  `SCRIPT_CONFIGURABLE`) are from `provision-host/uis/services/*/service-*.sh`
  and will drift.

---

## Related

- [INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md) — the home for items 1, 2 and 11
- [INVESTIGATE-service-openbao](./INVESTIGATE-service-openbao.md) — 2.3's note on NAIS moving away from a runtime vault
- [INVESTIGATE-system-external-or-in-cluster-services](./INVESTIGATE-system-external-or-in-cluster-services.md) — 2.9 and item 12
- [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md) — 2.7 and items 5, 7, 10
- [INVESTIGATE-cli-grammar-harmonization](./INVESTIGATE-cli-grammar-harmonization.md) — 2.10
- [Principle 0](../../../contributors/rules/kubernetes-deployment.md) — the rule NAIS has no equivalent of
