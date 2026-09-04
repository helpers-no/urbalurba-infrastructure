---
mdx:
  format: md
---

# project-uis

The authoritative description of **this** repository. Framework docs (`WORKFLOW.md`, `GIT.md`,
`SECURITY.md`, …) yield to this file when they disagree.

## What this repo is

The Urbalurba Infrastructure Stack (UIS): a `./uis` CLI, the Ansible playbooks and service
templates it drives, the Kubernetes manifests those deploy, and the Docusaurus site that documents
all of it. One installation is a cluster plus the CLI that provisions and verifies it.

## What it builds / does not build

- **Builds**: the `uis` CLI and its shell libraries, service playbooks and templates, the
  documentation site, and the `uis-provision-host` container image (built by GitHub Actions, never
  locally).
- **Does not build**: the clusters themselves, the tenant applications that consume UIS services,
  or anything in a `.uis.extend` overlay — those belong to an installation, not to this repo.

## Layout

- `uis` — the host-side launcher. **Not in the container image**; it is fetched over the raw CDN.
- `provision-host/uis/` — the in-container CLI: `manage/uis-cli.sh`, `lib/`, `services/`, `tests/`
- `ansible/playbooks/` — deploy, verify and remove playbooks, plus `templates/`
- `manifests/` — Kubernetes manifests
- `website/` — the Docusaurus site
- **This `ai-developer/` folder lives at `website/docs/ai-developer/`**, so it is published as part
  of the site. There is no second copy.

## Commands

From `website/`:

```bash
npm ci          # first time, ~40 s
npm run build   # REQUIRED before pushing anything under website/
```

From the repo root:

```bash
bash provision-host/uis/tests/run-tests.sh static   # the static guard suite
```

⚠️ `npm run build` needs **more than 2 GB of RAM**. Under a 2 GB cap it aborts with
`JavaScript heap out of memory` and exit 134; it passes at 3 GB. Expect 2–4 minutes cold.

## Git host

**GitHub.** `origin` is `helpers-no/urbalurba-infrastructure`, reached through an SSH host alias
with a per-repo deploy key. So [GIT.md](GIT.md)'s GitHub `gh` operations apply and
`AZURE-DEVOPS.md` does not — it is deliberately absent from this folder.

### ⚠️ Override of GIT.md's confirmation rule

`GIT.md` says never to run `git add`, `commit`, `push`, `checkout -b` or `merge` without asking
first. **That is not the rule here, and this file wins.** The maintainer agent commits, branches,
pushes and merges to `main` as ordinary work. What replaces it is stricter in the places that
matter:

- **Never merge work that an independent tester has not passed.** The agent builds and declares
  testable; it does not grade its own work.
- **When merging, verify that what landed is what was graded** — diff the merged file against the
  graded commit rather than trusting the merge.
- **Never push anything under `website/` without running `npm run build` first.** Broken links fail
  the build, so a skipped build means a red `main`.
- **Never commit internal addresses, hostnames or credentials.** See [SECURITY.md](SECURITY.md).

A reader who finds `GIT.md` alone will be misled. It is kept unmodified so it does not drift from
the fleet template; the override lives here, which is where the template says overrides belong.

## Devcontainer

**No — `DEVCONTAINER.md` does not apply to the maintainer agent, and is deliberately absent
from this folder.**

This repo *does* ship a `.devcontainer` (DevContainer Toolbox) and contributors use it. But the
maintainer agent works **on the host**: it runs `npm run build` and the static suite directly, which
is exactly how a docs failure gets caught before CI. Adopting `DEVCONTAINER.md` would install a rule
— "all commands must run inside the devcontainer" — that the mandated pre-flight breaks every time.

Stated here so no agent invents a cage it does not need.

## Contracts (non-negotiable)

- **This repository is PUBLIC.** Everything committed is world-readable immediately.
- **The builder is not the verifier.** An independent tester grades; a `completed` verdict on your
  own work is self-grading.
- **The container image is built by GitHub Actions**, never locally.
- **A change that republishes the image must bump `version.txt`**, or the update path cannot see the
  release — the launcher compares versions, not digests.
- **A human decides** public exposure, production writes, credentials and deletion.

## Always-loaded files

- Repo-root [`CLAUDE.md`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/CLAUDE.md)
- Repo-root [`AGENTS.md`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/AGENTS.md)

⚠️ These are **absolute** URLs on purpose. The template suggests adjusting a relative path to repo
root, which cannot work here: this `ai-developer/` folder lives inside the published Docusaurus
tree, so anything above `website/docs/` is outside the site and no relative link resolves. The
build enforces that — `onBrokenMarkdownLinks` is `throw`.

## URB fleet

- Agent id: `tor-agent`
- Fleet coordination is the **Issues bus** in `terchris/urb-agents`, reached with
  `ops/bus/fleet-task.sh`. Delivery is by issue number; browsing by inbox is eventually consistent.
- Do not clone `terchris/urb-agents`. Do not copy `protocol/` here — it is read remotely, always.
- The old file-based `talk/` bus was retired for this agent on 2026-08-31.

## Other documentation

The rest of the product documentation is the Docusaurus site under `website/docs/` — services,
contributor rules and guides, and host/platform docs. This folder is the agent-facing subset of it.
