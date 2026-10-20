---
title: Forgejo — git host and built-in registry
sidebar_label: Forgejo
sidebar_position: 5
---

# Forgejo — git host and built-in registry

A self-hosted git host, with its own built-in OCI registry for what gets built on this
platform. Added for the Epinio self-service deploy path
([INVESTIGATE-service-epinio-deploy-path.md](/docs/ai-developer/plans/backlog/INVESTIGATE-service-epinio-deploy-path)):
Epinio builds a workload from a developer's pushed source, and needs somewhere to push the
built image to and pull it back from.

## It lives outside the cluster, same as the registry cache

Same reasoning as [the registry cache](./registry-cache): a thing other services bootstrap
from cannot live inside the cluster it serves. Forgejo is a Proxmox guest — a `core-services`
entry alongside the registry cache, Bao and Garage — not a `uis deploy <service>` Kubernetes
workload.

## Separate role from the registry cache, on purpose

The registry cache (Zot) **proxies and caches external upstreams** — Docker Hub,
`registry.k8s.io`, and so on. Forgejo's built-in registry is the opposite: it is the
**origin** for images this platform itself builds, not a mirror of someone else's. Routing
Forgejo's images through the pull-through cache would be actively wrong, not merely
redundant — see
[INVESTIGATE-system-registry-cache.md, Part 4](/docs/ai-developer/plans/backlog/INVESTIGATE-system-registry-cache#part-4--forgejoepinio-needs-a-different-shape-not-another-upstream-2026-10-19)
for why.

## Shape

- Git over HTTP and git-ssh (published on a non-default host port — see the role's own
  `forgejo_ssh_port`, since this guest's own management sshd already owns 22).
- The OCI registry rides the same HTTP port as the web UI and git-http, per Forgejo's own
  `[packages]` config — there is no separate registry port to publish.
- SQLite backing store — a single-node install. Revisit if this guest ever needs to scale
  beyond one node.
- No admin account or repository is created by the role itself. First-run setup (an admin
  user, the first organisation/repo) is a deliberate, explicit operator step — the same
  "no baked-in default credential" rule the registry cache and object store already follow.

## Firewall

Allow-listed by resolved hostname or address range, input and forward both gated (Docker's
own DNAT rule needs both hooks covered — the same lesson the registry cache's own role
learned). Management SSH and outbound traffic are left alone.

## Known limitation, as shipped

Containerd trust for pulling from this registry (plain HTTP, no TLS) is **not** solved by
this guest existing — see
[INVESTIGATE-system-registry-cache.md, Parts 4 and 5](/docs/ai-developer/plans/backlog/INVESTIGATE-system-registry-cache#part-4--forgejoepinio-needs-a-different-shape-not-another-upstream-2026-10-19)
for the design and the cross-repo clobber risk that still needs resolving before any cluster
can actually pull from it.
