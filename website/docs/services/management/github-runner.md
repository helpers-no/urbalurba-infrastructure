---
title: GitHub Runner
sidebar_label: GitHub Runner
---

# GitHub Runner

In-cluster GitHub Actions self-hosted runner (CI for GitHub-hosted repos)

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy github-runner` |
| **Undeploy** | `./uis undeploy github-runner` |
| **Depends on** | None |
| **Required by** | None |

| **Default namespace** | `github-runner` |

## What It Does

Registers a GitHub Actions self-hosted runner, via GitHub's own **Actions Runner Controller
(ARC)**, against an operator-supplied repository. Runners scale to **zero** between jobs — an
ephemeral runner pod is created per queued job and torn down after, executing it via a private
docker:dind sidecar (the same architecture choice forgejo-runner already made). The SAME chart
install runs identically on Rancher Desktop and on a Proxmox k3s cluster.

## Deploy

```bash
# Deploy GitHub Runner
./uis deploy github-runner
```

## Verify

```bash
# Quick check
./uis verify github-runner

# Manual check — every registered instance + the repo it serves
./uis github-runner list

# Manual check — the listener(s) (the always-on part; ephemeral runner pods only exist
# while a job is actually in progress — "no runner pods" is the normal idle state)
kubectl get pods -n github-runner
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
A GitHub Personal Access Token must be configured first — the `GITHUB_ACCESS_TOKEN` secret
(`uis secrets edit`), the same one `uis argocd register` uses for private-repo access. It needs the
`Administration` repository permission (fine-grained) or classic `repo` scope.

🔴 **Unlike a short-lived token, this PAT now persists in the cluster** (as a Secret, scoped to
this instance alone) — GitHub's Actions Runner Controller needs to keep minting its own
short-lived runner registration tokens from it, with no human in the loop, for as long as the
instance exists. That's the cost of scale-to-zero working unattended, not an oversight — the
permission stays the same narrow `Administration` scope either way.

Register a runner instance against a target repository:

```bash
./uis github-runner register bifrost terchris/bifrost
```

This installs the shared ARC controller (once per cluster, idempotent on every later call) and
this instance's own runner scale set. Runners scale to **zero** when idle; an ephemeral pod is
created per queued job and torn down afterward — there is nothing to keep "warm."

### Running more than one instance on the same cluster

One cluster can run a separate, fully independent runner for each repo that needs one — pick a
new `<instance>` slug (lowercase alphanumeric and hyphens only) to register a second (or third,
...) instance alongside any already running, without touching it:

```bash
./uis github-runner register other-repo owner/other-repo
./uis github-runner list      # every instance + the repo it serves
./uis github-runner remove other-repo
```

Every instance shares the one `github-runner` namespace (and the one cluster-wide ARC controller);
`register` refuses to apply if that instance name is already serving a *different* repo (`--force`
to deliberately retarget it). `remove` only removes the named instance's own runner scale set —
never any other, and never the shared controller — and only deletes the namespace itself once no
instance is left in it.

⚠️ Sharing a namespace is not full isolation — every instance's `dind` sidecar is still
`privileged: true`, and two repos' runners sharing this namespace share the same RBAC/
NetworkPolicy boundary that namespace provides, nothing stronger.

### Preferring a node with more headroom

By default, the Kubernetes scheduler has no basis to prefer one node over another for a runner
pod. "Most powerful host" and "most free headroom right now" aren't always the same node — so this
is a **ranked preference**, not a single avoid-one-node rule.

Each k3s node is expected to carry a `urbalurba.no/hypervisor` label (`odin`, `tor`, or `frigg`),
set **declaratively at k3s provisioning time in the platform repo's own IaC** — never a hand-run
`kubectl label`, so a cluster rebuild reproduces it automatically instead of silently losing it.
That's a platform-repo concern, outside this repo.

From this repo's side, pass a ranked list reflecting real (not assumed) headroom, e.g.:

```bash
-e '{"github_runner_node_preference": [{"hypervisor": "frigg", "weight": 100}, {"hypervisor": "tor", "weight": 50}]}'
```

Every runner instance then **prefers** (not requires — a job still runs on the least-preferred
node rather than sitting `Pending` forever if that's all that's available) frigg first, tor
second, and implicitly odin last. Empty by default, so this has **zero effect** until an operator
sets it — register/re-run an existing instance (`./uis github-runner register <instance>
<owner/repo>`) to pick the preference up once it's configured.

### Migrating an instance registered before this service used ARC

An instance registered before this migration is a plain `Deployment`, not an ARC-managed runner
scale set. Re-running `register` for it installs the new, ARC-backed instance **alongside** the
old one — both keep serving the same repo (redundant, not broken) until the old one is removed by
hand once the new instance is confirmed listening:

```bash
kubectl delete deployment <resource-name> -n github-runner
kubectl delete secret <resource-name>-token -n github-runner
```

`register` warns loudly if it finds a pre-migration Deployment still present under the same name —
it never deletes it automatically.

## Undeploy

```bash
./uis undeploy github-runner
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->

### A job fails mid-build with "lost communication with the server"

This looks like a network problem but is very often a **cgroup OOM kill**: the runner container
hit its memory limit, the kernel killed it, and that looks exactly like a lost connection from
GitHub's side. Confirm with a kernel-log check at the failure timestamp — an `oom-kill` /
`Memory cgroup out of memory` entry is the tell.

This has already come up twice for two different repos, at two different ceilings
(`urb-agents#2032`: the template's own `768Mi` default was too small; `urb-agents#2090`: `2Gi` was
too small for a monorepo's `yarn install`, raised to `4Gi` for that instance). There is no single
default that fits every repo's build — a trivial repo needs far less than one with a large
dependency tree — so treat a build this size hitting the limit as **expected**, not a bug to chase
by raising the template default again. Raise `github_runner_memory_limit` for the specific
instance instead:

```bash
-e '{"github_runner_memory_limit": "4Gi"}'
```

Re-run `register` for an existing instance once you've raised it, the same way
`github_runner_node_preference` is picked up.

### The runner image is not `ubuntu-latest`

The runner image is the minimal official `actions-runner` image, run as a **non-root** user. Workflows
that assume GitHub-hosted `ubuntu-latest` can hit three differences (reported from a real
monorepo migration, `urb-agents#2092`):

**1. No native build tools.** An npm dependency that compiles a native module on install (e.g.
`better-sqlite3`) fails with `gyp ERR! stack Error: not found: make`. `ubuntu-latest` ships
`build-essential`; this image does not. Install it in the workflow before the dependency install —
`sudo` is required, plain `apt-get` fails with `Permission denied`:

```yaml
- run: sudo apt-get install -y --no-install-recommends build-essential python3
```

**2. napi-rs native loaders (e.g. `@swc/core`) reject the runner's cache directory.** The loader
fails with `ERR_SWC_NATIVE_CACHE — cache root has a parent writable by another user without trusted
sticky protection`. This is a deliberate symlink-race guard in the loader, not a missing library
(`ldd` on the `.node` binary resolves cleanly; a direct `require()` shows the real error, while
wrappers often log only a generic "Failed to load native binding"). Workaround: point the cache
outside `/home/runner/.cache`, e.g. `SWC_NATIVE_BINDING_CACHE=/tmp/swc-cache`. Whether the
underlying permission on the image itself should be fixed instead is an open question — any
napi-rs-based tool would hit the same guard.

**3. Turborepo drops custom env vars.** Under Turborepo's default strict `envMode`, only variables
listed in `turbo.json` (`globalEnv`/`env`/`passThroughEnv`) reach task processes — so a workflow-level
`env:` such as the cache variable above is silently ignored by `turbo run`. Add it to
`globalPassThroughEnv` (or per-task `passThroughEnv`) in `turbo.json`. Not a runner issue, but a trap
for any Turborepo project adopting this runner.

## Learn More

- [Official GitHub Runner documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
