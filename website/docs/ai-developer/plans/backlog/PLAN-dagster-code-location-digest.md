# Plan: the definition is pinned by digest, the code that runs is not

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: `uis template install` must record, print, and — if the chart allows
it — pin the digest of the **code image** it causes to run, not only the digest
of the install definition it read.

**Found**: 2026-09-11 by `imac` during acceptance of 1.6.59 (`urb-agents#719`),
from the install it had just performed rather than from reading the code.

---

## What UIS verifies, and what it then runs

An application install resolves two different references:

| | reference | how UIS treats it |
|---|---|---|
| the **install definition** | `terchris/atlas-data/uis:v20260911-f4bf175` | pulled at a **digest**, checked against the `Pin` the catalogue records, refused if the tag is mutable |
| the **code image** | `terchris/atlas-data:v20260911-f4bf175` | written into the Dagster overlay as `repository` + `tag`. **Pinned nowhere** |

So the definition is verified with care and the thing that actually executes is
fetched by a mutable name. On imac's install the code image resolved to
`sha256:d7a371f7…` — **a digest that appears nowhere in any UIS output**.

🔴 **A re-push of that tag changes what runs while every digest UIS prints stays
identical.** The install would report exactly the same thing.

## Why the existing defences do not cover this

Both real defences are on the wrong reference:

- `_template_pin_is_immutable` refuses `latest`, `main`, `master`, `head` — and
  it refuses them for the **definition**, which is also the reference that
  already carries a digest.
- The code-location schema's own warning (`NEVER latest`) is about Helm not
  rolling the pod when the image string does not change. That is a **deployment
  correctness** argument, not an integrity one, and `v20260911-f4bf175` satisfies
  it completely while still being re-pushable.

⚠️ **An immutable-looking tag is not an immutable tag.** Nothing at the registry
stops `v20260911-f4bf175` being moved; the convention is the publisher's
discipline, and UIS currently depends on it without saying so.

## Why this is worth doing rather than noting

Two mutable-reference failures happened in a single evening, both to agents who
knew the rule:

- `:latest` moved off `1.6.58` between one measurement and the next, which put a
  stale claim into a message to `ops-dev` (`#717`).
- A cached registry read reported an application as unpublished when it had been
  published for an hour — the 1.6.59 defect.

This is the same class in the place hardest to notice, because there is no
symptom at all: no error, no changed output, no failed check.

## The shape of the fix

**Step 1 — record and print the resolved code-image digest. Cheap, and does not
depend on the chart.**

At install, resolve `image:tag` to its digest and report it alongside the
definition's `Pin`. A re-push then becomes *detectable* — the digest in the
install record differs from the digest resolving today — even if nothing is
pinned. This alone converts a silent substitution into an answerable question.

**Step 2 — pin it, if the chart can express it.**

⚠️ **NOT YET VERIFIED, and the plan must not assume it.** The overlay renders:

```yaml
image:
  repository: {{ cl.image }}
  tag: "{{ cl.tag }}"
```

The Dagster chart composes these as `repository:tag`. A digest is
`repository@sha256:…`, which that composition cannot produce — so a `digest:`
field cannot simply be passed through as a tag. Whether the chart offers a
digest form, and whether `repository: ghcr.io/x/y@sha256` with `tag: <hex>`
renders a valid reference, **must be established against the chart itself**
before any schema change is designed. A schema field that renders an invalid
image reference would fail the deploy loudly, which is the good case; one that
renders a *valid but wrong* reference is the bad case and is the reason to check
first.

**Step 3 — schema and docs.** An optional `digest:` in
`dagster-code-locations.yaml`, and a statement in the Dagster docs of which
reference UIS verifies and which it does not. The current documentation implies
more than UIS delivers by explaining pinning at length in the definition's
context.

## What this is not

- Not a reason to reject tag-based code locations. An application that cannot
  publish digests must still be installable.
- Not atlas's defect. The code-location schema **has no digest field at all**, so
  atlas could not pin this even if it wanted to.

## Acceptance

- An install prints the resolved code-image digest.
- Re-pushing a code tag between two installs produces visibly different output.
- If step 2 lands: an entry carrying a digest renders a reference the chart
  accepts, proven by a deploy, not by reading the template.
