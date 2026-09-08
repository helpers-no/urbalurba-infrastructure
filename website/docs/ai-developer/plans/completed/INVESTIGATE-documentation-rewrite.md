# INVESTIGATE: Documentation Rewrite — Prototype for Auto-Generation

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-02-27
**Status:** Completed
**Related**: [INVESTIGATE-documentation-generation](INVESTIGATE-documentation-generation.md) — the future auto-generation system this prototypes for

## Problem Statement

The documentation was written before the UIS CLI existed and is inconsistent — some service pages are 600+ lines with architecture diagrams, others are 100 lines. Some reference old `./scripts/packages/` paths, others use `./uis` correctly. There's no standard template, no dependency information, and no UIS CLI reference.

**The approach**: Don't just fix broken references. Design a documentation structure that works well for users, then manually write it. This becomes the prototype and specification for auto-generated docs later. We learn what good docs look like by writing them first.

---

## Terminology

### Definitions

| Concept | What it is | Examples |
|---------|-----------|----------|
| **UIS** | Urbalurba Infrastructure Stack — the whole system | — |
| **Package** | Integrated set of services that work together as a unit | Observability, AI, Analytics, Identity |
| **Category** | Every service belongs to a category. Groups services that serve a similar purpose. | Databases, Management, Networking, Observability, AI |
| **Service** | Individual deployable unit | postgresql, grafana, redis, openwebui |
| **Solution** | End-user software running on UIS services (future) | Nextcloud, OpenMetadata |
| **Dependency** | A service that must be deployed before another service can work | authentik depends on postgresql and redis |

### Package vs Category

A **package** is an integrated set of services — deploy them together, they depend on each other, they provide a combined capability. For example, the observability package combines prometheus, loki, tempo, otel-collector, and grafana into a working monitoring system.

A **category** groups independent services that serve a similar purpose but are not related to each other. For example, the databases category contains postgresql, mysql, mongodb, qdrant, and redis — you pick the ones your application needs. The networking category contains tailscale-tunnel and cloudflare-tunnel — different ways to expose services externally.

Every service belongs to a category. When all the services in a category are designed to work together as a unit, that category also forms a **package**. For example, the observability category contains prometheus, loki, tempo, otel-collector, and grafana — you deploy all of them together to get a working monitoring system, so observability is also a package.

In the databases category, postgresql, mysql, and mongodb are independent choices — you don't deploy all of them, you pick what you need. There's no "databases package" because the services don't form an integrated unit.

| Category | Has a package? | Services |
|----------|:-:|----------|
| Observability | **Yes** — the observability package | prometheus, loki, tempo, otel-collector, grafana |
| AI | **Yes** — the AI package | openwebui, litellm, tika |
| Analytics | **Yes** — the analytics package | jupyterhub, spark, unity-catalog |
| Identity | **Yes** — the identity package | authentik |
| Databases | No — independent services | postgresql, mysql, mongodb, qdrant, redis, elasticsearch |
| Management | No — independent services | argocd, pgadmin, redisinsight, nginx, whoami |
| Networking | No — independent services | traefik, tailscale-tunnel, cloudflare-tunnel |
| Storage | No — platform infrastructure | storage-class-alias, hostpath-storage |
| Integration | No — independent services | rabbitmq, gravitee |

This distinction matters for documentation:
- **Package categories** need deployment sequence docs, architecture diagrams, and "deploy the full package" guides
- **Non-package categories** need selection guidance ("postgresql vs mysql — when to use which") and independent service pages

### The Hierarchy

```
UIS (the stack)
├── Packages (integrated service sets)
│   ├── Observability: prometheus + loki + tempo + otel-collector + grafana
│   ├── AI: openwebui + litellm + tika
│   ├── Analytics: jupyterhub + spark + unity-catalog
│   └── Identity: authentik
├── Categories (independent service groups)
│   ├── Databases: postgresql, mysql, mongodb, qdrant, redis, elasticsearch
│   ├── Management: argocd, pgadmin, redisinsight, nginx, whoami
│   ├── Networking: traefik, tailscale-tunnel, cloudflare-tunnel
│   ├── Storage: storage-class-alias, hostpath-storage
│   └── Integration: rabbitmq, gravitee
└── Solutions (future)
    ├── Nextcloud
    └── OpenMetadata
```

### Alignment with Cloud Provider Terminology

Our terms align with industry standard cloud terminology. All three major providers use "service" and "category" the same way we do.

| UIS | Azure | AWS | GCP | Notes |
|-----|-------|-----|-----|-------|
| **Service** | Service/Product | Service | Product | Same concept everywhere — individual deployable unit |
| **Category** | Product Category | Service Category | Product Category | Same concept — all providers group services into categories |
| **Package** | No equivalent | No equivalent | No equivalent | UIS-specific. Cloud providers ship integrated products. We compose packages from open-source services. |
| **Dependency** | Not formally named | Not formally named | Not formally named | All providers have dependencies but don't name the concept |
| **Solution** | Solution | Solution | Solution | Same concept everywhere — end-user software running on services |

Our category names map closely to what all three providers use:

| UIS Category | Azure | AWS | GCP |
|---|---|---|---|
| Databases | Databases | Database | Databases |
| Networking | Networking | Networking & Content Delivery | Networking |
| AI | AI + Machine Learning | Machine Learning | AI and Machine Learning |
| Analytics | Analytics | Analytics | Data Analytics |
| Management | Management and Governance | Management & Governance | Management Tools |
| Identity | Identity | Security, Identity & Compliance | Identity & Security |
| Observability | Monitor | Management & Governance | Operations |
| Storage | Storage | Storage | Storage |
| Integration | Integration | Application Integration | Application Integration |

**Service** and **category** are industry standard. **Package** is our addition — it's needed because we compose integrated capabilities from separate open-source services, whereas cloud providers ship them as single products (e.g., Azure Monitor = one product that covers metrics, logs, and traces).

### Renames

**Data Science → Analytics**: Align with Azure/AWS/GCP category naming. All three providers group Spark, data governance, and notebooks under Analytics.

**Network → Networking**: Align with Azure/AWS/GCP category naming.

**Authentication → Identity**: Align with Azure/AWS/GCP. "Identity" covers the full scope — users, groups, SSO, OAuth — not just authentication.

**Core → Management**: nginx and whoami are verification/test tools, not core infrastructure. Move them into Management alongside other admin/utility services (argocd, pgadmin, redisinsight). Eliminates the Core category.

**Queues → Integration** (+ move Gravitee from Management): RabbitMQ (message broker) and Gravitee (API gateway) are both integration tools. Align with Azure/AWS/GCP naming.

**Search → Databases** (move Elasticsearch): Elasticsearch is a data store with search capabilities. Cloud providers put search under Databases or Analytics. Eliminates the single-service Search category.

| What | Current | New |
|------|---------|-----|
| Category value | `DATASCIENCE` | `ANALYTICS` |
| Service folder | `services/datascience/` | `services/analytics/` |
| Docs folder | `packages/datascience/` | `packages/analytics/` |
| Sidebar label | "Data Science" | "Analytics" |
| Category value | `NETWORK` | `NETWORKING` |
| Service folder | `services/network/` | `services/networking/` |
| Docs folder | (separate top-level) | `packages/networking/` |
| Sidebar label | "Networking" | "Networking" (already correct) |
| Category value | `AUTHENTICATION` | `IDENTITY` |
| Service folder | `services/authentication/` | `services/identity/` |
| Docs folder | `packages/authentication/` | `packages/identity/` |
| Sidebar label | "Authentication" | "Identity" |
| Category value | `CORE` | `MANAGEMENT` (merge) |
| Service folder | `services/core/` | `services/management/` (move nginx, whoami) |
| Docs folder | `packages/core/` | `packages/management/` (merge) |
| Sidebar label | "Core Services" | "Management" (merge) |
| Category value | `QUEUES` | `INTEGRATION` |
| Service folder | `services/queues/` | `services/integration/` (move rabbitmq) |
| Service move | gravitee from `services/management/` | `services/integration/` |
| Docs folder | `packages/queues/` | `packages/integration/` |
| Sidebar label | "Message Queues" | "Integration" |
| Category value | `SEARCH` | `DATABASES` (merge) |
| Service move | elasticsearch from `services/search/` | `services/databases/` |
| Docs folder | `packages/search/` | `packages/databases/` (merge) |
| Sidebar label | "Search" | "Databases" (merge) |

These renames should be part of the implementation plan.

### Traefik — Documentation Only

Traefik is the ingress controller that routes all traffic into the cluster. Every service with an IngressRoute depends on it. It belongs in the Networking category but is different from other services:

- **Rancher Desktop (k3s)**: Pre-installed, comes with k3s
- **Azure AKS**: Installed via Helm in `hosts/azure-aks/02-azure-aks-setup.sh`
- **Ubuntu MicroK8s**: Enabled as a MicroK8s addon

For now, traefik gets a documentation page in Networking but no `service-traefik.sh` or `./uis deploy traefik`. Making it a deployable UIS service is deferred to INVESTIGATE-system-remote-deployment-targets (where platform-specific setup is addressed).

### Storage — Documentation Only

Storage is foundational — the storage class alias (`000-storage-class-alias.yaml`) is the very first manifest applied, before any service can use PVCs. Like traefik, it's platform-dependent:

- **Rancher Desktop (k3s)**: Needs `000-storage-class-alias.yaml` to create `microk8s-hostpath` storage class using the `rancher.io/local-path` provisioner
- **Ubuntu MicroK8s**: Needs `010-move-hostpath-storage.yml` to move storage to `/mnt/urbalurbadisk/kubernetesstorage`
- **Azure AKS**: Uses Azure-managed storage classes

For now, storage gets documentation pages but no `./uis deploy storage`. Platform-specific setup is deferred to INVESTIGATE-system-remote-deployment-targets.

### Dependencies

A **dependency** is a service that must be deployed before another service can work. The reason doesn't matter for the CLI — whether it's for data storage, verification, or monitoring, the deploy order is the same.

Expressed in service scripts as `SCRIPT_REQUIRES="postgresql redis"`. The CLI uses this to enforce deployment order in `./uis deploy` and `./uis test-all`.

Current dependency graph:

```
postgresql ← authentik, openwebui, litellm, unity-catalog, pgadmin
redis ← authentik, redisinsight
nginx ← tailscale-tunnel
prometheus ← grafana
loki ← grafana
tempo ← grafana
otel-collector ← (needs prometheus, loki, tempo for E2E)
```

In documentation, each service page shows both directions:
- **Depends on** — what must be deployed first
- **Required by** — what depends on this service

### Service-to-Documentation Relationship

Each service has exactly **one service script** and exactly **one primary doc page**. The primary page follows the standard template and is auto-generatable. Additional pages can be added manually for deep topics.

The connection: `SCRIPT_ID` maps one-to-one to the primary doc page. Convention: `packages/<lowercase-category>/<script-id>.md`.

**Package example (identity):**

```
packages/identity/
├── index.md              ← package index (auto-generatable)
├── authentik.md          ← primary service page for authentik (auto-generatable)
├── authentik-sso.md      ← additional: SSO setup guide (manual)
├── auth10-system.md      ← additional: Auth10 multi-domain system (manual)
└── authentik-testing.md  ← additional: E2E auth testing (manual)
```

**Category example (databases):**

```
packages/databases/
├── index.md              ← category index (auto-generatable)
├── postgresql.md         ← primary service page (auto-generatable)
├── mysql.md              ← primary service page (auto-generatable)
├── mongodb.md            ← primary service page (auto-generatable)
├── qdrant.md             ← primary service page (auto-generatable)
└── redis.md              ← primary service page (auto-generatable)
```

**Rules:**
- One service script → one primary doc page (one-to-one)
- Primary pages follow the standard template and are auto-generatable
- Additional pages are free-form, written manually, linked from the primary page or index
- Package/category index pages are also auto-generatable from service metadata

### Where This Is Used Today

| Context | Term | Maps to |
|---------|------|---------|
| CLI: `./uis list` | `CATEGORY` column | Category name |
| Service scripts | `SCRIPT_CATEGORY="DATABASES"` | Category name (uppercase) |
| Docs sidebar | "Packages" parent | Contains both packages and categories |
| Service folders | `provision-host/uis/services/databases/` | Category name (lowercase) |

### Future: Solutions

Today UIS contains **services** — infrastructure building blocks. In the future, UIS will also contain **solutions** — end-user software that runs on top of services.

| Type | Examples | Audience |
|------|----------|----------|
| **Service** | postgresql, grafana, authentik, redis | Developers, ops |
| **Solution** | Nextcloud, OpenMetadata | End users, data teams |

Solutions differ from services:
- They depend on multiple services (a solution might need postgresql + redis + authentik)
- They have their own user-facing UI and workflows
- They are what end users interact with; services are what solutions are built on

The documentation structure should be ready for this from the start:

```
Packages/              ← contains both packages and categories of services
  Observability/
  Databases/
  AI/
  ...
Solutions/             ← end-user software (future)
  Nextcloud/
  OpenMetadata/
  ...
```

Solution pages would use the service page template with additional sections:
- **User Guide** — how end users use the solution
- **Infrastructure Requirements** — which packages/services must be deployed first
- **Integration** — how the solution connects to UIS services (auth via Authentik, storage via PostgreSQL, etc.)

---

## Current Documentation Problems

### 1. No Standard Service Page Template

Current service pages vary wildly:

| Service | Lines | Sections | Approach |
|---------|------:|----------|----------|
| PostgreSQL | 380 | 9 sections, SQL examples, backup procedures | Comprehensive |
| Prometheus | 600+ | Architecture diagrams, PromQL examples | Very detailed |
| Authentik | 500+ | Multi-domain auth, blueprints, E2E tests | Deep |
| Elasticsearch | 185 | Decision matrix, basic setup | Light |
| Spark | ~150 | Basic deployment only | Minimal |
| nginx | ~100 | Overview only | Bare |

A new user reading PostgreSQL docs gets a different experience than reading Spark docs.

### 2. Old Command References

~6 files reference pre-UIS patterns:

| File | Old Pattern |
|------|-------------|
| `packages/authentication/index.md` | `./scripts/packages/auth.sh` |
| `packages/ai/index.md` | `./scripts/packages/ai.sh`, `./scripts/manage/k9s.sh` |
| `packages/ai/litellm.md` | Older script patterns |
| `provision-host/kubernetes.md` | Raw `/mnt/urbalurbadisk/` paths |
| `reference/troubleshooting.md` | Only kubectl, no `./uis` equivalents |

### 3. Missing Information

Information that exists in service scripts but not in docs:

| Missing | Where It Lives Today |
|---------|---------------------|
| Service dependencies | `SCRIPT_REQUIRES` in service scripts |
| Deployment order | `SCRIPT_PRIORITY` in service scripts |
| Helm chart + version | Ansible playbooks (mostly unpinned) |
| Container images | Manifests and config files |
| Deploy/undeploy commands | `./uis deploy/undeploy <service>` — not in most docs |
| Verification commands | `SCRIPT_CHECK_COMMAND` in service scripts |
| All `./uis` commands | No CLI reference doc exists |

### 4. No Package vs Category Distinction

Some groups are packages (all services work together — observability, AI) and some are categories of independent services (databases, networking). The docs treat them identically. Packages need deployment sequence docs ("deploy these 5 in this order"). Non-package categories need selection guidance ("postgresql vs mysql vs mongodb — when to use which").

---

## Design: Service Page Template

Every service page should follow a consistent template. This template is what auto-generation will eventually produce.

### Proposed Template

```markdown
---
title: <Service Name>
sidebar_label: <Service Name>
---

# <Service Name>

<One-sentence description from SCRIPT_DESCRIPTION>

| | |
|---|---|
| **Package/Category** | <package or category name> |
| **Deploy** | `./uis deploy <service-id>` |
| **Undeploy** | `./uis undeploy <service-id>` |
| **Depends on** | <service-ids or "None"> |
| **Required by** | <service-ids or "None"> |
| **Helm chart** | `<chart-name>` <version or "unpinned"> |
| **Default namespace** | `<namespace>` |

## What It Does

<2-3 paragraphs explaining the service, what problems it solves,
and how it fits in the UIS stack. From SCRIPT_SUMMARY or manual.>

## Deploy

```bash
# Prerequisites — deploy dependencies first
./uis deploy <dependency-1>
./uis deploy <dependency-2>

# Deploy this service
./uis deploy <service-id>
```

## Verify

```bash
# Quick check
./uis verify <service-id>

# Manual check
kubectl get pods -n <namespace> -l <label>
```

## Configuration

<What users can customize in .uis.secrets/ or .uis.extend/.
Show the relevant variables from common-values.env.template
and what they control.>

## Undeploy

```bash
./uis undeploy <service-id>
```

## Troubleshooting

<3-5 most common issues with solutions.
Keep it practical — what the user sees, what to run.>

## Learn More

- Official documentation (generated by SCRIPT_WEBSITE)
- <Links to related UIS service pages>
```

### What This Template Gives Us

- **Consistent** — every service page has the same sections in the same order
- **Actionable** — leads with deploy/undeploy commands, not architecture theory
- **Dependency-aware** — shows what to deploy first and what depends on this service
- **Auto-generatable** — every field maps to script metadata or can be derived from it
- **Extensible** — services that need more detail (PostgreSQL, Authentik) add sections below the template

### Template Field → Metadata Mapping

| Template Field | Source | Auto-generatable? |
|----------------|--------|:-:|
| Service Name | `SCRIPT_NAME` | Yes |
| Description | `SCRIPT_DESCRIPTION` | Yes |
| Package/Category | `SCRIPT_CATEGORY` | Yes |
| Deploy command | `SCRIPT_ID` | Yes |
| Undeploy command | `SCRIPT_ID` | Yes |
| Dependencies | `SCRIPT_REQUIRES` | Yes |
| Required by | Reverse lookup of all `SCRIPT_REQUIRES` | Yes |
| Helm chart | New: `SCRIPT_HELM_CHART` | Yes (once added) |
| Namespace | Playbook or manifest | Needs investigation |
| What It Does | Manual or `SCRIPT_SUMMARY` | Partial |
| Configuration | Manual (secrets/config vars) | Partial |
| Troubleshooting | Manual | No |
| Learn More | `SCRIPT_WEBSITE` + manual | Partial |

---

## Design: Index Page Templates

Two templates — one for packages (integrated services), one for categories (independent services).

### Package Index Template (observability, AI, analytics, identity)

```markdown
---
title: <Package Name>
---

# <Package Name>

<What this package provides as a whole. Why these services belong together.>

## Services

| Service | Role in this package | Dependencies |
|---------|---------------------|-------------|
| [<name>](./<id>.md) | <role> | <deps or "None"> |
| ... | ... | ... |

## Deploy the Full Package

Deploy in this order (dependencies first):

```bash
./uis deploy <service-1>   # foundation
./uis deploy <service-2>   # depends on service-1
./uis deploy <service-3>   # depends on service-1
./uis deploy <service-4>   # depends on service-2 and service-3
```

## Architecture

<How the services connect to each other. Mermaid diagram showing data flow.>
```

### Category Index Template (databases, networking, management, storage, integration)

```markdown
---
title: <Category Name>
---

# <Category Name>

<What this category provides. When you would use these services.>

## Services

| Service | Description | Use Case |
|---------|-------------|----------|
| [<name>](./<id>.md) | <description> | <when to choose this> |
| ... | ... | ... |

## Choosing a Service

<Guidance on which service to pick. Comparison of alternatives.>
```

---

## Design: UIS CLI Reference

New page: `reference/uis-cli-reference.md`

Sections:
- **Container management**: `./uis start`, `./uis stop`, `./uis shell`, `./uis build`
- **Service management**: `./uis list`, `./uis deploy`, `./uis undeploy`, `./uis verify`
- **Secrets**: `./uis secrets status`, `./uis secrets generate`
- **Testing**: `./uis test-all`, `./uis test-all --dry-run`, `./uis test-all --clean`
- **Service-specific**: `./uis tailscale expose/unexpose/verify`
- **Initialization**: `./uis init`, `./uis provision`

---

## Design: Service Dependency Page

New page showing the full dependency graph — either as a Mermaid diagram or table. Auto-generatable from `SCRIPT_REQUIRES` across all service scripts.

```
postgresql ← authentik, openwebui, litellm, unity-catalog, pgadmin
redis ← authentik, redisinsight
prometheus ← grafana
loki ← grafana
tempo ← grafana
otel-collector ← (standalone, but needs backends for E2E)
nginx ← tailscale-tunnel
traefik ← (all services with IngressRoute — platform dependency, not in SCRIPT_REQUIRES)
storage ← (all services with PVC — platform dependency, not in SCRIPT_REQUIRES)
```

---

## Implementation Strategy

### Phase 1: Category Renames

Rename categories, folders, and sidebar entries to match the new terminology. This must happen first because all subsequent documentation work uses the new names.

- Rename service folders (`services/datascience/` → `services/analytics/`, etc.)
- Update `SCRIPT_CATEGORY` values in all service scripts
- Rename docs folders (`packages/authentication/` → `packages/identity/`, etc.)
- Update sidebar configuration
- Move services: nginx/whoami → management, gravitee → integration, elasticsearch → databases

### Phase 2: Design Validation (Prototype)

Pick 3 services at different complexity levels and rewrite them using the template:
- **Simple**: whoami or nginx (no dependencies, minimal config)
- **Medium**: redis or postgresql (dependencies, secrets, common issues)
- **Complex**: authentik (multi-service deps, blueprints, multi-domain)

Review the prototypes to validate the template works. Adjust before doing all services.

### Phase 3: Create Foundation Docs

- `reference/uis-cli-reference.md` — CLI reference
- Service dependency matrix page
- Quick-start guide

### Phase 4: Rewrite All Service Pages

Apply the validated template to all services (26 deployable + 2 doc-only: traefik, storage). Fix old references along the way.

### Phase 5: Rewrite Index Pages

Standardize all index pages using the appropriate template (package index for integrated services, category index for independent services).

### Phase 6: Clean Up

- Remove `rules/documentation-legacy.md` or archive it
- Verify sidebar matches the new category structure
- Add notes to host docs about future `./uis target` commands

---

## Connection to Other Investigations

- **INVESTIGATE-documentation-generation**: This rewrite IS the prototype. The template we design here becomes the spec for auto-generation. Every field that maps to script metadata is a field the generator can fill in.
- **INVESTIGATE-system-version-pinning**: Once versions are pinned in script metadata, they appear automatically in the "Helm chart" field of each service page.
- **INVESTIGATE-system-remote-deployment-targets**: Host docs stay as-is until target management exists.

---

## Next Steps

Create a PLAN starting with Phase 1 (prototype 3 service pages) to validate the template.
