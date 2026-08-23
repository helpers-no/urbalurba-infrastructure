# Rules for UIS Deployment System

## Relationship to Other Rules

This document covers the **orchestration and automation framework**:
- How the UIS CLI discovers and deploys services
- Service metadata files and the deploy/undeploy lifecycle
- Stacks (pre-defined service bundles)
- Autostart configuration via `enabled-services.conf`

For **how to write individual Ansible playbooks**, see:
> [Rules for Provisioning](./provisioning.md) - Implementation patterns for playbooks

For **file and resource naming patterns**, see:
> [Naming Conventions](./naming-conventions.md)

## Core Principles

0. **Every service runs on a developer's laptop.** A UIS service MUST be
   deployable to Rancher Desktop / k3s with `uis deploy <id>` and nothing else —
   no second machine, no hand-built prerequisite, no manual step. Production may
   differ in **topology** (state deliberately lives outside the cluster there),
   never in **interface**. A service provided externally in production still
   ships an in-cluster form for development. This is principle zero because the
   others describe *how* a service is built; this one decides whether it is a UIS
   service at all. See
   [adding-a-service](../guides/adding-a-service.md) and
   [INVESTIGATE-system-external-or-in-cluster-services](../../ai-developer/plans/backlog/INVESTIGATE-system-external-or-in-cluster-services.md).

1. **Declarative Service Metadata**: Each service is defined by a metadata file (`service-*.sh`) that declares its properties, deployment method, dependencies, and health check
2. **CLI-Driven Deployment**: All deployments are performed through `./uis deploy` and `./uis undeploy` commands
3. **Dependency Management**: Services declare their requirements via `SCRIPT_REQUIRES` and the system verifies dependencies before deploying
4. **Ansible for Heavy Lifting**: Metadata files delegate actual deployment to Ansible playbooks — no business logic in metadata
5. **Idempotency**: All deployments MUST be safe to run multiple times
6. **Health Verification**: Services define a `SCRIPT_CHECK_COMMAND` for post-deploy health checks

## UIS CLI Commands

### Service Deployment

```bash
# Deploy a single service (also enables it for autostart)
./uis deploy postgresql

# Deploy all enabled services (from enabled-services.conf)
./uis deploy

# Undeploy a single service
./uis undeploy postgresql
```

### Service Management

```bash
# List all available services (grouped by category)
./uis list
./uis list --all            # Include disabled services
./uis list --category AI    # Filter by category

# Show deployed services with health status
./uis status

# Enable/disable autostart (does not deploy/undeploy)
./uis enable postgresql
./uis disable postgresql

# List enabled services
./uis list-enabled
```

### Stack Operations

```bash
# List available stacks
./uis stack list

# Show stack details (services, descriptions)
./uis stack info observability

# Install a stack (deploys all services in order)
./uis stack install observability

# Install stack without optional services
./uis stack install observability --skip-optional

# Remove a stack (undeploys in reverse order)
./uis stack remove observability
```

### Other Commands

```bash
# Show version
./uis version

# Interactive setup menu
./uis setup

# First-time initialization
./uis init

# Sync enabled list with what's actually running in cluster
./uis sync

# Legacy: run old provision-kubernetes.sh system
./uis provision
```

## Service Architecture

### Service Metadata Files

Every service is defined by a metadata file in `provision-host/uis/services/<category>/`:

```
provision-host/uis/services/
├── ai/
│   ├── service-litellm.sh
│   └── service-openwebui.sh
├── analytics/
│   ├── service-jupyterhub.sh
│   ├── service-spark.sh
│   └── service-unity-catalog.sh
├── databases/
│   ├── service-elasticsearch.sh
│   ├── service-mongodb.sh
│   ├── service-mysql.sh
│   ├── service-postgresql.sh
│   └── service-redis.sh
├── identity/
│   └── service-authentik.sh
├── integration/
│   └── service-rabbitmq.sh
├── management/
│   ├── service-argocd.sh
│   ├── service-pgadmin.sh
│   ├── service-redisinsight.sh
│   └── service-whoami.sh
├── networking/
│   └── service-cloudflare-tunnel.sh
└── observability/
    ├── service-grafana.sh
    ├── service-loki.sh
    ├── service-otel-collector.sh
    ├── service-prometheus.sh
    └── service-tempo.sh
```

### Metadata File Structure

Each metadata file declares service properties as shell variables. The scanner reads these by parsing the file line-by-line (it does NOT `source` the file during discovery, for safety).

```bash
#!/bin/bash
# service-postgresql.sh - PostgreSQL service metadata

# === Service Metadata (Required) ===
SCRIPT_ID="postgresql"                    # Unique ID used in CLI commands
SCRIPT_NAME="PostgreSQL"                  # Human-readable display name
SCRIPT_DESCRIPTION="Open-source relational database"
SCRIPT_CATEGORY="DATABASES"               # Must match a category ID

# === Deployment Configuration (Optional) ===
SCRIPT_PLAYBOOK="040-database-postgresql.yml"   # Ansible playbook (preferred)
SCRIPT_MANIFEST=""                              # Direct kubectl manifest (alternative)
SCRIPT_REMOVE_PLAYBOOK="040-remove-database-postgresql.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REQUIRES=""                        # Space-separated service IDs
SCRIPT_PRIORITY="30"                      # Deploy order (lower = earlier, default: 50)

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="bitnami/postgresql"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Resource"            # Component | Resource
SCRIPT_TYPE="database"            # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"     # platform-team | app-team
SCRIPT_PROVIDES_APIS=""          # API names this service provides (e.g., "myservice-api")
SCRIPT_CONSUMES_APIS=""          # API names this service consumes (e.g., "litellm-api")

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="World's most advanced open-source relational database"
SCRIPT_LOGO="postgresql-logo.webp"
SCRIPT_WEBSITE="https://www.postgresql.org"
SCRIPT_TAGS="database,sql,relational,postgres,rdbms"
SCRIPT_SUMMARY="PostgreSQL is a powerful, open-source object-relational database system..."
SCRIPT_DOCS="/docs/services/databases/postgresql"
```

**Three metadata groups:**

| Group | Fields | Purpose |
|-------|--------|---------|
| Required | `SCRIPT_ID`, `SCRIPT_NAME`, `SCRIPT_DESCRIPTION`, `SCRIPT_CATEGORY` | Service identity and discovery |
| Deployment | `SCRIPT_PLAYBOOK`, `SCRIPT_MANIFEST`, `SCRIPT_CHECK_COMMAND`, `SCRIPT_REMOVE_PLAYBOOK`, `SCRIPT_REQUIRES`, `SCRIPT_PRIORITY`, `SCRIPT_NAMESPACE` | How to deploy, verify, and remove |
| Extended | `SCRIPT_KIND`, `SCRIPT_TYPE`, `SCRIPT_OWNER`, `SCRIPT_PROVIDES_APIS`, `SCRIPT_CONSUMES_APIS` | Backstage catalog generation |
| Website | `SCRIPT_ABSTRACT`, `SCRIPT_LOGO`, `SCRIPT_WEBSITE`, `SCRIPT_TAGS`, `SCRIPT_SUMMARY`, `SCRIPT_DOCS` | Documentation generation |

**Important constraints:**
- `SCRIPT_PLAYBOOK` and `SCRIPT_MANIFEST` are mutually exclusive — if both are set, playbook takes precedence
- `SCRIPT_REMOVE_PLAYBOOK` can include extra Ansible parameters after the filename (space-separated)
- Files starting with `_` (e.g., `_helper.sh`) are skipped by the scanner
- Each variable must be on its own line in `KEY="value"` format for the line-by-line parser

### Categories

Services are organized into 10 categories (defined in `provision-host/uis/lib/categories.sh`):

| Category ID | Display Name | Description | Manifest Range |
|------------|--------------|-------------|----------------|
| `OBSERVABILITY` | Observability | Metrics, logs, and tracing | 030-039 |
| `AI` | AI & ML | AI and machine learning services | 200-229 |
| `ANALYTICS` | Analytics | Data science and analytics platforms | 300-399 |
| `AUTOMATION` | Automation | Browser automation, synthetic checks, and agent tooling | 400-429 |
| `IDENTITY` | Identity | Identity and access management | 070-079 |
| `DATABASES` | Databases | Data storage and caching services | 040-044, 050-069 |
| `MANAGEMENT` | Management | Admin tools, GitOps, and test services | 600-799 |
| `APPLICATIONS` | Applications | End-user applications and collaboration platforms | 620-629 |
| `NETWORKING` | Networking | VPN tunnels and network access | — |
| `STORAGE` | Storage | Platform storage infrastructure | 000-009, 045-046 |
| `INTEGRATION` | Integration | Messaging, API gateways, and event streams | 080-091 |

**Note**: The manifest range is a convention, not a constraint. A service keeps the number it was created with — reclassifying a service into another category does not renumber its playbooks and manifests. MinIO is the current example: it is a `STORAGE` service that keeps its original `045`/`046` numbers.

**Note**: Parts of `STORAGE` and `NETWORKING` are platform-dependent — Traefik and the storage provisioners/storage classes are managed by Rancher Desktop, not by `./uis deploy`. Deployable services in those categories (MinIO) work like any other service.

### Service Discovery

The service scanner (`provision-host/uis/lib/service-scanner.sh`) discovers services by:

1. Walking `provision-host/uis/services/` recursively for `*.sh` files
2. Skipping files starting with `_` (helper scripts)
3. Parsing each file line-by-line for `SCRIPT_ID=`, `SCRIPT_NAME=`, etc.
4. Caching results for performance (cache is an in-memory indexed array)

The scanner never `source`s scripts during discovery — this is a safety measure. Only `deploy_single_service` in `service-deployment.sh` actually sources a metadata file (to load all variables for deployment).

## Deploy Flow

When you run `./uis deploy <service>`, the system follows this sequence:

```
./uis deploy postgresql
    │
    ├─ 1. Find service script via service scanner
    │     └─ Locates provision-host/uis/services/databases/service-postgresql.sh
    │
    ├─ 2. Source metadata file (loads all SCRIPT_* variables)
    │
    ├─ 3. Check dependencies (SCRIPT_REQUIRES)
    │     └─ For each required service, verify it's deployed via SCRIPT_CHECK_COMMAND
    │     └─ Fail fast if any dependency is missing
    │
    ├─ 4. Execute deployment (mutually exclusive methods):
    │     ├─ If SCRIPT_PLAYBOOK: ansible-playbook <playbook> -e "target_host=<host>"
    │     └─ If SCRIPT_MANIFEST: kubectl apply -f <manifest>
    │
    ├─ 5. Post-deploy health check (if SCRIPT_CHECK_COMMAND is set)
    │     └─ Wait 2 seconds, then run health check
    │     └─ Failure is a warning, not an error
    │
    └─ 6. Auto-enable service in enabled-services.conf
```

**`./uis deploy` (no argument)** deploys all services listed in `enabled-services.conf`, in order. Stops on first failure.

**`./uis undeploy <service>`** uses a three-tier removal strategy:
1. If `SCRIPT_REMOVE_PLAYBOOK` is set: run the removal playbook
2. Else if `SCRIPT_MANIFEST` is set: `kubectl delete -f <manifest> --ignore-not-found`
3. Else: warn "no removal method found"

### Target Host

The target host (default: `rancher-desktop`) is read from `cluster-config.sh`. This determines which Kubernetes context Ansible uses. Supported cluster types:
- `rancher-desktop` (default, local development)
- `azure-aks`
- `azure-microk8s`
- `multipass-microk8s`
- `raspberry-microk8s`

## Manifests vs Templates: Single-Instance vs Multi-Instance

UIS services come in two shapes, and the shape determines how the Kubernetes YAML is authored.

### Single-instance services (the default)

One shared instance per cluster. PostgreSQL, Redis, Prometheus, Grafana — every existing service in the table above. The setup playbook applies static manifest files via `kubernetes.core.k8s: src: <file>`:

| Where | What |
|---|---|
| `manifests/<NNN>-<id>-config.yaml` | Helm values or ConfigMap |
| `manifests/<NNN>-<id>-ingressroute.yaml` | Traefik IngressRoute |
| `manifests/<NNN>-<id>-statefulset.yaml` (alt) | StatefulSet for Helm-less services |

The metadata sets `SCRIPT_MULTI_INSTANCE` to nothing (or `"false"`). `./uis deploy <id>` and `./uis undeploy <id>` operate without an `--app` flag — the CLI rejects `--app` for single-instance services with a clear error.

### Multi-instance services (per-app deployments)

One Deployment **per consuming application**, all sharing the service's namespace. PostgREST is the first such service: `./uis configure postgrest --app atlas` then `./uis deploy postgrest --app atlas` produces an `atlas-postgrest` Deployment routed at `api-atlas.<domain>`. A second app (`./uis deploy postgrest --app customers`) coexists alongside it without collision.

Static manifests do not work here — every instance needs different metadata, env-vars, and IngressRoute hostnames. Multi-instance services author **Jinja templates** instead, rendered at playbook-execution time:

| Where | What |
|---|---|
| `ansible/playbooks/templates/<NNN>-<id>-<role>.yml.j2` | Per-app Deployment, Service, IngressRoute, etc. |

The setup playbook applies them via `kubernetes.core.k8s: definition: "{{ lookup('template', '...j2') | from_yaml_all | list }}"` with per-app extra-vars (`_app_name`, `_url_prefix`, `_schema`). The metadata sets `SCRIPT_MULTI_INSTANCE="true"`, which propagates to `services.json` as `"multiInstance": true` and changes how the CLI routes lifecycle commands:

- `./uis deploy <id>` and `./uis undeploy <id>` **require** `--app <name>`.
- `./uis configure <id>` pre-checks the dependency (e.g. postgresql) is deployed, not the service itself.
- `./uis status` and `./uis list` show per-instance state (PLAN-005 polishes the formatting).

The full convention — file naming, the `_app_name`/`_url_prefix`/`_schema` extra-var contract, and `lookup('template', ...) | from_yaml_all | list` for multi-document templates — lives in [`ansible/playbooks/templates/README.md`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/templates/README.md). The contributor walkthrough is in [Adding a Service: Multi-instance services](../guides/adding-a-service.md#multi-instance-services).

### Which shape should you pick?

Default to single-instance unless you have a reason. Pick multi-instance only when each consuming application needs its own copy with its own configuration, credentials, or routing — and a shared instance would not be safe or sensible to share. Most data-plane services (databases, caches, message brokers, observability backends) are single-instance. PostgREST is multi-instance because each app exposes a different Postgres schema with different `web_anon` roles and a different public URL.

## Stacks

Stacks are pre-defined bundles of services that work together. They are defined in `provision-host/uis/lib/stacks.sh`.

### Available Stacks

| Stack | Services | Optional |
|-------|----------|----------|
| **observability** | prometheus, tempo, loki, otel-collector, grafana | otel-collector |
| **ai-local** | litellm, openwebui | — |
| **analytics** | spark, jupyterhub, unity-catalog | unity-catalog |

### Stack Behavior

- **Install**: Services are deployed left-to-right in the defined order (dependencies first)
- **Remove**: Services are removed in **reverse** order (dependents first)
- **`--skip-optional`**: Skips services listed as optional for the stack
- Each service installed via a stack is automatically added to `enabled-services.conf`

### Adding a Custom Stack

Stacks are defined in `provision-host/uis/lib/stacks.sh` using a pipe-delimited format. To add a new stack:

**1. Add a stack entry** to the `_STACK_DATA` array:

```bash
_STACK_DATA=(
    # ... existing stacks ...
    "my-stack|My Stack|Short description of the stack|CATEGORY_ID|tag1,tag2,tag3|Brief abstract|service1,service2,service3|service3|Longer summary text.|/docs/stacks/my-stack|my-stack-logo.svg"
)
```

The fields are:

| Position | Field | Description |
|:---:|-------|-------------|
| 0 | `id` | Stack identifier used in CLI commands (`./uis stack install <id>`) |
| 1 | `name` | Human-readable display name |
| 2 | `description` | Short description |
| 3 | `category` | Category ID (must match a category from categories.sh) |
| 4 | `tags` | Comma-separated tags for website metadata |
| 5 | `abstract` | Brief abstract for documentation |
| 6 | `services` | Comma-separated service IDs in installation order |
| 7 | `optional_services` | Comma-separated service IDs that `--skip-optional` will skip (subset of services) |
| 8 | `summary` | Longer summary for documentation |
| 9 | `docs` | Documentation URL path |
| 10 | `logo` | Logo filename (in `website/static/img/`) |

**2. Add the ID** to `STACK_ORDER`:

```bash
STACK_ORDER=(observability ai-local analytics my-stack)
```

**3. Test it:**

```bash
./uis stack list              # Should show your new stack
./uis stack info my-stack     # Should show services and details
./uis stack install my-stack  # Should deploy all services in order
./uis stack remove my-stack   # Should undeploy in reverse order
```

**Important:** Service order in the `services` field matters — list dependencies before dependents. The stack installer deploys left-to-right without dependency resolution (unlike `./uis deploy` which checks `SCRIPT_REQUIRES`).

## Autostart Configuration

The file `.uis.extend/enabled-services.conf` controls which services are deployed when running `./uis deploy` without arguments.

```bash
# Enable a service (adds to enabled-services.conf)
./uis enable postgresql

# Disable a service (removes from enabled-services.conf)
./uis disable postgresql

# List what's enabled
./uis list-enabled

# Sync enabled list with cluster state
./uis sync
```

The `sync` command scans the cluster for running services and adds them to the enabled list — useful after manual deployments or when the enabled list gets out of sync.

## Adding a New Service

For a complete step-by-step walkthrough, see the **[Adding a Service Guide](../guides/adding-a-service.md)**.

## Legacy System (Removed)

The old deployment system (`provision-host/kubernetes/` with numbered directories and `provision-kubernetes.sh`) was removed in March 2026. All services now deploy exclusively through the UIS CLI (`./uis deploy`). The old code is preserved in git history.

---

**Related Documentation:**
- [Rules for Provisioning](./provisioning.md) - Ansible playbook patterns
- [Naming Conventions](./naming-conventions.md) - File and resource naming
- [Rules Overview](./index.md)
- [Secrets Management](./secrets-management.md)
- [CI/CD Pipelines and Generators](../guides/ci-cd-and-generators.md) - Automated documentation generation
- [Integration Testing](../guides/integration-testing.md) - Full system testing with `test-all`
- [Ingress and Traefik](./ingress-traefik.md)
