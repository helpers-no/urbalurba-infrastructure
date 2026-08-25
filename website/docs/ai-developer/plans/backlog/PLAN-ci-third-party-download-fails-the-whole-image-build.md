---
title: "One flaky third-party download fails the entire image build"
status: backlog
type: PLAN
area: ci
severity: medium
created: 2026-08-26
---

# One flaky third-party download fails the entire image build

## The observation

`Build UIS Container` has failed twice in two days, both times inside
`provision-host-02-kubetools.sh`, both times at **"Installing k9s"**, on
`linux/arm64`. `kubectl` and `helm` installed cleanly immediately before. A
plain re-run passed both times.

```
Installing kubectl        ✓
Installing Helm           ✓
Installing k9s            ← fails here
Error executing provision-host-02-kubetools.sh. Continuing with next script.
...
provision-host-02-kubetools.sh: Failed (Exit code: 1)
ERROR: failed to build
```

Neither failure was caused by the commit being built — the first was a
launcher-only change, the second touched `uis` and `version.txt`. Nothing in
either goes near the provisioning path.

## Why it costs more than a re-run

The build takes **11–13 minutes**. A failure means noticing, diagnosing whether
it is yours, re-running, and waiting again — roughly half an hour of elapsed
time for a transient network error on someone else's CDN.

It also actively misleads. The failure lands on a commit, so the first question
is always *"did I break the build?"* — and answering that honestly means reading
the log rather than assuming. That cost is paid every time.

There is a subtler cost: **a red build trains people to re-run rather than
read.** The next genuine failure will look like this one.

## Two things worth separating

The script already tolerates the failure — it prints *"Error executing
provision-host-02-kubetools.sh. Continuing with next script"* and carries on —
but the provisioning summary then reports the script as failed and the whole
`RUN` layer exits 1. So the intent to continue is there and does not reach the
exit code.

1. **Should a k9s download failure fail the image at all?** k9s is an
   interactive TUI for humans debugging a cluster. Nothing in UIS's automation
   depends on it. An image without k9s is degraded, not broken.
2. **If it should, it needs a retry.** One attempt against a third-party CDN,
   on a 12-minute build, is a coin flip that costs half an hour when it lands
   wrong.

## Options, roughly in order of effort

- **Retry the download** — three attempts with a short backoff. Smallest change,
  addresses the immediate cost, does not change what the image contains.
- **Make non-essential tools non-fatal** — install k9s (and similar) on a
  best-effort basis, and have the summary distinguish "a required tool failed"
  from "an optional tool was skipped". This is the one that matches the script's
  existing intent.
- **Pin and vendor** — fetch from a mirror we control. Most robust, most work,
  and adds a thing to maintain.

My lean is retry plus the essential/optional distinction: the retry removes most
occurrences, and the distinction means the ones that remain do not fail a build
over a tool nothing depends on.

## What this is not

Not a UIS defect, and not caused by any change. It is a supply-chain fragility
that UIS chose to treat as fatal.

## Related

- Observed on `1fa5d36600cf` (2026-08-25) and `be7ac147ef21` (2026-08-26)
- Same family as [[INVESTIGATE-system-launcher-image-version-drift]] in one
  respect only: both are about what it takes for a change to actually reach the
  machines that need it.
