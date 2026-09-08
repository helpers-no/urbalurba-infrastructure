---
title: UIS CLI Reference
sidebar_label: CLI Reference
---

# UIS CLI Reference

The `./uis` command manages the UIS provision-host container and all services within it. Commands are organized into host-level (managing the container) and service-level (managing Kubernetes services inside the container).

## Container Management

These commands run on the host machine and manage the UIS container.

| Command | Description |
|---------|-------------|
| `./uis start` | Start the UIS provision-host container |
| `./uis stop` | Stop the container |
| `./uis restart` | Restart the container |
| `./uis container` | Show container status |
| `./uis shell` | Open interactive bash shell in the container |
| `./uis exec <command>` | Execute a command inside the container |
| `./uis logs [--tail N]` | Show container logs (default: last 50 lines) |
| `./uis build` | Build the container image locally as `uis-provision-host:local` |

## Platform Management

UIS targets multiple Kubernetes platforms (Rancher Desktop, Azure AKS, …). The `uis platform` subcommands surface them all under a single command interface. See [Platforms overview](../platforms/index.md) for the full mechanic.

| Command | Description |
|---------|-------------|
| `./uis platform list [--offline\|--deep]` | List all platforms and their state. `--offline` skips reachability probe; `--deep` adds per-platform extras (e.g. cluster version, cost). |
| `./uis platform use [<name>] [--offline]` | Switch the active platform — kubectl context + `cluster-config.sh` flip together. No arg → interactive picker over reachable platforms. `--offline` allows switching to an unreachable platform (e.g. to clean up stale state). |
| `./uis platform init <provider>` | Interactive setup wizard for a cloud platform. Writes `.uis.secrets/cloud-accounts/<provider>-default.env`. |
| `./uis platform up <provider>` | Provision the cluster end-to-end. Chains bootstrap + tofu apply + post-apply configuration. Auto-flips active platform to the new cluster on success. |
| `./uis platform status <provider>` | Show cluster state, external IP, and rough cost estimate. Does not target the active platform — reports on the named one. |
| `./uis platform down <provider>` | Tear down the cluster. Requires typing the cluster name to confirm (irreversible). Auto-resets active platform back to `rancher-desktop` on success. |

### `platform list` — canonical output

```
$ ./uis platform list
Active: rancher-desktop

PLATFORM          STATUS
rancher-desktop   ✓ running  (active)    local k3s
azure-aks         · configured, not running  (run './uis platform up azure-aks' to start it)
```

Four possible state values per row: `✓ running`, `· configured, not running`, `· not initialized`, `✗ unreachable`. See [Platforms overview](../platforms/index.md) for what each means.

### `platform use` — canonical output

```
$ ./uis platform use rancher-desktop
✓ Switched: azure-aks → rancher-desktop
```

```
$ ./uis platform use      # no arg → interactive picker
     PLATFORM          STATUS
[1] rancher-desktop   ✓ running  (currently active)    local k3s
    azure-aks         · configured, not running  (run './uis platform up azure-aks' to start it)

Pick a platform [1-1]:
```

Only `running` platforms get selectable numbers. Switching to a `not initialized` or `unreachable` platform doesn't have a meaningful outcome.

### Banner on every cluster-touching command

`./uis deploy`, `./uis undeploy`, `./uis list`, `./uis status`, `./uis configure`, `./uis expose`, `./uis stack install`, and `./uis test all` all print a one-line banner identifying the active platform before running:

```
$ ./uis deploy nginx
ℹ  Platform: azure-aks (reachable)
(deploy output follows…)
```

If no platform is active or the active platform is unreachable, the banner aborts the command with a recovery hint. See [Platforms overview](../platforms/index.md#banner-on-every-cluster-touching-command) for all four banner cases.

## Network Management

UIS supports two networking providers — Cloudflare (production-grade tunnels with WAF + your own domain) and Tailscale (per-service Funnel for dev sharing on any network). The `uis network` subcommands manage both under a single command surface. See [Networking](../networking/index.md) for the comparison + walkthrough.

| Command | Description |
|---------|-------------|
| `./uis network list` | List both providers and their state. |
| `./uis network init <provider>` | Interactive setup wizard. `<provider>` is `cloudflare` or `tailscale`. |
| `./uis network up <provider> [flags]` | Deploy the provider into the cluster. Tailscale supports `--with-cluster-funnel` for an opt-in catch-all device. |
| `./uis network down <provider>` | Tear down the provider's cluster footprint. |
| `./uis network status <provider>` | Show provider state, tunnel/route state, pod health. |
| `./uis network verify <provider>` | Run the provider's diagnostics. |
| `./uis network expose tailscale <service> [--yes]` | Expose a service via a per-service Tailscale Funnel device. Namespace auto-detected. Tailscale-specific — Cloudflare uses cluster-wide HostRegexp routing instead. |
| `./uis network unexpose tailscale <service>` | Undo per-service Funnel exposure. |

## Service Management

### Discovery

| Command | Description |
|---------|-------------|
| `./uis list` | List all services with deployment status |
| `./uis list --category <id>` | Filter by category (e.g., `DATABASES`, `OBSERVABILITY`) |
| `./uis list --all` | Show all services including disabled |
| `./uis status` | Show deployed services health and cluster context |
| `./uis categories` | List all service categories |

### Deploy and Undeploy

| Command | Description |
|---------|-------------|
| `./uis deploy` | Deploy all enabled/autostart services |
| `./uis deploy <service-id>` | Deploy a specific service (auto-enables it) |
| `./uis undeploy <service-id>` | Remove a service from the cluster |

### Autostart Configuration

Services can be marked for automatic deployment.

:::warning "Autostart" does not mean "starts at boot"
Nothing in UIS runs when the machine boots. The enabled list only decides what
`./uis deploy` deploys **when you run it with no arguments** — it is a default
argument list, not a startup mechanism.

What actually happens after a host restart:

- **Deployed services come back on their own.** Deployments, Services,
  IngressRoutes, Secrets and database roles are cluster state; once the cluster
  is running again the kubelet restarts the pods. **Nothing needs redeploying,
  and re-running `./uis deploy` is not the fix.**
- **The cluster itself is not started by UIS.** Rancher Desktop is installed at
  OS level, so whether it comes up with the machine is a host setting outside
  UIS's control.

So if services are unreachable after a reboot, check whether the **cluster** is
running before redeploying anything.
:::

| Command | Description |
|---------|-------------|
| `./uis enable <service-id>` | Add service to autostart (deploys on next `./uis deploy`) |
| `./uis disable <service-id>` | Remove from autostart (does not undeploy) |
| `./uis list-enabled` | Show all services in autostart configuration |
| `./uis sync` | Auto-enable all currently deployed services |

### Verification

| Command | Description |
|---------|-------------|
| `./uis verify <service-id>` | Run service-specific verification checks |

## Stack Management

Stacks are pre-configured groups of related services deployed together.

| Command | Description |
|---------|-------------|
| `./uis stacks` | List all available stacks |
| `./uis stack info <stack-id>` | Show stack details (components, dependencies) |
| `./uis stack install <stack-id>` | Install all services in a stack in order |
| `./uis stack install <stack-id> --skip-optional` | Skip optional services |
| `./uis stack remove <stack-id>` | Remove all services in a stack |

Available stacks: `observability`, `ai-local`, `analytics`

## Template Management

A **template** installs an application that spans several services — a database
with migrations, per-app instances, exposures — under one name and one
`app_name`. It is the `uis` half of
[Rules for Deploying Applications](../contributors/rules/application-deployment.md):
templates provision, ArgoCD deploys workloads.

| Command | Description |
|---------|-------------|
| `./uis template list` | List available UIS templates from the registry |
| `./uis template info <id>` | Show one template's details |
| `./uis template install <id> [--param k=v]...` | Deploy and configure every service the template declares |

### The declaration

A template ships a `template-info.yaml`:

```yaml
install_type: stack
params:
  app_name: myapp            # substituted anywhere as {{ params.app_name }}

provides:
  services:
    - service: postgresql
      config:
        database: "{{ params.app_name }}"
        init: migrations/                    # a file OR a directory
        namespace: dagster                   # where to write the secret
        secret_name_prefix: "{{ params.app_name }}-database"
    - service: postgrest
      config:
        schemas: api_v1
        url_prefix: api-myapp
  stacks:
    - observability                          # expanded to its services, deploy-only
```

### `config:` keys

Every key maps to a `uis configure` flag. **An unrecognised key is rejected**, so
a typo such as `url-prefix` fails the install rather than being silently ignored.

| Key | Passed as | Notes |
|---|---|---|
| `database` | `--database` | |
| `init` | `--init-file -` | a file, or a directory — see below |
| `schemas` | `--schemas` | PostgREST |
| `url_prefix` | `--url-prefix` | PostgREST |
| `namespace` | `--namespace` | ⚠️ **requires `secret_name_prefix`** |
| `secret_name_prefix` | `--secret-name-prefix` | ⚠️ **requires `namespace`** |

⚠️ The resulting Secret is named **`<secret_name_prefix>-db`** and its key is
always **`DATABASE_URL`** — see
[Dagster's tenant contract](../services/analytics/dagster.md) for why that
matters when another service consumes it.

### `init:` — a file or an ordered directory

- **a file** — applied as-is
- **a directory** — every `*.sql` in it, concatenated in `LC_ALL=C sort` order

Order is part of the contract: migrations are numbered (`001_…`, `050_…`)
because DDL is order-dependent. The count and the ordered file list are printed
before anything is applied, so a partial apply is recoverable from the log.
Non-`.sql` files are ignored, and an **empty directory fails** rather than
installing nothing.

`{{ params.* }}` is substituted into the concatenated content, so a parameter may
appear in any file.

⚠️ **Zero-pad your numbers.** Sorting is lexicographic, so `9_`, `10_`, `100_`
apply in *reverse* — and out-of-order DDL can succeed while leaving the wrong
schema, which is the one failure this ordering contract exists to prevent. UIS
warns when numeric and lexicographic order disagree and shows what numeric order
would have been, but it applies the lexicographic order regardless: it cannot
know which you meant. `001_`, `002_`, … `010_` is immune.

### Testing a template before publishing it

`REGISTRY_URL_PRIMARY`, `REGISTRY_URL_FALLBACK` and `TEMPLATE_REPO` honour an
environment override, so a template can be exercised before it reaches the
registry:

```bash
TEMPLATE_REPO=/path/to/local/dev-templates ./uis template install my-fixture
```

### Multi-instance services

`./uis deploy` receives `--app <app_name>` automatically for any service whose
`multiInstance` is true in `services.json` (today: `postgrest`). `configure`
always receives `--app`, because a single-instance service can still hold
per-app resources — `configure postgresql --app` creates a per-app database in
the shared instance.

:::warning A template does not yet cover every surface
A **Dagster code location** cannot be declared in `provides:` — it is a
contribution to another service's `.uis.extend` file, not a service instance. It
remains a manual edit of `.uis.extend/dagster-code-locations.yaml` followed by
`./uis deploy dagster`.

So installing an application that orchestrates with Dagster is **two steps**, not
one. Tracked as TPL-F5 in
[INVESTIGATE-templates-multi-surface-application](../ai-developer/plans/backlog/INVESTIGATE-templates-multi-surface-application.md).
:::

---

## Secrets Management

| Command | Description |
|---------|-------------|
| `./uis secrets init` | Create `.uis.secrets/` directory with templates |
| `./uis secrets status` | Show which secrets are configured vs missing |
| `./uis secrets edit` | Open secrets config in editor |
| `./uis secrets generate` | Generate Kubernetes secrets from templates |
| `./uis secrets apply` | Apply generated secrets to the cluster |
| `./uis secrets validate` | Validate secrets config and check required values |

## Testing

| Command | Description |
|---------|-------------|
| `./uis test-all` | Deploy and undeploy all services (full integration test) |
| `./uis test-all --dry-run` | Show test plan without executing |
| `./uis test-all --clean` | Undeploy everything first, then run tests |
| `./uis test-all --only <svc> [svc...]` | Test only specified services and their dependencies |

## Service-Specific Commands

### Tailscale and Cloudflare

Tailscale and Cloudflare are managed through the unified [`uis network`](#network-management) family. The legacy `uis tailscale <verb>` and `uis cloudflare <verb>` invocations print a redirect stub and exit non-zero.

### ArgoCD

| Command | Description |
|---------|-------------|
| `./uis argocd register <name> <repo-url>` | Register a GitHub repo as ArgoCD application. Name is used as namespace, repo-url must be full HTTPS URL |
| `./uis argocd remove <name>` | Remove an ArgoCD application and its namespace |
| `./uis argocd list` | List registered ArgoCD applications with health and sync status |
| `./uis argocd verify` | Run ArgoCD health checks |

## Host Configuration

Manage configurations for different deployment targets.

| Command | Description |
|---------|-------------|
| `./uis host add` | List available host templates |
| `./uis host add <template-id>` | Add a host configuration from template |
| `./uis host list` | List configured hosts with status |

## Other Commands

| Command | Description |
|---------|-------------|
| `./uis init` | First-time setup wizard (cluster type, domain, project name) |
| `./uis setup` | Interactive TUI menu for browsing and deploying services |
| `./uis tools list` | List optional tools with installation status. See [Tools](./tools.md). |
| `./uis tools install <tool-id>` | Install an optional tool (aws-cli, azure-cli, etc.). See [Tools](./tools.md). |
| `./uis docs generate [dir]` | Generate JSON data files for website documentation |
| `./uis version` | Show UIS version |
| `./uis help` | Show help |

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `UIS_IMAGE` | Override container image | `ghcr.io/helpers-no/uis-provision-host:latest` |
| `UIS_KUBECONFIG_DIR` | Override kubeconfig directory | `$HOME/.kube` |
