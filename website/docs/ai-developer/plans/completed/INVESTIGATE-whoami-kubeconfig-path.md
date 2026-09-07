# INVESTIGATE: Playbooks Using Old Kubeconfig Path

**Status:** Completed

**Related Plan**: [PLAN-004-secrets-cleanup](../completed/PLAN-004-secrets-cleanup.md)
**Found by**: Tester during PLAN-004 verification (Round 2, 2026-02-19)
**Severity**: Regression — playbooks fail when run via Ansible

## Problem

The `uis` wrapper was updated (PLAN-004, Phase 1.3) to only create the kubeconfig symlink at the new path:

```
/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all
```

The old legacy symlink was removed:

```
/mnt/urbalurbadisk/kubeconfig/kubeconf-all
```

However, **59 Ansible playbooks** still reference the old path via `merged_kubeconf_file` or `kubeconfig_file` variables. When these playbooks run, `kubectl` can't find the kubeconfig and falls back to `localhost:8080`, which fails with:

```
error validating "...": failed to download openapi:
Get "http://localhost:8080/openapi/v2?timeout=32s": dial tcp [::1]:8080: connection refused
```

## Tester Observations

- `./uis deploy whoami` failed — the Ansible playbook couldn't connect to the API server
- `docker exec uis-provision-host kubectl apply -f ...` works fine (kubectl uses `~/.kube/config` directly)
- The tester classified it as "pre-existing" but the root cause is the removed legacy symlink

## Affected Files

59 playbooks reference `/mnt/urbalurbadisk/kubeconfig/kubeconf-all`:

| Variable | Count |
|----------|-------|
| `merged_kubeconf_file` | 55 |
| `kubeconfig_file` | 4 |

Plus `04-merge-kubeconf.yml` has it in a comment, and `provision-host-rancher/docker-compose.yml` references it.

Key playbooks affected:
- `025-setup-whoami-testpod.yml`
- `070-setup-authentik.yml`
- `220-setup-argocd.yml`
- `350-setup-jupyterhub.yml`
- All deploy, remove, and utility playbooks

## Why Other Playbooks Worked in Testing

ArgoCD and JupyterHub passed testing in earlier rounds because the tester was using the **old** `uis` wrapper at the time, which still created the legacy symlink. The updated wrapper was only copied for the PLAN-004 Round 2 test.

## Fix Options

### Option A: Add legacy symlink back to `uis` wrapper (quick fix)

Add one line to the `uis` wrapper's kubeconfig setup:

```bash
mkdir -p /mnt/urbalurbadisk/kubeconfig
ln -sf /home/ansible/.kube/config /mnt/urbalurbadisk/kubeconfig/kubeconf-all
```

Pros: Zero-risk, all 59 playbooks work immediately, no mass edits.
Cons: Keeps the old path alive alongside the new one.

### Option B: Update all 59 playbooks to use new path

Change `merged_kubeconf_file` to point to `.uis.secrets/generated/kubeconfig/kubeconf-all` in all playbooks.

Pros: Fully migrated, single source of truth.
Cons: Large change (59 files), risk of typos, needs thorough testing.

### Option C: Use `get_kubeconfig_path()` from paths.sh

Have playbooks resolve the path dynamically via the paths library instead of hardcoding it.

Pros: No more hardcoded paths, future-proof.
Cons: Requires Ansible to call shell functions, adds complexity.

## Recommendation

**Option A first** (add legacy symlink back) to unblock immediately, then **Option B** as a follow-up plan to migrate all playbooks to the new path. Option A is a one-line change in the `uis` wrapper and restores functionality without risk.
