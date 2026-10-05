# Investigate: migrate `hosts-to-be-deleted/*` to `platforms/*` (or formally retire)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog (Tier 3 — design question, not urgent)

**Last Updated**: 2026-10-05

**2026-10-05 update (Terje, prompted by ops's Proxmox work raising the same `hosts/` vs
`platforms/` confusion fresh):**

- Renamed the top-level `hosts/` → `hosts-to-be-deleted/` repo-wide — a visible, low-risk
  signal that the whole area is leaving, without forcing the two still-open per-platform
  decisions below. Confirmed first that nothing in the live `./uis` CLI or any actively-run
  ansible playbook depends on this directory's name or location — the only live reference was
  the Dockerfile's `COPY`, updated to the new source path (destination inside the container is
  deliberately unchanged, so any still-working legacy manual flow doesn't break mid-decision).
- **Confirmed safe to delete now, independently re-verified rather than taken on faith:**
  `azure-aks/` (fully superseded, matches this doc's existing finding), `multipass-microk8s/`
  (doc already says "replaced by Rancher Desktop," unmaintained 1+ year), and
  `rancher-kubernetes/` (audited both scripts directly — nothing live references them;
  `./uis start` for Rancher Desktop runs entirely through `platforms/rancher-desktop/` today).
  Plus their `install-*.sh` wrappers. **Still not deleted** — renamed and staged, actual
  deletion deferred per Terje's call, tracked as its own follow-up.
- **`azure-microk8s/` and `raspberry-microk8s/` remain genuinely open** — "does anyone still
  want this" is a usage question this repo can't answer from the code, not a technical one.
- **`asgard/`, `assist/`, `mac-ollama/` are a different kind of problem, deliberately not
  touched here beyond the rename**: real per-installation config, not legacy platform code —
  see [PLAN-system-public-repo-internal-detail.md](PLAN-system-public-repo-internal-detail.md).

**Original source**: surfaced during the platform-docs refresh (PR #150 + content PR-B). PR #149 shipped `platforms/azure-aks/` as the modern UIS-CLI-driven AKS path. The legacy `hosts-to-be-deleted/aks/`, `hosts-to-be-deleted/azure-microk8s/`, `hosts-to-be-deleted/multipass-microk8s/`, `hosts-to-be-deleted/raspberry-microk8s/`, and `hosts-to-be-deleted/rancher-kubernetes/` directories are still in tree, with their own deprecated scripts and "not migrated to UIS CLI" caution banners on the docs site.

---

## Problem Summary

UIS today has **two parallel platform shapes** that don't share infrastructure:

| Shape | Code | Driven by | Verified |
|---|---|---|---|
| **New (`platforms/*`)** | `platforms/azure-aks/scripts/{00-bootstrap,01-apply,02-post-apply,03-destroy}.sh`, `platforms/azure-aks/tofu/`, etc. | `./uis` CLI flow + sourced helpers + ansible playbooks for cross-cluster bits | ✅ AKS Tier A retry №4 (PR #149) |
| **Legacy (`hosts-to-be-deleted/*`)** | `hosts-to-be-deleted/azure-aks/`, `hosts-to-be-deleted/azure-microk8s/`, `hosts-to-be-deleted/multipass-microk8s/`, `hosts-to-be-deleted/raspberry-microk8s/`, `hosts-to-be-deleted/rancher-kubernetes/` + `hosts-to-be-deleted/install-*.sh` driver scripts | Bash scripts invoked manually inside the provision-host container | ❓ Last verified pre-UIS-CLI; current status unknown for each |

The new shape ships per-platform scripts that integrate with `./uis deploy <service>`, the merged kubeconfig, and `cluster-config.sh`. The legacy shape predates all of that — it stands up a cluster but doesn't wire it into UIS's deploy flow consistently.

**The question isn't "should we migrate"** (the duplication is obvious tech debt). **The question is "which legacy platforms still warrant first-class support, and what does the migration look like?"** Answers determine whether each legacy `hosts-to-be-deleted/<x>/` directory becomes `platforms/<x>/` or gets formally retired.

---

## What's currently in `hosts-to-be-deleted/`

```
hosts-to-be-deleted/
├── azure-aks/              # superseded by platforms/azure-aks/ (PR #146 + #149); pure dead code
├── azure-microk8s/         # MicroK8s on an Azure VM (instead of managed AKS); CAF-compliant tooling
├── multipass-microk8s/     # MicroK8s in Multipass on macOS/Linux; explicitly "replaced by Rancher Desktop"
├── raspberry-microk8s/     # MicroK8s on Raspberry Pi 4 + Tailscale; for edge / IoT
├── rancher-kubernetes/     # legacy scripts for the Rancher Desktop path; unclear whether actively used
├── install-azure-aks.sh    # legacy AKS installer; superseded by platforms/azure-aks/
├── install-azure-microk8s-v2.sh
├── install-multipass-microk8s.sh
├── install-rancher-kubernetes.sh
└── 03-setup-microk8s-v2.sh # shared MicroK8s setup invoked by multiple flavours
```

`hosts-to-be-deleted/azure-aks/` is the clearest case: it's been completely superseded by `platforms/azure-aks/`. The other five each have a different story.

---

## Per-platform questions

### `hosts-to-be-deleted/azure-aks/` — superseded; safe to delete

- ✅ Replaced by `platforms/azure-aks/` (PR #146).
- ✅ Tier A retry №4 verified the new path end-to-end.
- ❓ Does any tool / script / CI workflow still reference `hosts-to-be-deleted/azure-aks/`?
- 📝 If grep returns clean, **delete the directory and the `install-azure-aks.sh` driver** as a follow-up code-cleanup PR. Pure dead code.

### `hosts-to-be-deleted/azure-microk8s/` — does anyone still want it?

Use case: an Azure VM running MicroK8s, instead of managed AKS. Trade-offs vs. AKS: cheaper at idle (no AKS control-plane overhead), more manual operations (no cluster autoscaler, no Azure-managed upgrades), CAF-compliant networking via Tailscale.

- ❓ Are there any active users (helpers.no or otherwise) running production workloads on this path?
- ❓ Does AKS sufficiently cover the use case now that we have `platforms/azure-aks/` working? AKS is roughly ~€1/day for a 1-node test cluster — comparable to a B2s_v2 VM running MicroK8s, but with AKS's autoscaler + managed control plane.
- 📝 If no active user, deprecate and retire. If yes, scope `platforms/azure-microk8s/` migration: reuse `platforms/azure-aks/`'s shape (00-bootstrap-state.sh equivalent for the Azure VM, 01-apply.sh for OpenTofu-driven VM provisioning + cloud-init, 02-post-apply.sh for the kubeconfig-merge and Traefik install — Traefik playbook already platform-agnostic per PR #149).

### `hosts-to-be-deleted/multipass-microk8s/` — formally retire

- ✅ Already documented as "replaced by Rancher Desktop" in the existing `multipass-microk8s.md` page.
- 📝 No migration. Delete the directory + the `install-multipass-microk8s.sh` driver in the same code-cleanup PR as `hosts-to-be-deleted/azure-aks/`. Update the docs page to add a "this content is preserved for historical reference" header.

### `hosts-to-be-deleted/raspberry-microk8s/` — design question

Use case: edge / IoT / development on ARM hardware. Currently requires Tailscale for remote access and manual provisioning of the Pi.

- ❓ Is anyone running this in 2026?
- ❓ Is RPi as a UIS target still aligned with the project's direction (cloud-first per the AKS work) or a niche the project doesn't want to maintain?
- ❓ If we keep it, what does `platforms/raspberry-microk8s/` look like? RPi is fundamentally manual — the Pi has to be physically prepared with an SD card, networked, etc. The `platforms/*` shape assumes scripts can drive everything; an RPi `platforms/` entry would be more "here's the runbook" than "here's the OpenTofu module".
- 📝 If kept, migrate as a "manual platform" with a `platforms/raspberry-microk8s/README.md` runbook + lightweight scripts. If retired, delete and add a note about ARM workloads going to AKS's ARM-capable node pools or another cloud.

### `hosts-to-be-deleted/rancher-kubernetes/` — already implicit

- ❓ The `platforms/rancher-kubernetes.md` doc says install Rancher Desktop and run `./uis start` — no script needed. The `hosts-to-be-deleted/rancher-kubernetes/` directory has scripts; what do they do that the docs don't describe?
- 📝 Audit the scripts. Likely they're old setup wrappers that Rancher Desktop made obsolete. If so, delete the directory + `install-rancher-kubernetes.sh` driver. Rancher Desktop is its own installer.

---

## What `platforms/*` shape implies for each migrated platform

Once `platforms/<provider>/` is the answer, each new entry needs:

1. **`platforms/<provider>/scripts/`** with the 4 standard files (or fewer if the platform doesn't need state-backend bootstrap):
   - `00-bootstrap-state.sh` (if there's a remote IaC state to set up)
   - `01-apply.sh` (provision the cluster)
   - `02-post-apply.sh` (kubeconfig merge + cluster-config flip + storage class aliases + Traefik via the shared playbook)
   - `03-destroy.sh` (tear down + cleanup)
2. **`platforms/<provider>/<iac>/`** — OpenTofu module, Pulumi program, CloudFormation, whatever.
3. **`platforms/<provider>/manifests/`** — any platform-specific cluster resources (storage class aliases, etc.).
4. **A user-facing doc page** at `website/docs/platforms/<provider>.md`.
5. **Optional**: an env template at `provision-host/uis/templates/uis.secrets/cloud-accounts/<provider>.env.template` for any cloud creds.

The shared playbook `ansible/playbooks/003-setup-traefik.yml` (PR #149) already handles cross-platform Traefik install. Future cross-platform bits (cluster-config flip, kubeconfig merge, storage class aliases) follow the same pattern: shared mechanism, per-platform invocation.

---

## What this investigation needs to produce

A child PLAN per platform that's worth migrating, plus one cleanup PR for the dead-on-arrival ones. Pre-conditions for each:

1. **Decision**: keep & migrate / retire & delete / hibernate (keep code, don't promise support)?
2. **For "keep & migrate"**: scope the migration PR — which scripts, what state, what verification gate.
3. **For "retire & delete"**: scope a single code-cleanup PR that removes all `hosts-to-be-deleted/<x>/` directories at once and updates the platform doc to note "preserved for historical reference, not supported".

---

## Documentation migration (folded in from INVESTIGATE-docs-host-migration, 2026-05-15)

The legacy host documentation pages still describe the manual-script approach (`provision-kubernetes.sh`, `install-*.sh`, cloud-init templates) and have not been updated for the `./uis` CLI workflow. They carry caution banners today but the underlying content needs to follow whatever migration decision is made above.

### Pages affected

| Page | Path | Notes |
|------|------|-------|
⚠️ **Corrected 2026-10-05**: these doc pages are not under `website/docs/hosts-to-be-deleted/`
(a mechanical rename-script error briefly put them there) — they already moved to
`website/docs/platforms/` as part of PR #150, well before today's `hosts/` →
`hosts-to-be-deleted/` script-directory rename. The two renames are unrelated; don't conflate
the doc path with the script path below.

| Azure AKS | `website/docs/platforms/azure-aks.md` | Full AKS deployment guide with az CLI — superseded by `platforms/azure-aks/` shipping. |
| Azure MicroK8s | `website/docs/platforms/azure-microk8s.md` | Azure VM + MicroK8s via CAF — depends on the "keep & migrate" vs "retire" decision above. |
| Multipass MicroK8s | `website/docs/platforms/multipass-microk8s.md` | Legacy, already marked "USE RANCHER DESKTOP INSTEAD" — formally retire alongside the code. |
| Raspberry Pi | `website/docs/platforms/raspberry-microk8s.md` | Edge/IoT — depends on the design decision below. |
| Cloud-Init | `website/docs/platforms/cloud-init/index.md` | Cloud-init templates — retain only if VM-based platforms are kept. |
| Cloud-Init Secrets | `website/docs/platforms/cloud-init/secrets.md` | SSH key setup for cloud-init — same gate. |

### Doc-side questions

1. **Per-host pages or single page?** Each host type keeps its own page, or consolidate into one "deploying to remote VMs" page once the platform-side picture is settled?
2. **What about cloud-init?** Still the approach for provisioning remote hosts, or has that changed with `platforms/*`?
3. **Tied to [INVESTIGATE-system-remote-deployment-targets](INVESTIGATE-system-remote-deployment-targets.md)** — the docs should reflect what `./uis` actually targets. Until that investigation lands, the docs migration is blocked on knowing the supported set.

### Doc migration sequencing

The doc rewrite for each page lands as part of that page's parent decision in "Per-platform questions" above:

- `website/docs/platforms/azure-aks.md` — delete; the canonical AKS guide is `platforms/azure-aks.md`. ✓ already done (the legacy host page survives only as a redirect/caution banner).
- `website/docs/platforms/azure-microk8s.md` — depends on keep-or-retire decision.
- `website/docs/platforms/multipass-microk8s.md` — retire alongside the code.
- `website/docs/platforms/raspberry-microk8s.md` — depends on design decision.
- `website/docs/platforms/cloud-init/*` — retain only if at least one platform still uses cloud-init provisioning.

---

## Out of scope for this investigation

- **Adding new platforms** that don't currently exist (GCP/EKS/etc.) — that's a separate "second cloud" investigation. The shared playbook in `ansible/playbooks/003-setup-traefik.yml` plus the `platforms/azure-aks/` shape gives that work a clean starting point, but it's not the same scope as legacy migration.
- **Removing `hosts-to-be-deleted/` entirely.** Until the per-platform decisions are made, `hosts-to-be-deleted/` stays.

---

## Related

- [INVESTIGATE-system-platform-provisioning-layer](INVESTIGATE-system-platform-provisioning-layer.md) — the architectural umbrella above this execution work (what `platforms/*` should look like as a category).
- [PLAN-platform-aks-destroy-kubeconfig-cleanup.md](../completed/PLAN-platform-aks-destroy-kubeconfig-cleanup.md) — destroy-side kubeconfig cleanup; the `03-destroy.sh` shape that future platforms inherit.
- [INVESTIGATE-active-cluster-visibility-ux.md](../completed/INVESTIGATE-active-cluster-visibility-ux.md) — once we have multiple platforms, "which cluster am I about to deploy to?" becomes more pressing. Visibility UX is a prerequisite for confidently using multiple `platforms/*` flows.
- [INVESTIGATE-system-remote-deployment-targets](INVESTIGATE-system-remote-deployment-targets.md) — remote-cluster targeting; the docs migration above can't finish until the supported target set is decided.
- PR #149 — landed `platforms/azure-aks/`, the template every other migrated platform should follow.
- PR #150 — promoted "Hosts & Platforms" to top-level "Platforms" sidebar.
