---
title: Workflow
sidebar_position: 2
---

# Plan to Implementation Workflow

How plans become implemented features.

**Related:**
- [PLANS.md](PLANS.md) - Plan structure, templates, and best practices

---

## The Flow

**Note:** Claude always asks for confirmation before running git commands (add, commit, push, branch, merge).

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  1. USER: "I want to add feature X" or "Fix problem Y"              │
│                                                                     │
│  2. CLAUDE:                                                         │
│     - Creates PLAN-*.md or INVESTIGATE-*.md in backlog/             │
│     - Asks user to review the plan                                  │
│                                                                     │
│  3. USER: Reviews and edits the plan, then confirms                 │
│                                                                     │
│  4. CLAUDE:                                                         │
│     - Moves plan to active/                                         │
│     - Implements phase by phase                                     │
│     - Runs validation after each phase                              │
│     - Commits after each phase                                      │
│     - Updates plan with progress                                    │
│                                                                     │
│  5. USER: Reviews result                                            │
│                                                                     │
│  6. CLAUDE:                                                         │
│     - Moves plan to completed/                                      │
│     - Final commit                                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Step 1: Describe What You Want

Tell Claude what you want to do:

```
"I want to add a new PostgreSQL backup CronJob"
```

```
"Fix the Traefik ingress routing for the monitoring stack"
```

```
"Add Authentik SSO to the new service"
```

---

## Step 2: Claude Creates a Plan

Claude will:

1. **Create plan file** in `website/docs/ai-developer/plans/backlog/`:
   - `PLAN-*.md` if the solution is clear
   - `INVESTIGATE-*.md` if research is needed first
   - For large initiatives, an investigation may produce **multiple ordered plans** (`PLAN-001-*`, `PLAN-002-*`, etc.) — see [Splitting Investigations into Multiple Plans](PLANS.md#splitting-investigations-into-multiple-plans)
2. **Ask you to review** the plan

See [PLANS.md](PLANS.md) for plan structure, templates, and what goes in each section.

---

## Step 3: Review the Plan

Open the plan file and review it:

- Are the phases in the right order?
- Are the tasks specific enough?
- Is anything missing?
- Are the validation steps correct?

Edit the file if needed.

When satisfied, tell Claude:

```
"Plan approved, start implementation"
```

---

## Step 4: Claude Implements

Claude will:

1. **Move plan to active/**:
   ```bash
   mv website/docs/ai-developer/plans/backlog/PLAN-xyz.md website/docs/ai-developer/plans/active/
   ```

2. **Ask about feature branch** (recommended):

   Claude will ask:
   > "Do you want to work on a feature branch? (recommended)
   >
   > This keeps your changes separate from the main code until you're ready.
   > When done, you'll create a Pull Request to merge your changes."

   **If yes:** Claude creates a branch like `feature/postgres-backup`
   **If no:** Claude works directly on the current branch

   *See "What is a Feature Branch?" below if you're new to this.*

3. **Work phase by phase**:
   - Complete tasks in order
   - Ask user to confirm each phase: "Phase 1 complete. Does this look good?"
   - Update the plan file (mark tasks complete)
   - Commit after user confirms
   - Stop if user has concerns

4. **Ask for help** if blocked or unclear

---

## Step 5: Review Result

Check the changes:

- Do the manifests apply correctly?
- Do the services deploy properly?
- Any errors in the logs?

If changes needed, tell Claude what to fix.

If good, tell Claude:

```
"Looks good, complete it"
```

---

## Step 6: Claude Completes

Claude will:

1. **Move plan to completed/**
2. **Update plan status**: `## Status: Completed`
3. **Push changes**

**If working on a feature branch**, Claude will also:

4. **Create a Pull Request** using `gh pr create`
5. **Explain next steps**:
   > "I've created a Pull Request. You can:
   > - Review it on GitHub
   > - Ask someone to review it
   > - Merge it when ready"

---

## Version Management (MANDATORY)

**Before creating a pull request, ask:**

> "Should we bump the version for this change?
>  Current version: `<contents of version.txt>`
>  If yes, what should the new version be?"

If yes, edit `version.txt` — **the single version file** — and include it in the
same PR.

| Bump | When |
|---|---|
| PATCH `1.5.x` | bug fixes, small improvements |
| MINOR `1.x.0` | new features, documentation improvements |
| MAJOR `x.0.0` | breaking changes |

### Why this is mandatory rather than nice-to-have

**`./uis pull` only tells a user there is an update when the number changes.**
Ship a fix without bumping and it reaches nobody who is not already watching
commits — the update notice on every command says "up to date" about an
installation that is weeks behind.

That is not hypothetical. `version.txt` sat at `0.1.1` while the image was
rebuilt dozens of times, during which three defects shipped to the launcher and
reached no machine at all: the kubeconfig written as a symlink, images never
cleaned up, and a dropped override. **A version that never moves makes the
version check theatre**, and the check wears the fix as a disguise.

### What one edit propagates to

One file, every consumer:

- the container image (`Dockerfile` copies it in)
- `uis version` and the launcher's installed/latest comparison
- the update notice carried by every command
- the version badge on the documentation site
- the CI image tags

### Release process

```bash
echo "1.5.3" > version.txt
git add version.txt
git commit -m "chore: bump version to 1.5.3"
```

Merging to `main` builds and publishes the image tagged with both the version
and `:latest`. Users see it on their next `./uis` command, and get it with
`./uis pull`.

Adopted from `devcontainer-toolbox`, which states the reason plainly: *without a
version bump, changes will never reach users.*

---

## Handing work to the tester

Build and verify are separated — see **[Writing a testable dispatch](./VERIFICATION.md)**.
The rule that page exists for, because three dispatches have shipped without it:

> After injecting a fault, read the value back from where the code will actually
> read it. Only then run the test.

A falsification that does not break anything produces a passing run that reads as
proof the check works.

## Quick Reference

### Commands to give Claude:

| You say | Claude does |
|---------|-------------|
| "I want to add X" / "Fix Y" | Creates plan, asks for review |
| "Plan approved" | Asks about feature branch, moves to active/, starts implementing |
| "Yes, use a feature branch" | Creates branch, works there |
| "No, work on current branch" | Works on current branch |
| "Looks good, complete it" | Moves to completed/, creates PR if on feature branch |
| "Stop" | Pauses and waits for instructions |

---

## Example Session

```
YOU: I want to add a Grafana dashboard for monitoring PostgreSQL

CLAUDE: I'll create a plan for that.
        Created website/docs/ai-developer/plans/backlog/PLAN-grafana-postgres-dashboard.md

        Please review the plan and let me know if it looks good
        or needs changes.

YOU: [reviews file, makes edits]
     Plan approved, start implementation

CLAUDE: Do you want to work on a feature branch? (recommended)

        This keeps your changes separate from the main code until you're ready.
        When done, you'll create a Pull Request to merge your changes.

YOU: Yes

CLAUDE: Created branch: feature/grafana-postgres-dashboard
        Moving plan to active/...
        Starting Phase 1...

        [works through phases, committing after each]

        Phase 2 complete. Validation passed.
        Continuing to Phase 3...

        All phases complete. Please review the changes.

YOU: Looks good, complete it

CLAUDE: Done! I've:
        - Moved plan to completed/
        - Pushed the feature branch
        - Created Pull Request #25

        Next steps:
        - Review the PR on GitHub
        - Merge it when you're ready
        - Or ask a teammate to review it first
```

---

## What is a Feature Branch?

*If you're new to git branches, this section explains the concept.*

### The Problem

Imagine you're writing a book with others. If everyone edits the same copy at the same time, it gets messy. Someone might overwrite your changes, or you might break something while experimenting.

### The Solution: Branches

A **branch** is like making a personal copy of the book to work on. You can:
- Make changes without affecting the original
- Experiment freely
- Share your copy when it's ready

```
main (the original)
  │
  └── feature/add-postgres-backup (your copy)
        │
        └── [you work here safely]
```

### The Workflow

1. **Create branch** - Make your personal copy
2. **Work on it** - Make changes, commit as you go
3. **Create Pull Request (PR)** - Ask to merge your changes back
4. **Review** - Others can look at your changes before merging
5. **Merge** - Your changes become part of the original

### Why It's Recommended

- **Safe**: Your experiments don't break the main code
- **Reviewable**: Others can check your work before it's merged
- **Reversible**: Easy to undo if something goes wrong
- **Collaborative**: Multiple people can work on different features

### Commands Claude Uses

```bash
# Create and switch to a new branch
git checkout -b feature/my-feature

# Push the branch to GitHub
git push -u origin feature/my-feature

# Create a Pull Request
gh pr create --title "Add my feature" --body "Description..."
```

You don't need to memorize these - Claude handles it for you.

---

## Optional: Working with GitHub Issues

If you're using GitHub issues to track work, tell Claude:

```
"Work on issue #42"
```

Claude will:
1. Read the issue with `gh issue view 42`
2. Create a plan based on the issue
3. Create a branch: `issue-42-short-name`
4. Close the issue when complete
