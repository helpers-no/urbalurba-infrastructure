# How Deployment Works

This page explains what happens under the hood when you run `./uis deploy`. If you just want to deploy services, see the [Deploy System overview](../contributors/architecture/deploy-system.md). If you want to add a new service, see the [Adding a Service guide](../contributors/guides/adding-a-service.md).

## The Deploy Flow

When you run `./uis deploy <service>`, the system follows these steps:

```
./uis deploy postgresql
    |
    +-- 1. Service discovery
    |     Find service-postgresql.sh in provision-host/uis/services/
    |
    +-- 2. Load metadata
    |     Source the file to read all SCRIPT_* variables
    |
    +-- 3. Check dependencies
    |     For each service in SCRIPT_REQUIRES, verify it's running
    |     (fail fast if any dependency is missing)
    |
    +-- 4. Execute deployment
    |     If SCRIPT_PLAYBOOK: run ansible-playbook
    |     If SCRIPT_MANIFEST: run kubectl apply
    |
    +-- 5. Health check
    |     Wait 2 seconds, then run SCRIPT_CHECK_COMMAND
    |     (failure is a warning, not an error)
    |
    +-- 6. Auto-enable
          Add service to enabled-services.conf
```

### Step 1: Service Discovery

The service scanner (`lib/service-scanner.sh`) finds services by walking `provision-host/uis/services/` recursively for `*.sh` files. Files starting with `_` (helper scripts) are skipped.

During discovery, the scanner parses each file **line by line** — it does not `source` the scripts. This is a safety measure so that unknown scripts can't execute code during a scan. Only when you actually deploy does the system `source` the metadata file.

Results are cached in memory for performance.

### Step 2: Load Metadata

When deploying, the system sources the service script to load all `SCRIPT_*` variables. For example, `service-postgresql.sh` sets:

```bash
SCRIPT_ID="postgresql"
SCRIPT_NAME="PostgreSQL"
SCRIPT_CATEGORY="DATABASES"
SCRIPT_PLAYBOOK="040-database-postgresql.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="30"
```

See [Service metadata fields](#service-metadata-fields) below for the key fields and a link to the complete reference.

### Step 3: Check Dependencies

If `SCRIPT_REQUIRES` lists other service IDs (space-separated), each dependency is verified before deployment begins. Verification runs each dependency's `SCRIPT_CHECK_COMMAND` — if the command exits 0, the dependency is considered deployed.

If any dependency is missing, deployment **fails immediately** with an error message telling you which service needs to be deployed first.

Example: OpenWebUI requires PostgreSQL:

```bash
# In service-openwebui.sh
SCRIPT_REQUIRES="postgresql"
```

Running `./uis deploy openwebui` without PostgreSQL deployed will fail with:
```
Required service 'postgresql' is not deployed
```

### Step 4: Execute Deployment

Two deployment methods exist (mutually exclusive — if both are set, playbook wins):

| Method | Field | What happens |
|--------|-------|-------------|
| **Ansible playbook** | `SCRIPT_PLAYBOOK` | `ansible-playbook <playbook> -e "target_host=<host>"` |
| **Direct manifest** | `SCRIPT_MANIFEST` | `kubectl apply -f <manifest>` |

All current services use Ansible playbooks. The playbook filename refers to a file in `ansible/playbooks/`.

The **target host** (which Kubernetes cluster to deploy to) is read from `.uis.extend/cluster-config.sh`. The default is `rancher-desktop` (local development). Other supported values: `azure-aks`, `azure-microk8s`, `multipass-microk8s`, `raspberry-microk8s`.

### Step 5: Health Check

After deployment, if `SCRIPT_CHECK_COMMAND` is set, the system:

1. Waits 2 seconds for the service to start
2. Runs the check command
3. If it exits 0: reports success
4. If it fails: reports a **warning** (not an error) — the service may need more time to start

Most health checks look for Running pods:

```bash
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | grep -q Running"
```

### Step 6: Auto-Enable

After a successful deployment, the service is automatically added to `enabled-services.conf`. This means running `./uis deploy` (without arguments) in the future will include this service.

---

## Deploy-All Flow

Running `./uis deploy` with no argument deploys all services listed in `.uis.extend/enabled-services.conf`, in the order they appear in the file. It **stops on the first failure** — if service 3 of 10 fails, services 4–10 are skipped.

```bash
# Deploy all enabled services
./uis deploy

# See what's enabled
./uis list-enabled
```

---

## Priority Ordering

Each service has a `SCRIPT_PRIORITY` value (default: 50). Lower numbers deploy first. This matters when deploying multiple services — infrastructure services like storage and databases should deploy before services that depend on them.

| Priority Range | Typical Use |
|:---:|---|
| 10–20 | Core infrastructure (storage, ingress) |
| 25–30 | Databases and caches |
| 40–50 | Application services (default) |
| 60+ | Management and monitoring tools |

Example priorities from actual services:

| Service | Priority | Why |
|---------|:---:|---|
| PostgreSQL | 30 | Database — many services depend on it |
| Redis | 30 | Cache — Authentik depends on it |
| Authentik | 50 | Needs PostgreSQL and Redis first |
| Grafana | 50 | Needs Prometheus, Loki, Tempo for full functionality |
| pgAdmin | 50 | Needs PostgreSQL |

---

## Dependency Resolution

Dependencies are declared in `SCRIPT_REQUIRES` as a space-separated list of service IDs:

```bash
# Authentik requires both PostgreSQL and Redis
SCRIPT_REQUIRES="postgresql redis"
```

When deploying, the system checks each dependency by running its `SCRIPT_CHECK_COMMAND`. This is a **runtime check** — it verifies the service is actually running in the cluster, not just that it's listed in the enabled config.

Dependencies are **not transitive**. If service A requires B, and B requires C, deploying A only checks that B is running — it doesn't check C. The assumption is that B wouldn't be running if C weren't already deployed.

Current dependency chain:

```
postgresql ← pgAdmin, OpenWebUI, LiteLLM, Unity Catalog, Authentik, OpenMetadata
redis ← Authentik, RedisInsight
postgresql + redis ← Authentik
postgresql + elasticsearch ← OpenMetadata
```

---

## Stacks

Stacks are pre-defined bundles of services that work together. They deploy multiple services with a single command.

### Available Stacks

| Stack | Services | Optional |
|-------|----------|----------|
| **observability** | Prometheus, Tempo, Loki, OTel Collector, Grafana | OTel Collector |
| **ai-local** | LiteLLM, OpenWebUI | — |
| **analytics** | Spark, JupyterHub, Unity Catalog | Unity Catalog |

### How Stacks Work

- **Install** (`./uis stack install <name>`): deploys services left-to-right in the defined order (dependencies first)
- **Remove** (`./uis stack remove <name>`): removes services in **reverse** order (dependents first)
- **`--skip-optional`**: skips services marked as optional for that stack

Each service installed via a stack is automatically added to `enabled-services.conf`, just like a regular deploy.

Stacks are defined in `provision-host/uis/lib/stacks.sh`. To add a custom stack, see [Adding a Custom Stack](../contributors/rules/kubernetes-deployment.md#adding-a-custom-stack) in the deployment rules.

---

## Undeploy Flow

When you run `./uis undeploy <service>`, the system uses a three-tier removal strategy:

1. **Removal playbook** (`SCRIPT_REMOVE_PLAYBOOK`): if set, runs the Ansible playbook. The field can include extra parameters after the filename (e.g., `085-remove-enonic.yml -e "operation=delete"`)
2. **Manifest deletion** (`SCRIPT_MANIFEST`): if no removal playbook, runs `kubectl delete -f <manifest> --ignore-not-found`
3. **No method**: if neither is set, prints a warning that manual cleanup may be required

:::note
Undeploy does **not** delete PersistentVolumeClaims (PVCs) by default. Your data is preserved. To fully clean up, delete PVCs manually:
```bash
kubectl delete pvc -n <namespace> -l app=<service>
```
:::

---

## Autostart Configuration

The file `.uis.extend/enabled-services.conf` controls which services deploy when running `./uis deploy` without arguments.

:::warning Despite the name, this is not a boot mechanism
Nothing in UIS runs at boot. This file is the default argument list for
`./uis deploy`, and that command only runs when a person or a script runs it.

After a host restart, **already-deployed services return without any UIS
command** — they are cluster state, and the kubelet restarts their pods once the
cluster is up. What UIS does not do is start the cluster: Rancher Desktop is
installed at OS level (`platform-switching.sh`, `pf_list_platforms`), so bringing
it up with the machine is a host setting.

The failure this warning exists to prevent: services look "gone" after a reboot,
someone redeploys everything, and the actual cause was a cluster that never
started.
:::

```bash
# Enable a service (adds to enabled-services.conf)
./uis enable postgresql

# Disable a service (removes from enabled-services.conf)
./uis disable postgresql

# List what's enabled
./uis list-enabled

# Sync enabled list with what's actually running in the cluster
./uis sync
```

The `sync` command scans the cluster for running services and updates the enabled list to match — useful after manual deployments or when the list gets out of sync.

Note: `./uis deploy <service>` automatically enables the service, so you rarely need to run `./uis enable` separately.

---

## Service Metadata Fields

Each service is defined by a metadata file in `provision-host/uis/services/<category>/service-<id>.sh`. The key fields that control deployment are:

| Field | Purpose | Example |
|-------|---------|---------|
| `SCRIPT_ID` | Unique identifier used in CLI commands | `"postgresql"` |
| `SCRIPT_NAME` | Human-readable display name | `"PostgreSQL"` |
| `SCRIPT_CATEGORY` | Category grouping (must match a category ID) | `"DATABASES"` |
| `SCRIPT_PLAYBOOK` | Ansible playbook filename in `ansible/playbooks/` | `"040-database-postgresql.yml"` |
| `SCRIPT_MANIFEST` | Kubernetes manifest (alternative to playbook) | `""` |
| `SCRIPT_REMOVE_PLAYBOOK` | Ansible playbook for removal | `"040-remove-database-postgresql.yml"` |
| `SCRIPT_CHECK_COMMAND` | Shell command that exits 0 if service is healthy | `"kubectl get pods ... \| grep -q Running"` |
| `SCRIPT_REQUIRES` | Space-separated service IDs this service depends on | `"postgresql redis"` |
| `SCRIPT_PRIORITY` | Deploy order — lower numbers deploy first (default: 50) | `"30"` |

These are just the deployment-related fields. Services also have extended metadata for Backstage catalog generation, website documentation, and more.

For the **complete field reference** with all metadata groups (deployment, extended, website), constraints, and examples, see:
- **[Kubernetes Deployment Rules](../contributors/rules/kubernetes-deployment.md)** — full metadata specification
- **[Adding a Service Guide](../contributors/guides/adding-a-service.md)** — step-by-step guide with field descriptions

---

## Related Documentation

- **[Deploy System Overview](../contributors/architecture/deploy-system.md)** — High-level overview of deploying and managing services
- **[UIS CLI Reference](../reference/uis-cli-reference.md)** — Complete command reference
- **[Kubernetes Deployment Rules](../contributors/rules/kubernetes-deployment.md)** — Service metadata specification and deployment conventions
- **[Adding a Service Guide](../contributors/guides/adding-a-service.md)** — How to create a new service
