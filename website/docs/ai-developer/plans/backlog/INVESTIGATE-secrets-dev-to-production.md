# Investigate: a secret that works in dev, and what happens to it in production

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-08-14

## Status: Backlog

---

## Background

A developer builds a service on Rancher Desktop, needs a credential, adds it, gets
everything working. Then it goes to production. **This investigation follows that
one secret across the boundary**, because that journey is where the platform's
secret handling either holds or quietly fails.

The good news first: the *application* side is already portable. The developer
reads `urbalurba-secrets` by `secretKeyRef`, and the manifest is byte-identical in
both topologies. Nothing in this investigation asks them to change that.

What is not portable is **the value behind the key**, and the machinery that is
supposed to notice.

---

## Part 1: Findings (measured 2026-08-14)

### SEC-F1 — An unset variable becomes an empty secret, silently

Secrets are rendered with `envsubst`. Verified directly:

```
$ printf 'KEY: "${DEFINITELY_UNSET_VAR}"\n' | envsubst
KEY: ""
```

If a production installation has never heard of the developer's new key, the
Secret is created with an **empty value**. Nothing fails at deploy. The service
fails later, at runtime, with whatever error an empty credential produces — which
is rarely "your secret is missing".

### SEC-F2 — Validation is a hardcoded allowlist, so new secrets never join it

`validate_secrets` in `secrets-management.sh` checks:

```
required_vars   7 hardcoded names   (DEFAULT_ADMIN_EMAIL, DEFAULT_ADMIN_PASSWORD, …)
weak-value      6 hardcoded names   matched against ^LocalDev
```

The shipped template carries **62 keys**. A key the developer adds is in neither
list, so it is checked for neither presence nor a development placeholder.

This is the same defect shape found twice already this week — an allowlist that new
things do not join, reporting success while missing the case. `VERIFY_SERVICES`
registered in two of three places behaved identically.

### SEC-F3 — A development placeholder can reach production without a warning

The weak-value check covers 6 names and, even for those, only `log_warn`s. So:

- a developer adds `STRIPE_API_KEY=LocalDevStripe123`
- the operator copies the dev config forward, or simply never learns the key exists
- production runs on a literal development credential
- **nothing warns, and nothing fails**

Of the three ways this can go, this is the one that looks like success.

### SEC-F4 — Validation does not run on the path people use

`validate_secrets` is reachable from `uis secrets validate` (explicit, opt-in) and
from the generate flow. It is **not** part of `uis deploy <service>`. The command
a developer and an operator actually run every day does not check whether the
secrets it is about to depend on are present or real.

### SEC-F5 — Adding one secret means editing three files

[adding-a-service](../../../contributors/guides/adding-a-service.md) Step 7 lists
three edits for a single new credential: the common-values template, the
master-secrets template, and `default-secrets.env`. Three places to keep in step,
with nothing checking they agree — the same multi-place registration problem that
produced unreachable verify playbooks.

### SEC-F6 — What the developer never writes is exactly what production needs

In dev the developer writes **nothing** about where a secret comes from; they read
`urbalurba-secrets`. If production sources that key from the vault, someone must
author an `ExternalSecret` **that was never written or exercised in dev**.

So the one artifact that differs between environments is the one nobody tested.
See [INVESTIGATE-service-openbao](./INVESTIGATE-service-openbao.md) Part 2b, whose
Option C exists to close precisely this gap.

---

## Part 2: What the journey should look like

1. **A missing secret fails the deploy, loudly, naming the key.** The operator
   should learn from the tool, not from a runtime stack trace in an unrelated
   service.
2. **A development placeholder in a non-dev topology is an error, not a warning.**
   The topology is already known — `cluster-config.sh` states it.
3. **Validation derives from the template**, so a key added today is checked today.
   No allowlist to update, because updating it is the step that gets missed.
4. **Adding a secret is one edit, or the places are checked against each other.**
5. **The developer's manifest stays unchanged.** Whatever is decided here must not
   ask applications to know where their secrets come from.

---

## Part 2b: Making it easy for the developer

**This is the binding constraint, and it rules out most of the options in Part 3.**

### What it costs today

Adding one secret means editing three **shared** files:

```
00-common-values.env.template     274 lines
00-master-secrets.yml.template    729 lines
default-secrets.env                70 lines
                                 ----
                                 1073 lines, three places to keep in step
```

The developer must also know which namespace block inside the 729-line file their
key belongs to. And because the files are shared, two developers adding secrets in
the same week collide in the same file.

That is a lot of ceremony for "my service needs a Stripe key", and three chances
to get it wrong with nothing checking.

### The shape the platform already uses

Services already ship small artifacts beside themselves:

```
services/<category>/probes/<id>.yaml
services/<category>/dashboards/<id>.json
```

Secrets fit the same shape:

```
services/<category>/secrets/<id>.yaml
```

```yaml
STRIPE_API_KEY:
  why:      "billing integration - charges customers"
  dev:      "LocalDevStripe123"      # what a laptop uses
  required: true                     # deploy fails without a real value outside dev

STRIPE_WEBHOOK_SECRET:
  why:      "verifies webhook signatures"
  generate: true                     # UIS mints one per install; nothing to supply
```

### Why this is both easier and more correct

- **One small file, in the developer's own service directory.** No 729-line file,
  no namespace block to locate, no collisions with other developers.
- **Q1 answers itself.** `required:` is the signal, declared where the person who
  knows the answer is already working. No allowlist to update, so SEC-F2's "new
  secrets never join the check" disappears by construction.
- **SEC-F3 becomes exactly detectable.** Because `dev:` records the development
  value explicitly, "production is running the dev placeholder" is a comparison
  rather than a `^LocalDev` guess — and it catches placeholders that never matched
  that pattern.
- **`why:` is required**, the rule already held by uptime-kuma monitors and
  `external-services.yaml`. A failed deploy can then say what the key is *for*,
  which is the difference between an actionable error and a lookup.
- **`generate: true` removes the work entirely** for the ~25 internal passwords UIS
  mints per install. The developer declares intent; the platform does it.
- **It matches the convention settled twice already this session**: shape ships
  with the service, values are per-installation.

### What the journey then looks like

```
dev    add services/<cat>/secrets/<id>.yaml, uis deploy <id>  -> works, zero config
prod   uis deploy <id> -> FAILS, naming the keys and their why:
       "STRIPE_API_KEY is required (billing integration - charges customers)"
```

The developer edits one file they own. The operator is told exactly what to supply
and why. Neither reads a 1073-line template.

### Cost, stated honestly

This is a bigger change than patching `validate_secrets`: it needs a merge step at
generate time, and the existing 62 keys should migrate to it — otherwise the
platform ends up with two mechanisms, which this session has repeatedly found to be
worse than either alone. A migration path is part of the plan, not an afterthought.

---

## Part 3: Open questions

- **Q1 — Where does the "required" signal come from?** **Part 2b proposes an answer: a per-service declaration, so the signal lives where the person who knows it is already working.** Every key in the template
  being mandatory is too strong; many are genuinely optional. Options: a marker in
  the template (`# required`), a convention (`_TOKEN`/`_PASSWORD` suffixes), or a
  per-service declaration listing the keys it needs. The third is the most honest
  and the most work.
- **Q2 — Which topologies enforce?** "Not `rancher-desktop`" is the obvious rule,
  but a second developer cluster would also be non-dev and should not be forced to
  supply production credentials.
- **Q3 — Fail or warn on empty?** A missing optional secret should not block a
  deploy. Without Q1, empty and optional are indistinguishable.
- **Q4 — Does this replace Step 7's three files, or just check them?** Collapsing
  to one source is cleaner and a bigger change; checking that the three agree is
  cheap and leaves the duplication.
- **Q5 — How does an operator discover new keys?** A diff between the shipped
  template and the installation's config would name them. Where should that
  surface — `uis secrets validate`, `uis status`, or the deploy itself?

---

## Part 4: Why this comes before the vault question

[INVESTIGATE-service-openbao](./INVESTIGATE-service-openbao.md) asks whether UIS
needs a vault at all. On the reference installation the vault backs **one**
`ExternalSecret` while `urbalurba-secrets` carries **54 keys**.

Whatever that answer turns out to be, every one of the findings above still
applies: a vault does not stop an unset key rendering empty, does not make an
allowlist self-updating, and does not put validation on the deploy path. Fixing
this first makes the vault question smaller, because it removes the failure modes
people might otherwise hope a vault would solve.

---

## Part 5: Proposed plans (draft after the questions are answered)

1. **Template-derived validation** — replace both hardcoded lists with a check
   generated from the template, and run it on `uis deploy`, failing with the
   missing key names. Closes SEC-F1, F2, F4.
2. **Placeholder values are an error outside dev** — closes SEC-F3, and depends on
   Q2's topology rule.
3. **One place to add a secret**, or a consistency check across the three — closes
   SEC-F5, depending on Q4.
