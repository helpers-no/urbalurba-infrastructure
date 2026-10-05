---
title: Platforms
sidebar_label: Overview
sidebar_position: 1
---

# Platforms

UIS targets **multiple Kubernetes platforms** from a single command interface. Rancher Desktop is the always-present local one (k3s on your laptop). Cloud and remote platforms — Azure AKS today, Google GKE / AWS EKS in the future — are provisioned on demand. All of them speak the same `uis platform ...` vocabulary, so switching between local development and production AKS is one command.

## See what you have

`uis platform list` shows every platform UIS knows about and its current state. The `(active)` annotation marks which one `uis deploy <service>` will target next:

```
$ uis platform list
Active: rancher-desktop

PLATFORM          STATUS
rancher-desktop   ✓ running  (active)    local k3s
azure-aks         · configured, not running  (run './uis platform up azure-aks' to start it)
```

The status column uses four state values:

| State | Meaning | Typical hint |
|---|---|---|
| `✓ running` | Cluster is live and reachable from inside the provision-host container | platform-specific (e.g. `local k3s`, `k8s cluster reachable`) |
| `· configured, not running` | Setup completed (env file or platform config exists), no live cluster | `run './uis platform up <name>' to start it` |
| `· not initialized` | UIS doesn't have configuration for this platform yet | `run './uis platform init <name>' to set up` (rancher-desktop says "install Rancher Desktop and start it" — no init wizard needed for the local-only case) |
| `✗ unreachable` | Setup exists but the API server didn't respond within 3 seconds | `run './uis platform status <name>' for details` |

The probe runs in parallel across platforms so the table renders in under 500 ms even with several cloud targets. Add `--offline` to skip the reachability probe entirely (faster, useful when offline).

## Switch between them

```
$ uis platform use rancher-desktop
✓ Switched: azure-aks → rancher-desktop
```

`uis platform use <name>` switches the active platform. It does **not** move running workloads — it changes which cluster the next `uis deploy`, `uis status`, `uis configure`, `uis expose`, `uis stack install`, and `uis test all` will target. Same syntax for every platform UIS supports.

Run with no argument to get an interactive picker over reachable platforms:

```
$ uis platform use
     PLATFORM          STATUS
[1] rancher-desktop   ✓ running  (currently active)    local k3s
    azure-aks         · configured, not running  (run './uis platform up azure-aks' to start it)

Pick a platform [1-1]:
```

Only platforms in `running` state get selectable numbers — switching to a `not initialized` or `unreachable` platform doesn't have a meaningful outcome, so the picker filters them out.

## Per-platform guides

| Platform | Use case | Setup | Status |
|---|---|---|---|
| [Rancher Desktop](./rancher-kubernetes.md) | Local development on your laptop (single-node k3s) | Install [Rancher Desktop](https://rancherdesktop.io/) → enable Kubernetes → `./uis start`. No `init` step. | ✅ Default |
| [Azure AKS](./azure-aks.md) | Production cloud cluster | `./uis tools install azure-aks` → `./uis platform init azure-aks` → `./uis platform up azure-aks` | ✅ Verified end-to-end |
| [Azure VM (MicroK8s)](./azure-microk8s.md) | Azure VM with MicroK8s instead of managed AKS | Pre-UIS-CLI scripts under `hosts-to-be-deleted/azure-microk8s/` | ⚠ Not yet migrated to `uis platform` |
| [Multipass MicroK8s](./multipass-microk8s.md) | Local virtualised cluster. **Superseded by Rancher Desktop.** | Pre-UIS-CLI scripts under `hosts-to-be-deleted/multipass-microk8s/` | ⚠ Kept for historical reference |
| [Raspberry Pi MicroK8s](./raspberry-microk8s.md) | Edge / ARM-based deployments | Pre-UIS-CLI scripts under `hosts-to-be-deleted/raspberry-microk8s/`, manual provisioning, Tailscale for remote access | ⚠ Not yet migrated |

The "not yet migrated" platforms work — they use the older `hosts-to-be-deleted/` script flow — but they don't speak the `uis platform list / use / init / up / status / down` vocabulary yet. Migration is tracked at [INVESTIGATE-system-migrate-hosts-to-platforms.md](../ai-developer/plans/backlog/INVESTIGATE-system-migrate-hosts-to-platforms.md).

## How it works — cluster targeting

UIS treats two pieces of state as the source of truth for "which platform is active":

1. **`kubectl current-context`** in the merged kubeconfig at `/mnt/urbalurbadisk/kubeconfig/kubeconf-all` (in-container, not bind-mounted — kubectl writes from inside the container are flock-safe).
2. **`CLUSTER_TYPE` + `TARGET_HOST`** in `.uis.extend/cluster-config.sh`, which `service-deployment.sh` reads to set the `target_host` extra-var on Ansible playbook invocations.

Both must agree. A single function — `pf_lockstep_flip` in `provision-host/uis/lib/platform-switching.sh` — writes all three (in-container kubeconf-all, the legacy bind-mount kubeconfig, and `cluster-config.sh`) atomically. The same function is called from three places:

- `02-post-apply.sh` (after `uis platform up`) — flips active to the just-provisioned platform.
- `03-destroy.sh` (after `uis platform down`) — resets active back to `rancher-desktop`.
- `cmd_platform_use` (when you run `uis platform use <name>` manually) — flips active to the chosen platform.

Single writer means the kubectl context and `cluster-config.sh` can never silently diverge. If you ever see a state where they disagree, that's a bug — file an issue. (For background, see [INVESTIGATE-active-cluster-visibility-ux](../ai-developer/plans/completed/INVESTIGATE-active-cluster-visibility-ux.md) for the design decisions and tradeoffs.)

The merged kubeconfig is **seeded on first invocation**: if `kubeconf-all` is missing but the host kubeconfig at `/home/ansible/.kube/config` has a `rancher-desktop` context, UIS extracts that context and writes it to `kubeconf-all` so `uis platform list` works before any cloud cluster has been provisioned. This lets `uis platform list` answer "what do I have?" even on a brand-new container.

## Banner on every cluster-touching command

Every command that targets a cluster prints a one-line banner to stderr identifying the active platform:

```
$ uis deploy nginx
ℹ  Platform: azure-aks (reachable)
(deploy output follows on stdout…)
```

Banner cases:

- `ℹ  Platform: <name> (reachable)` — single-line success, deploy proceeds.
- `⚠  Platform: <name> (not a UIS platform — proceeding with kubectl context anyway)` — you're targeting a kubectl context UIS didn't provision (e.g. a custom personal cluster). Single line, deploy proceeds.
- `✗  Platform: <name>, but the API server is unreachable.` — multi-line abort with recovery hint. The deploy doesn't run.
- `⚠  No active kubectl context set.` — multi-line abort. Run `uis platform use rancher-desktop` or `uis platform list` to recover.

This catches the silent-wrong-cluster footgun: if you've forgotten that `uis platform up azure-aks` flipped your active context, the banner reminds you before `uis deploy nginx` lands in production AKS. The banner appears on `deploy`, `undeploy`, `list`, `status`, `configure`, `expose`, `stack install`, and `test all`. It is **not** printed on `platform list` / `platform use` themselves — those are the discovery and recovery commands, banner-then-abort would be catch-22.

## After a destroy

After `uis platform down azure-aks` completes, the platform's row in `uis platform list` reads:

```
azure-aks   · configured, not running  (run './uis platform up azure-aks' to start it)
```

UIS removes the kubectl context for the destroyed cluster from the merged kubeconfig as part of teardown, so the row doesn't show `✗ unreachable` against a dead API server. The platform's `.uis.secrets/cloud-accounts/<provider>-default.env` configuration file is preserved by design — you can `uis platform up <name>` again later without re-running the init wizard.

## See also

- **[Provision Host Overview](../advanced/provision-host/index.md)** — the management container that's identical across all platforms.
- **[Tools](../reference/tools.md)** — built-in vs installable CLIs (`azure-cli`, `opentofu`, etc.).
- **[How Deployment Works](../advanced/how-deployment-works.md)** — what `./uis deploy <service>` does under the hood.
- **[CLI Reference](../reference/uis-cli-reference.md)** — full command reference including all `uis platform` subcommands.
