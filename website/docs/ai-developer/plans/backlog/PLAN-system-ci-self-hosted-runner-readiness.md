# Plan: what UIS's workflows would need from a self-hosted runner, and why they should not move yet

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: If UIS's CI ever moves to self-hosted runners, the three properties
that make its workflows hostile to a persistent runner are fixed **first**,
rather than discovered during the migration.

**Found**: 2026-09-10. Terje asked for a self-hosted runner because *"GitHub
Actions credits are exhausted"* and CI was reported blocked across UIS
(`urb-agents#670`). Measuring first changed the scope.

---

## 🟢 The premise, measured

`helpers-no/urbalurba-infrastructure` is **PUBLIC**, and GitHub does not bill
standard runners in public repositories. At **21:58Z**, one hour *after* the
private bus repository's last working job, a merge here started four workflows:

```
21:58:01Z  in_progress        Build UIS Container       <- multi-arch
21:58:01Z  completed success  Test UIS Scripts
21:58:01Z  in_progress        Generate UIS Documentation
21:58:01Z  pending            Deploy Documentation
```

**Same organisation, same minute, opposite outcomes; the difference is
visibility.** So the budget emergency is confined to the private repositories,
and moving this one to a self-hosted runner would trade free, ephemeral,
isolated runners for lab hardware **at zero saving**.

⚠️ **That is a reason to sequence it deliberately, not a reason never to do
it.** Sovereign CI is a stated strategic goal and proving the path before it is
needed is legitimate. This plan is what that would cost.

## What the four workflows need

| workflow | needs | |
|---|---|---|
| `build-uis-container` | docker, buildx, QEMU | `platforms: linux/amd64,linux/arm64` |
| `test-uis` | kind, kubectl, helm, jq | kind needs Docker |
| `generate-uis-docs` | node/npm, git, jq | pushes commits |
| `docs` | node/npm | Pages deploy, `github-pages` environment |

## 🔴 The three that must be fixed before, not during

### 1. `generate-uis-docs.yml` pushes to `main`

It runs `git commit` and `git push` to regenerate the docs index. On a
GitHub-hosted runner that credential lives for the length of one ephemeral VM.
**On a persistent self-hosted runner it is a standing credential that writes
the default branch of a public repository**, on a machine that also runs code
from pull requests.

That is a larger prize than anything else in the CI surface and it is the item
most likely to be overlooked, because the workflow looks like documentation.

### 2. `docker/setup-qemu-action` modifies the host, permanently

Registering binfmt handlers for arm64 emulation is a **system-wide kernel
change that outlives the job**. Correct on a VM that is destroyed afterwards;
a lasting modification to a machine that is not.

### 3. `test-uis` runs `kind`, and two jobs collide

GitHub gives every job a fresh VM, so cluster names and host ports never clash.
One self-hosted runner executing two jobs does. Needs either a `concurrency:`
group or per-job cluster names — **a workflow change, which the brief hoped to
avoid**, and one that is cheap now and confusing under time pressure.

## What needs deciding

1. **Does the public repository move at all?** Measurement says it need not.
   Sovereignty says it eventually should. 🔴 Terje's call, and it should be made
   on the numbers rather than inherited from the emergency.
2. **If it moves: which machine.** ⚠️ The hypervisor with spare capacity is also
   the one hosting the production database, the object store and the vault. A
   permanent runner that executes repository code is one hop from all three.
3. **Ephemeral or persistent?** All three problems above are properties of
   *persistence*. ARC, or any runner that is destroyed per job, dissolves 2 and
   3 outright and shrinks 1 to the length of one job. The brief defers ARC as
   "the next step" — worth noticing that it is also the step that removes most
   of this plan.

## Tasks

- [ ] 1.1 Decide question 1 before anything is built
- [ ] 1.2 Split the docs regeneration push out of CI, or scope its credential
      to the one path it writes
- [ ] 1.3 Add `concurrency:` to `test-uis`, or make kind cluster names per-job.
      ⚠️ Worth doing **regardless** — it is correct on GitHub's runners too and
      costs nothing
- [ ] 1.4 Decide 2 and 3 together; they are the same question asked twice

## Acceptance

- no workflow holds a credential for longer than the job that needs it
- ⚠️ **a second concurrent `test-uis` job is proven not to collide** — by
  running two, not by reading the config. The failure is a race and a race
  does not appear in a diff

## The lesson this plan carries

The brief said CI was blocked across UIS. It was blocked in the private
repositories, and this one was building containers the whole time. **Measuring
the premise took two minutes and changed what the work is** — and the fact that
would have settled it was already in the report, written as an aside: *"this
repository is PRIVATE, which is why minutes are billed at all."*
