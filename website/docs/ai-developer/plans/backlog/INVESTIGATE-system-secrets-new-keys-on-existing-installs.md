---
title: "How does an existing installation pick up a new service's secret keys?"
status: backlog
type: INVESTIGATE
area: system
severity: high
created: 2026-08-24
---

# How does an existing installation pick up a new service's secret keys?

## The observation

Adding neko added two secret keys. On the test installation, the documented
flow did not deliver them:

```bash
./uis secrets apply     # ran clean; the NEKO_* keys were still absent
```

Two causes, found by the independent tester (2026-08-24) while testing neko:

1. **`apply` only applies previously *generated* output.** `generate` has to run
   first, and nothing in the flow says so or does it.
2. **The local templates never refresh.** The container image carries the new
   `NEKO_*` template lines, but `~/uis/.uis.secrets/secrets-config/*.template`
   is a copy made at bootstrap, and `secrets init` **refuses to run on an
   existing directory** — for good reason, since it would overwrite live
   credentials.

## Why this is bigger than neko

**Every installation bootstrapped before a service merged has this problem, for
that service.** That is all of them, for every service added from now on.

neko is simply the first service to add a secret key since the pipeline was
written, so it is the first to expose it. browserless added `BROWSERLESS_TOKEN`
and did not hit it, because the installations that tested it were bootstrapped
after that key existed.

The failure is also quiet in the worst way: `./uis secrets apply` **exits 0**.
The service then fails to deploy for a reason that looks like a bug in the
service. On neko it surfaced as a deploy-time assertion naming the missing key —
which only helped because that assertion happened to exist.

## What this is not

Not a neko defect, and neko is not blocked on it. The tester unblocked
themselves by hand-copying the template lines (disclosed, backed up, product
code untouched) and neko then deployed, which is the evidence that the service
itself is fine.

## Questions to answer

1. **Where should new keys come from on an existing install?** The image's
   templates are the source of truth, but the local copy is what
   `generate` reads. Should `generate` merge new keys from the image's templates
   rather than reading only the local copy?
2. **How is a merge made safe?** The reason `init` refuses is that overwriting
   would destroy live credentials. A merge that only *adds* absent keys, never
   touching existing values, may be the answer — the same append-only, guarded
   shape used when adding services to `enabled-services.conf`.
3. **Should `apply` run `generate` when the generated output is older than the
   templates?** Or refuse, and say so, rather than exiting 0 having done nothing?
4. **What tells a user a key is missing?** Right now, nothing — until a service
   fails. A `./uis secrets diff` showing keys present in the templates and
   absent from the live secret would turn a silent gap into a visible one.
5. **Does this affect key *removal* and *renaming* too**, or only addition?

## Why it matters beyond convenience

The secrets pipeline is the interface every service reads, and the whole point
of the design is that the pod is byte-identical in every environment while the
values differ. That guarantee is only as good as a new key's ability to reach
an existing installation.

## Related

- Surfaced during `PLAN-service-neko-001-optional-addon` verification
- Same family as [[PLAN-cli-uis-docs-writes-outside-repo]]: a command that
  reports success while having done nothing to the state it names
