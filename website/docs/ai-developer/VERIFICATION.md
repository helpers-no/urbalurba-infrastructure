---
title: Writing a testable dispatch
sidebar_label: Verification
---

# Writing a testable dispatch

Build and verify are separated: the maintainer builds, an independent tester
runs it on a real cluster. What crosses between them is a **dispatch** — a file
saying what shipped, what to run, what counts as passing, and how to try to
break it.

This page is about the last of those, because it is where dispatches fail.

## The rule

> **After injecting a fault, read the value back from where the code will
> actually read it. Only then run the test.**

A falsification that does not actually break anything produces a **passing run
that reads as proof the check works**. That is worse than no falsification: it
manufactures confidence in both directions, and it costs the tester a round to
discover.

## Why this keeps happening

Three dispatches shipped with recipes that could not fail. The shape is the same
every time:

**the injection is performed at a layer the command under test rewrites or ignores.**

| Recipe | Why it was inert |
|---|---|
| `PG_PSQL_HOST=… ./uis configure …` | `docker exec` does not inherit the host environment, so the variable never crossed into the container |
| `PG_PSQL_HOST=…` again, after that was fixed | the app was already configured, so the command short-circuited before reaching any psql call |
| `kubectl patch secret …` then `./uis deploy …` | `deploy` re-applies secrets from the generated file **first**, reverting the patch in the same command meant to be tested against it |

In all three the run went green, and green is exactly what a broken check looks
like. One of them was nearly filed as *"the check cannot detect the
misconfiguration it exists for"* — a false alarm on the most important assertion
in that service.

## What the check costs

Seconds, and it is available to the builder without a cluster:

```bash
# environment override — does it arrive inside?
./uis exec sh -c 'echo "${PG_PSQL_HOST:-UNSET}"'

# secret patch — does the cluster actually hold it, after the command runs?
kubectl get secret urbalurba-secrets -n <ns> \
  -o jsonpath='{.data.<key>}' | base64 -d

# config file edit — does the process read that file, or a generated copy?
```

If the value read back is not the injected one, the recipe is inert. Fix the
recipe before shipping the dispatch, not after the tester spends a round on it.

## Write the confirmation into the dispatch

Do not merely check it yourself — make the tester's first step confirm the fault
is present, so a silently-inert injection cannot be mistaken for a working check:

```markdown
**a. Confirm the fault is actually present, then test:**

    ./uis exec sh -c 'echo "${UIS_TARGET_HOST:-UNSET}"'   # must print the injected value
    ./uis verify dagster                                  # only meaningful if the line above did

If the first command prints `UNSET`, the second proves nothing whatever it says.
```

## Three more ways a dispatch proves nothing (2026-08-26/27)

The rule above is about falsifications that cannot fail. The version-system rounds
produced three siblings, all found by the tester, all costing a round.

### 1. A gate that cannot pass

A dispatch pre-flight said *refuse to start unless the image reports 1.6.4*:

```bash
docker run --rm --entrypoint cat "$IMAGE" /uis/version.txt   # WRONG PATH
```

There is no `/uis` in the image — the file is at `/mnt/urbalurbadisk/version.txt`. So the
gate failed on a missing file **whatever the build state**, and could not discriminate the
thing it existed to discriminate.

> **A gate that cannot pass is the mirror image of a falsification that cannot fail.**
> Both report the same verdict regardless of the state they are meant to tell apart.

It is the more dangerous direction, because refusing *looks* like working. Two consequences:

- **Copy the command the product already uses.** The correct pre-flight was sitting in
  `uis` at `installed_version()`. It was written from memory instead, while that file was
  open.
- **An error is not a negative result.** `No such file or directory` means *the gate is
  broken*, not *the wrong version*. A dispatch must say which of the two a non-zero exit is,
  or the tester will grade a build on a broken instrument.

### 2. The code under test must be the code doing the work

Testing a fix to the launcher's self-update, the tester installed the **pre-fix** launcher and
ran it, saw the old behaviour, and was one step from filing "the fix does not work".

The launcher that *performs* the update is the one that prints the message. Installing 1.6.3 to
trigger a self-update meant 1.6.4 was what got **installed**, never what **ran**.

> **Confirming the fault is present is not enough. The code under test has to be the code
> doing the work.**

Same family as the rule at the top — the injected state was not the state the claim is about —
but it survives the original rule, because the fault really was present and really was read
back correctly.

### 3. A pre-flight must not consume the state the acceptance measures

The same dispatch asked for both:

- pre-flight: `docker pull …:latest`, then check the version
- acceptance: the **image digest must change** across `./uis pull`

Running the pre-flight satisfies the pull, so the digest cannot change afterwards and the
acceptance criterion **can never pass on its own terms**. The tester resolved it by reading the
registry digest without touching the local store, and committed in advance to reporting
BLOCKED rather than grading the round if the version turned out wrong.

> **Read the pre-flight and the acceptance together and ask whether performing the first
> destroys the evidence for the second.**

Prefer a pre-flight that *observes* (query the registry, inspect a manifest) over one that
*acts* (pull, restart, deploy). Anything the pre-flight does is state the acceptance no longer
gets to measure.

## The general form

This is the same distinction that keeps appearing in the services themselves:

> **"I could not ask" and "the answer was no" must never be reported the same way.**

A verify that cannot reach a cluster must not report an unhealthy service. A
configure that cannot connect must not report a missing database. And a
falsification that did not inject anything must not report a working check.

The failure mode is identical in all three: **an absent result being read as a
negative result.** Where the services now distinguish the two, dispatches must
too.

## Related

- [WORKFLOW.md](./WORKFLOW.md) — plan to implementation
- [[INVESTIGATE-system-assertions-cannot-distinguish-could-not-ask]] — the same
  distinction inside verify playbooks
