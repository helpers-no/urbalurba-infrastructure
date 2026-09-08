# PLAN-005: Migrate Playbooks to New Kubeconfig Path

**Related**: [INVESTIGATE-whoami-kubeconfig-path](INVESTIGATE-whoami-kubeconfig-path.md)
**Status:** Completed
**Created**: 2026-02-19

## Background

PLAN-004 (secrets cleanup) removed the legacy kubeconfig symlink at `/mnt/urbalurbadisk/kubeconfig/kubeconf-all` from the `uis` wrapper. However, 59 Ansible playbooks still hardcode this path. A legacy symlink was added back as a bridge fix.

This plan migrates all playbooks to the new path and then removes the legacy symlink.

## Scope

Change `merged_kubeconf_file` (and `kubeconfig_file`) from:
```
/mnt/urbalurbadisk/kubeconfig/kubeconf-all
```
to:
```
/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all
```

in all 59 playbooks, plus `provision-host-rancher/docker-compose.yml`.

## Implementation

### Phase 1: Update all playbooks

Simple find-and-replace across all `.yml` files in `ansible/playbooks/`:

```bash
# merged_kubeconf_file (55 files)
sed -i '' 's|/mnt/urbalurbadisk/kubeconfig/kubeconf-all|/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all|g' ansible/playbooks/*.yml ansible/playbooks/utility/*.yml

# docker-compose.yml
sed -i '' 's|/mnt/urbalurbadisk/kubeconfig/kubeconf-all|/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all|g' provision-host-rancher/docker-compose.yml
```

### Phase 2: Update 04-merge-kubeconf.yml comment

The comment on line 23 still references the old path.

### Phase 3: Remove legacy symlink from uis wrapper

Remove the bridge symlink added in PLAN-004:
```bash
# Legacy path — 59 playbooks still reference this; remove after PLAN-005 migration
mkdir -p /mnt/urbalurbadisk/kubeconfig
ln -sf /home/ansible/.kube/config /mnt/urbalurbadisk/kubeconfig/kubeconf-all
```

### Phase 4: Build and verify

- Rebuild container
- Run unit tests
- Tester verifies deploy/undeploy of whoami, ArgoCD, or JupyterHub

## Acceptance Criteria

- [ ] Zero references to `/mnt/urbalurbadisk/kubeconfig/` in playbooks
- [ ] Legacy symlink removed from `uis` wrapper
- [ ] Container builds
- [ ] Tester confirms deploy/undeploy works
