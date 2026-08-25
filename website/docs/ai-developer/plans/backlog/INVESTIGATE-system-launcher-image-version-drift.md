---
title: "The launcher and the image are versioned independently, and nothing notices"
status: backlog
type: INVESTIGATE
area: system
severity: high
created: 2026-08-25
---

# The launcher and the image are versioned independently, and nothing notices

**Proposed by**: ops at Terje's direction, 2026-08-25. Filed here with additions;
the framing is theirs and it is correct.
**Related**: `INVESTIGATE-uis-distribution` (completed) designed the update model
**for the container**. The launcher lives on the host, so it was outside that
frame — this is the second half, not a correction.

## UIS is two artifacts, and only one of them updates

| | What | How it updates |
|---|---|---|
| `~/uis/uis` | host-side bash launcher — starts/stops the container, mounts volumes, forwards commands | **nothing. A human copies a file.** |
| `ghcr.io/helpers-no/uis-provision-host` | the CLI, playbooks, service definitions | `./uis pull` |

Nothing checks they are compatible. Nothing reports drift.

## What it cost

ops ran the **3 August** launcher against the **25 August** image. That launcher
wrote the kubeconfig as a symlink on every start, so **every verify failed** —
and before the config-error pre-flight landed, the symptom was *"The Dagster
webserver did not answer a GraphQL query"* on a completely healthy Dagster. It
was nearly filed as a Dagster fault.

`./uis pull` could not fix it. Pulling the image is exactly what was done, and
the host script reintroduced the fault on every start.

## The maintainer's own installation had it too

Checked while filing this, and it is the strongest argument in the document:

```
launcher: Aug  7   ln -sf present, cp fix absent
kubeconf-all: symlink, created Aug 24 13:39 by that launcher
```

The fix was written in this repo that morning. The machine it was written on was
still creating the symlink on every start. **"Remember to update it" is not a
mechanism** — it had already failed for the person most motivated to apply it.

Repaired by copying the launcher and restarting, which also produced the first
real end-to-end confirmation of the fix (it had only ever been tested against
simulated states):

```
before: kubeconf-all -> /home/ansible/.kube/config    (symlink)
after : -rw------- 4867 bytes                          (real file)
kubectl through it: contexts listed
second restart: unchanged — idempotent
```

## What should become true

1. The launcher **declares its own version**, discoverable without reading source.
2. A stale launcher is **detected and reported** — on `pull` certainly, ideally on
   `start`.
3. A drifted pair **fails as a configuration problem**, never as a broken service.
   The `target_host` pre-flight established that principle; this is the same
   principle one layer out.
4. There is a **supported way to update the launcher** that is not "copy a file
   from a repo checkout you may not have".
5. `./uis start` should not **silently run a stale image** — today it pulls only
   when the image is absent.

## Two thirds of the mechanism exists

```
image  /mnt/urbalurbadisk/version.txt   → 0.1.1     ✅
repo   raw .../main/version.txt         → HTTP 200  ✅
launcher declares a version             → nothing   ❌
```

## The model to adopt

`helpers-no/devcontainer-toolbox`, `.devcontainer/manage/dev-update.sh` — same
house, already in production: reads a local version, fetches the remote one,
reports `X → Y`, has `--check`, **updates the host-side file from a template
after backing it up**, refuses politely when pinned, and cleans up old images.

The host-side step is the one UIS is missing entirely.

## DECIDED (Terje, 2026-08-25): one version, and it is displayed

This supersedes the "strict match or a range?" question below, and simplifies the
rest.

**There is ONE version for the product** — `version.txt` — carried by the
launcher, the container image and the documentation site alike. Not a launcher
version paired with an image minimum, which is what this document originally
proposed. One number, so "do these agree?" is a string comparison and "what am I
running?" has a single answer.

**It is displayed on the website**, as `devcontainer-toolbox` displays its own: a
badge in the navbar, on every page. Shipped — the site reads `version.txt` at
build time rather than hardcoding it, and omits the badge entirely if the file
cannot be read, because a version nobody can trust is worse than none.

### What that decision leaves to build

1. **The launcher must carry the version**, since today it declares nothing.
   With one shared number, the launcher and the image are compatible when their
   versions are equal — which is only checkable once the launcher has one.
2. **`./uis pull` compares and reports** local against
   `raw.githubusercontent.com/.../main/version.txt`, exactly as DCT does.
3. **`./uis version` reports both halves**, not just the container's. Today it
   prints the container's version, so a box with a three-week-old launcher shows
   `v0.1.1` and looks current. That is how all three of this week's incidents
   stayed invisible.
4. **`./uis pull` updates the launcher**, backup first — the step DCT has and
   UIS lacks. Download to a temp file, `bash -n` it, back up, `mv` into place:
   `mv` writes a new inode, so the running shell keeps its descriptor on the old
   one and finishes cleanly. The new launcher applies to the next invocation.

### One consequence worth stating plainly

A single version means **`version.txt` must actually be bumped on release**. It
has sat at `0.1.1` while the image was rebuilt many times, and the only thing
distinguishing today's images is the git SHA in
`org.opencontainers.image.revision`. A shared version that never changes reports
"in step" for two artefacts that are weeks apart — the failure this work exists
to prevent, wearing the fix as a disguise.

So the bump has to be part of releasing, or the comparison is theatre.

## Answers to the open questions, as starting positions

**Should the launcher self-update, or only detect and instruct?**
Both, in that order. Detect-and-instruct is the safe default and must exist
anyway for anyone who declines. A `./uis self-update` is then worth having,
because "copy a file from a repo checkout you may not have" is how the fleet
drifted in the first place.

The mid-execution hazard is real but narrow: replacing the file with `mv` writes
a **new inode**, and the running bash keeps its open descriptor on the old one.
Editing in place is what corrupts a running script. So: download to a temp file,
`bash -n` it, back up the current one, `mv` into place, and tell the user the new
version applies to the next invocation — do not re-exec mid-command.

**Strict match or a range?**
Neither, quite. A strict match makes every image release a fleet-wide emergency;
a range invites guessing what is compatible. The pairing that fits how this
actually broke: **the launcher declares its version, and the image declares the
minimum launcher it requires.** Then a launcher merely behind is a warning, and
one below the stated minimum is a hard configuration failure. Today's case would
have been the second — the image's kubeconfig expectations genuinely required the
newer launcher — and it would have said so on the first `./uis start`.

**Where does the canonical launcher live?**
The repo root, reachable at the same `raw.githubusercontent.com` path already
proven to serve `version.txt`. One base URL for both files, no new publishing
step. `website/static/uis` is a second copy that would need keeping in step —
this document exists because two copies drifted.

**Fold into the completed distribution investigation, or stand alone?**
Stand alone, cross-linked. That one is complete and correct within its frame;
reopening it would blur what was decided from what was missed.

## What this does not answer

Whether the drift check belongs on `start` (every invocation, needs to be fast
and offline-tolerant) or only on `pull` (rarer, but a user who never pulls never
learns). A network call on every `start` is a cost this platform has avoided
elsewhere, and an offline developer must not be blocked. That trade is the first
thing to settle.

## Related

- [[INVESTIGATE-uis-distribution]] — the container half, completed
- [[INVESTIGATE-system-assertions-cannot-distinguish-could-not-ask]] — why the
  symptom pointed at Dagster instead of at the launcher
