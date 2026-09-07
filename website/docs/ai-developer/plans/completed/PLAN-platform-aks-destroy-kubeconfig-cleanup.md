# Plan: clean up merged kubeconfig entries when destroying an AKS cluster

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (2026-05-16)

Implementation landed in `platforms/azure-aks/scripts/03-destroy.sh` via the shared `pf_remove_context` + `pf_lockstep_flip` helpers in `provision-host/uis/lib/platform-switching.sh`. All four acceptance-criteria items satisfied:

- `pf_remove_context "$AZURE_AKS_CLUSTER_NAME"` deletes context + cluster + user refs from `kubeconf-all` and syncs to the legacy bind-mount path (delete-cluster/-context/-user + cp, lines 211-241 of `platform-switching.sh`).
- `pf_lockstep_flip "rancher-desktop"` re-points `current-context` and writes `cluster-config.sh` in one shared writer (line 209 of `03-destroy.sh`).
- The host-kubeconfig defensive cleanup (`kubectl config delete-context`) runs first at line 181.
- Per-cluster `$KUBECONFIG_FILE` removal at line 194.

The verbatim code in this PLAN was not used — the equivalent work landed as higher-level helpers shared with `02-post-apply.sh` and `cmd_platform_use`, which converges on the lockstep-flip / context-removal pattern. Net outcome identical.

**Goal**: When `platforms/azure-aks/scripts/03-destroy.sh` tears down an AKS cluster, also remove that cluster's stale `clusters:` / `contexts:` / `users:` entries from the merged `kubeconf-all`, and re-point `current-context` to `rancher-desktop`. Symmetric counterpart to `02-post-apply.sh`'s flip-on-apply.

**Last Updated**: 2026-05-10

**Source**: tester's Round 3 Tier A retry №4 result in `testing/uis1/talk/talk.md` — flagged as a real bug after PR #149's merge gate was already met. Deferred from #149 to ship the verification-loop fixes; tracked here.

---

## Problem Summary

After `03-destroy.sh` runs, `cluster-config.sh` correctly resets to `rancher-desktop` (PR #149 added this), but the merged `kubeconf-all` files still contain the destroyed cluster's three entries:

- `clusters: azure-aks` — pointing at an API server that no longer resolves (`azure-aks-XXXX.hcp.westeurope.azmk8s.io … no such host`)
- `contexts: azure-aks`
- `users: clusterUser_*`
- `current-context: azure-aks`

Symptoms operators have hit:

- Bare `kubectl …` (no explicit `--context`) fails with confusing DNS-lookup errors instead of "you destroyed this cluster".
- Multiple destroy/recreate cycles accumulate stale entries forever; `kubectl config get-contexts` becomes a graveyard.
- Atlas-side port-forwards die silently after destroy because the tester's local `kubectl port-forward` is rooted at a now-dead context.

The destroy already removes the per-cluster `${cluster}-kubeconf` file and the `kubectl` context binding — but it does not edit the merged file that ~100 consumers across the repo read from.

## Phase 1: Implement the cleanup section in `03-destroy.sh`

### Tasks

- [ ] 1.1 In `platforms/azure-aks/scripts/03-destroy.sh`, add a new section between the existing "Cleaning up kubeconfig" block (per-cluster file removal) and "Reset UIS target to rancher-desktop" (cluster-config flip):

  ```bash
  print_status "Removing $AZURE_AKS_CLUSTER_NAME entries from merged kubeconfig..."

  # Operate on the in-container path (kubectl flock-safe); sync to the
  # bind-mount path after, mirroring 04-merge-kubeconf.yml's tasks 29-31.
  KUBECONF_PRIMARY="/mnt/urbalurbadisk/kubeconfig/kubeconf-all"
  KUBECONF_LEGACY="/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"

  if [[ -f "$KUBECONF_PRIMARY" ]]; then
      kubectl --kubeconfig "$KUBECONF_PRIMARY" config delete-context "$AZURE_AKS_CLUSTER_NAME" 2>/dev/null || true
      kubectl --kubeconfig "$KUBECONF_PRIMARY" config delete-cluster "$AZURE_AKS_CLUSTER_NAME" 2>/dev/null || true
      kubectl --kubeconfig "$KUBECONF_PRIMARY" config delete-user \
          "clusterUser_${AZURE_AKS_RESOURCE_GROUP}_${AZURE_AKS_CLUSTER_NAME}" 2>/dev/null || true

      # Re-point current-context at rancher-desktop if it's available
      if kubectl --kubeconfig "$KUBECONF_PRIMARY" config get-contexts -o name | grep -qx 'rancher-desktop'; then
          kubectl --kubeconfig "$KUBECONF_PRIMARY" config use-context rancher-desktop >/dev/null
          print_success "current-context switched to rancher-desktop"
      else
          print_warning "rancher-desktop context not in merged kubeconfig — current-context left dangling"
      fi

      # Sync to legacy path that ~100 consumer playbooks read from
      cp "$KUBECONF_PRIMARY" "$KUBECONF_LEGACY"
      print_success "Cleaned merged kubeconfig synced to legacy path"
  else
      print_warning "Merged kubeconfig not found — nothing to clean"
  fi
  ```

- [ ] 1.2 Verify on rancher-desktop + AKS hot-patched container: bring up an AKS cluster, run a `./uis deploy` against it, then run `03-destroy.sh`. After destroy:
  - `kubectl --kubeconfig $KUBECONF_PRIMARY config get-contexts` shows no `azure-aks` entry.
  - `kubectl --kubeconfig $KUBECONF_PRIMARY config current-context` returns `rancher-desktop`.
  - `cmp -s $KUBECONF_PRIMARY $KUBECONF_LEGACY` exits 0.
  - Bare `kubectl get nodes` succeeds (it would have failed with DNS error before this fix).

### Validation

The verbatim acceptance check from the tester's reply:

> **Edge case to handle**: if the operator destroys an AKS cluster without a rancher-desktop context in their merged kubeconfig (some future remote-only setup), the `else` branch warns and leaves the file alone rather than picking a random context. Conservative; fail loud rather than silent.

## Implementation Notes

- The `delete-cluster` / `delete-context` / `delete-user` operations all run against the in-container path (`/mnt/urbalurbadisk/kubeconfig/kubeconf-all`), which kubectl already proved write-safe during PR #149's `02-post-apply.sh` apply flow. The `cp` to the legacy path is a plain file copy — no kubectl, no flock, safe across the lima/9P bind mount.
- The user name `clusterUser_${AZURE_AKS_RESOURCE_GROUP}_${AZURE_AKS_CLUSTER_NAME}` is the convention emitted by `az aks get-credentials` (and by extension the kubeconfig that OpenTofu's `kube_config_raw` output produces). If a future deployment uses a different user-name convention, we'd need to discover the user dynamically (`kubectl --kubeconfig … config view -o jsonpath` for users referencing the destroyed context).
- This is the symmetric counterpart to `04-merge-kubeconf.yml`'s tasks 29-31. Apply adds the cluster + sets context; destroy removes the cluster + resets context. Cleaner mental model for the next contributor.

## Files to Modify

- `platforms/azure-aks/scripts/03-destroy.sh` (add the cleanup section)
- `website/docs/ai-developer/plans/active/PLAN-platform-aks-destroy-kubeconfig-cleanup.md` ← move from `backlog/` to `active/` when work starts

## Acceptance Criteria

- [ ] After `03-destroy.sh` succeeds, the merged kubeconfig contains no entries referencing the destroyed cluster.
- [ ] `current-context` is `rancher-desktop` (or the warning fires if no rancher-desktop context exists).
- [ ] Both kubeconf-all paths (`/mnt/urbalurbadisk/kubeconfig/` and `.uis.secrets/.../kubeconfig/`) are byte-identical after destroy.
- [ ] Tester confirms via `./uis deploy <something>` after destroy: targets rancher-desktop cleanly with no manual cluster-config or kubectl-context fix-up.
