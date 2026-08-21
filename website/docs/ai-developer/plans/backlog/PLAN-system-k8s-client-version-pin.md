# Fix: the provision-host ships a Kubernetes client 12 major versions too old

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: The Ansible layer talks to the cluster with a client the collection
actually supports, and that version is pinned rather than inherited.

**Created**: 2026-08-21 — surfaced by a warning during the Rancher Desktop
validation run, see
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).

**Priority**: Medium — nothing is broken today; the failure mode is obscure
rather than loud, which is why it is worth fixing before it bites.

---

## Problem

Every `kubernetes.core` task emits:

```
[WARNING]: kubernetes<24.2.0 is not supported or tested. Some features may not work.
```

Measured inside the running `uis-provision-host` container, 2026-08-21:

| | Version | |
|---|---|---|
| `kubernetes` (Python client) | **12.0.1** | collection requires **≥ 24.2.0** |
| `kubernetes.core` (collection) | 6.5.0 | |
| Target API server | **v1.36** | |

Python client 12.0.1 dates from 2020 and targets Kubernetes ~1.16. It is being
used against a **v1.36** API server — roughly twenty minor versions apart.

**It is not pinned anywhere.** Neither `Dockerfile.uis-provision-host` nor any
requirements file names `kubernetes`, so the version is whatever the base image
happens to carry. That means it can also change without anyone choosing to change
it — the same class of problem as the unpinned LiteLLM chart in
[PLAN-service-litellm-002-version-pinning](./PLAN-service-litellm-002-version-pinning.md).

### Why this matters even though everything passes

Eleven services deployed and tore down cleanly on 21 August with this client. The
risk is not that `k8s`/`k8s_info` stop working — it is that they mishandle newer
API shapes **quietly**: fields the old client does not know are dropped from
round-trips, and newer resource versions may deserialize incompletely.

That is the same shape as the two defects this platform has already paid for —
`kubectl run --rm -i` returning success with no output, and `envsubst` rendering
an unset key as an empty string. Silent wrong beats loud broken, every time, and
costs a day each.

---

## Phase 1: Pin and upgrade

### Tasks

- [ ] 1.1 Add an explicit `kubernetes>=24.2.0` pin (choose a specific version,
      not a floor) to the provision-host image build
- [ ] 1.2 Decide whether `kubernetes.core` 6.5.0 is also due an upgrade, and pin
      it in the same place — a collection and its client should move together
- [ ] 1.3 Rebuild the image and confirm the warning is gone

### Validation

```bash
docker exec uis-provision-host python3 -c "import kubernetes; print(kubernetes.__version__)"
./uis deploy whoami        # no kubernetes<24.2.0 warning in the output
```

---

## Phase 2: Prove nothing regressed

An old client that silently drops fields will also *appear* to work; so will a new
one. The only real check is a broad deploy/undeploy sweep before and after.

### Tasks

- [ ] 2.1 Run `./uis test-all` (or the batches used on 21 August) against the
      **old** client and capture the results as a baseline
- [ ] 2.2 Repeat against the **new** client and diff
- [ ] 2.3 Pay particular attention to services using `kubernetes.core.k8s` with
      complex objects — IngressRoutes, StatefulSets, PVCs
- [ ] 2.4 Check whether any playbook has a workaround that exists *because* of
      the old client, and remove it if so

### Validation

The same set of services deploys, verifies and undeploys on both clients, with no
new failures and no newly-empty fields in applied objects.

---

## Acceptance Criteria

- [ ] The Kubernetes Python client is pinned to an explicit, supported version
- [ ] `kubernetes.core` tasks emit no support warning
- [ ] The version is declared in the repo, not inherited from a base image
- [ ] A deploy/undeploy sweep passes identically before and after

---

## Implementation Notes

**Do not treat "the warning went away" as the acceptance criterion.** Upgrading
the client is the easy half; the reason to do it is the silent-mishandling risk,
and only the sweep in Phase 2 speaks to that.

**Sequencing**: this touches the provision-host image, so it lands cleanly
alongside other image-level work rather than on its own.

---

## Files to Modify

- `Dockerfile.uis-provision-host` — the pin
- possibly a `requirements.txt` for the provision-host, if one is introduced
