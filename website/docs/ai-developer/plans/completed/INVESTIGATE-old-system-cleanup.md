# INVESTIGATE: Old Deployment System Cleanup & Documentation Gaps

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-03-17
**Status:** Completed (2026-03-17)
**Related to:** [INVESTIGATE: Old Deployment System & UIS Migration](../completed/INVESTIGATE-old-deployment-system.md)

## Problem Statement

The migration from the old deployment system (`provision-host/kubernetes/`) to the UIS CLI (`provision-host/uis/`) is functionally complete — all 30 services deploy through UIS. But the old system is still in the repo, creating confusion for anyone trying to understand how UIS works. Dead code undermines documentation — if someone sees 60 scripts in `provision-host/kubernetes/`, they can't tell which system is real.

Cleanup and documentation are the same task: remove the noise so the signal is clear.

---

## What Exists Today

### Dead Code: `provision-host/kubernetes/`

60 scripts (6,149 lines), 59 already in `not-in-use/` subfolders. The one remaining active script (`01-core/020-setup-nginx.sh`) is a 125-line wrapper that calls the same Ansible playbook as `./uis deploy nginx`. Plus `provision-kubernetes.sh` (the old orchestrator) and `./uis provision` legacy fallback command.

| Folder | Active | Inactive |
|--------|:-:|:-:|
| `01-core` | 1 | 1 |
| `02-databases` | 0 | 8 |
| `03-queues` | 0 | 4 |
| `04-search` | 0 | 2 |
| `05-apim` | 0 | 1 |
| `06-management` | 0 | 4 |
| `07-ai` | 0 | 6 |
| `08-development` | 0 | 2 |
| `09-network` | 0 | 6 |
| `10-datascience` | 0 | 6 |
| `11-monitoring` | 0 | 14 |
| `12-auth` | 0 | 2 |
| `99-test` | 0 | 2 |
| **Total** | **1** | **59** |

### Existing Documentation

The CLI and deployment system are documented across several files:

| Document | What it covers | Audience |
|----------|---------------|----------|
| `docs/reference/uis-cli-reference.md` | Full command reference | Users |
| `docs/getting-started/installation.md` | Install and first run | Users |
| `docs/getting-started/overview.md` | Quick start, first deploy | Users |
| `docs/getting-started/architecture.md` | System architecture diagram | Users |
| `docs/contributors/guides/adding-a-service.md` | 11-step guide to add a service | Contributors |
| `docs/contributors/rules/kubernetes-deployment.md` | Metadata, categories, deploy flow | Contributors |
| `docs/contributors/architecture/deploy-system.md` | Deploy system architecture | Contributors |
| `provision-host/uis/templates/uis.extend/README.md` | Configuration directory | Users |
| `provision-host/uis/templates/uis.secrets/README.md` | Secrets workflow | Users |

### Documentation Gaps

What's missing or incomplete:

1. **How deployment works under the hood** — no user-facing page explaining the flow from `./uis deploy` → service metadata → Ansible playbook → Kubernetes resources. The contributor docs cover this but users don't see it.

2. **Service override customization** — `uis.extend/service-overrides/` exists but has no guide on what can be overridden or examples.

3. **Stack creation** — stacks are documented in rules but no guide on defining custom stacks.

4. **Cloud host deployment** — out of scope, covered by [INVESTIGATE: Remote Deployment Targets](../backlog/INVESTIGATE-system-remote-deployment-targets.md).

5. **Old system references in docs** — some docs may still reference `provision-host/kubernetes/` paths or the old deployment model.

### Naming Inconsistency: "Services" vs "Packages"

The CLI and data model use **services** everywhere, but the documentation uses **packages**:

| Where | Term used |
|-------|-----------|
| CLI commands | `./uis deploy <service>`, `./uis list`, `./uis status` |
| Service definitions | `provision-host/uis/services/*/service-*.sh` |
| Generated data | `website/src/data/services.json` |
| Navbar link | "Services" → `/services` |
| Documentation folder | `website/docs/packages/` |
| Sidebar category | `/docs/category/packages` |
| Doc generator output | `uis-docs-markdown.sh` writes to `docs/packages/` |

A user clicks "Services" in the navbar, then finds "Packages" in the sidebar. This looks like two different things when it's the same thing.

**Decision:** Rename `packages` to `services` throughout the documentation. This affects:
- `website/docs/packages/` → `website/docs/services/`
- All internal links referencing `/docs/packages/...`
- Sidebar category labels and `_category_.json` files
- `uis-docs-markdown.sh` output path
- `services.json` `docs` field in every service entry (currently `/docs/packages/...`)
- Service script metadata (`SCRIPT_DOCS` field in every `service-*.sh`)

### References to Old System Outside `provision-host/kubernetes/`

The old deployment system is referenced in active code and documentation outside the folder itself. These must be updated before or during deletion:

**Host-side CLI wrappers (execute the old system):**
- `uis` (bash wrapper, line ~243) — `provision` command calls `provision-kubernetes.sh`
- `uis.ps1` (PowerShell wrapper, line ~174) — same `provision` command

Note: The investigation scope says "Remove from `uis-cli.sh`" but the command actually lives in the host-side wrappers, not in `uis-cli.sh`.

**Legacy package scripts (separate dead code):**
- `scripts/packages/ai.sh` — references old script paths
- `scripts/packages/auth.sh` — references old script paths

This `scripts/packages/` folder appears to be another legacy system predating UIS. Should be evaluated for deletion.

**Host installation scripts (still call the old system):**
- `hosts/install-azure-microk8s-v2.sh` (line ~220) — **executes** `provision-kubernetes.sh`
- `hosts/install-azure-aks.sh` (line ~168) — references old system in instructions
- `hosts/azure-aks/02-azure-aks-setup.sh` (line ~173) — references old system in instructions

**Important:** `hosts/install-azure-microk8s-v2.sh` actively calls the old orchestrator. Deleting `provision-host/kubernetes/` without migrating this script will break Azure VM deployment. This is tied to [INVESTIGATE: Remote Deployment Targets](../backlog/INVESTIGATE-system-remote-deployment-targets.md).

**Documentation (6 files reference old paths):**
- `docs/reference/troubleshooting.md`
- `docs/advanced/hosts/azure-aks.md`
- `docs/advanced/hosts/index.md`
- `docs/contributors/rules/kubernetes-deployment.md`
- `docs/networking/tailscale-internal-ingress.md`
- `docs/packages/ai/environment-management.md`

### Deletion Order

Cannot just delete `provision-host/kubernetes/`. The order matters:

1. Migrate `hosts/install-azure-microk8s-v2.sh` to use UIS (or accept it breaks until remote targets are implemented)
2. Remove `provision` command from `uis` and `uis.ps1` wrappers
3. Evaluate and clean up `scripts/packages/` folder
4. Update all 6 documentation files
5. Delete `provision-host/kubernetes/`

---

## Investigation Questions

1. Can `provision-host/kubernetes/` be deleted entirely? It's in git history if needed. Or tag a release first?
2. Does `./uis provision` legacy command still need to exist in `uis-cli.sh`?
3. Are there references to `provision-host/kubernetes/` in CI/CD workflows, Dockerfiles, or entrypoint scripts?
4. The "how deployment works" page should go in `advanced/` — users who just want to deploy don't need it, but anyone who wants to understand the system does.
5. Cloud host docs are covered by [INVESTIGATE: Remote Deployment Targets](../backlog/INVESTIGATE-system-remote-deployment-targets.md) — not in scope here.

---

## Scope

This investigation will produce multiple plans, each tackling a different part:

### ~~Plan area: Rename "packages" to "services"~~ — COMPLETED

**Implemented**: [PLAN-rename-packages-to-services](../completed/PLAN-rename-packages-to-services.md) (2026-03-17, PR #88)

### ~~Plan area: Delete old deployment system~~ — COMPLETED

**Implemented**: [PLAN-delete-old-deployment-system](../completed/PLAN-delete-old-deployment-system.md) (2026-03-17, PR #90)

### ~~Plan area: "How Deployment Works" documentation~~ — COMPLETED

**Implemented**: [PLAN-how-deployment-works](../completed/PLAN-how-deployment-works.md) (2026-03-17)

### ~~Plan area: Documentation gap filling~~ — COMPLETED

**Implemented**: [PLAN-documentation-gap-filling](../completed/PLAN-documentation-gap-filling.md) (2026-03-17)

Findings: CI/CD pipelines and generators documented in `contributors/guides/ci-cd-and-generators.md`. Integration testing documented in `contributors/guides/integration-testing.md`. Stack creation guide added to `contributors/rules/kubernetes-deployment.md`. Service override `service-overrides/` directory removed — was never implemented. Getting-started path improved with deployment suggestions and cross-links.
