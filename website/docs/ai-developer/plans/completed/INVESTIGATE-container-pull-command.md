# Investigate: UIS Container Pull Command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Add a `./uis pull` command that pulls the latest provision-host container image and restarts the container

**Last Updated**: 2026-03-11

---

## Problem

After initial installation, there is no way to update the provision-host container to a newer version. The `./uis` wrapper script in the repo root has no `pull` or `update` command. Users must manually run `docker pull` and restart the container.

Note: `website/static/uis` (the newer wrapper distributed via the docs site) has an `update` command that does this, but the repo-root `./uis` wrapper that developers actually use does not.

---

## Decisions

| Question | Decision |
|----------|----------|
| Command name | `./uis pull` |
| Behavior | Pull latest container image + restart container |
| In-flight operations | Warn if running, but proceed (user-initiated) |
| Version check | Out of scope for first implementation |
| Wrapper script updates | Out of scope — just the container image |
| Tag strategy | Keep `:latest` for now |

---

## Current State

- Repo-root `./uis` wrapper has no pull/update command
- `website/static/uis` has `update_container()` function (pull + stop + start) — can be used as reference
- CI/CD pipeline builds and pushes new images on merge to main
- Container image: `ghcr.io/terchris/uis-provision-host:latest`

---

## Implementation Notes

The `website/static/uis` wrapper already has a working implementation at lines 191-204:

```bash
update_container() {
    log_info "Pulling latest UIS container image..."
    if docker pull "$IMAGE"; then
        log_info "Image updated successfully"
        if is_container_running; then
            log_info "Restarting container with new image..."
            stop_container
            start_container
        fi
    else
        log_error "Failed to pull image"
        exit 1
    fi
}
```

Adapt this for the repo-root `./uis` wrapper, rename to `pull`, and add a case in the main command handler.

---

## Next Steps

- [ ] Create PLAN to implement `./uis pull`
