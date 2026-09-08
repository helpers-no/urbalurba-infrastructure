# Feature: Add `./uis pull` command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Add a `./uis pull` command to the repo-root wrapper that pulls the latest container image and restarts the container

**Last Updated**: 2026-05-06

**Completed**: 2026-05-06 — `pull_container()` shipped in both `./uis` (line 174) and `website/static/uis` (line 191); help text in both wrappers documents the command. All phase tasks and acceptance criteria are met by the existing code.

**Related**: [INVESTIGATE-container-pull-command.md](./INVESTIGATE-container-pull-command.md)

---

## Overview

The repo-root `./uis` wrapper has no command to update the container image. The `website/static/uis` wrapper already has a working `update` command. This plan adds `pull` to the repo-root wrapper and updates the help text.

---

## Phase 1: Add pull command to repo-root wrapper

### Tasks

- [ ] 1.1 Add `pull_container()` function to `./uis` (adapt from `website/static/uis` `update_container()`, renamed to `pull`)
- [ ] 1.2 Add `pull` case to the main command handler
- [ ] 1.3 Add `pull` to the help text in the `help` case output

### Validation

```bash
./uis pull
```

Container image is pulled and container restarts. User confirms.

---

## Phase 2: Update website wrapper

### Tasks

- [ ] 2.1 Rename `update` to `pull` in `website/static/uis` (function name, case handler, help text, header comment)

### Validation

User confirms the rename looks correct.

---

## Acceptance Criteria

- [ ] `./uis pull` pulls the latest image and restarts the container
- [ ] `./uis help` shows the `pull` command
- [ ] Both wrappers (`./uis` and `website/static/uis`) use the same command name `pull`

---

## Files to Modify

- `uis` (repo-root wrapper)
- `website/static/uis` (website-distributed wrapper)
