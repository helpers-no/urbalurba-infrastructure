---
title: "Verify assertions cannot distinguish “could not ask” from “answered wrongly”"
status: backlog
type: INVESTIGATE
area: system
severity: medium
created: 2026-08-25
---

# Verify assertions cannot distinguish "could not ask" from "answered wrongly"

## The shape

Almost every verify probe follows this pattern:

```yaml
- shell: kubectl ... some query ...
  register: _out
  failed_when: false          # so the play can assert instead of aborting
- assert:
    that: _out.stdout is search('expected')
```

`kubectl`'s **stdout** is captured; its **stderr** is discarded. So an empty
`_out.stdout` means either:

- the service answered wrongly — a real defect, or
- **the question was never asked** — wrong context, unreadable kubeconfig,
  missing namespace, RBAC denial, a typo in a resource name

and the assertion can only ever report the first. It reports a **configuration
failure as an unhealthy service**.

## Why it matters more than it sounds

Observed twice on 2026-08-25, both times convincingly:

1. A non-existent kubectl context made a healthy Dagster report *"the webserver
   did not answer a GraphQL query"*. The message went on to **speculate a
   cause** — "the pod may be unable to reach its metadata database" — which was
   entirely wrong, and would have sent the reader to debug a database.
2. A kubeconfig left as an unreadable symlink broke **every** verify on an
   installation. The tester nearly attributed it to an unrelated release.

In both cases `kubectl` printed exactly the right diagnosis, and it appeared
**zero times** in the output.

## What has already been done

`run_verify_playbook` now pre-flights the two known causes — it checks the
context exists and the kubeconfig is a readable regular file, and fails as a
*configuration error* before the playbook starts. That closes the two instances
above at the source.

**It does not close the class.** A kubectl call can still fail mid-playbook for
reasons the pre-flight cannot anticipate: a namespace that does not exist, an
RBAC denial, a resource renamed upstream, an API-server timeout. Every one of
those still surfaces as "the service did not answer".

## Questions

1. **Should probes assert on rc, not just on stdout?** `failed_when: false` is
   there so the play can produce a good message rather than an ansible traceback
   — but nothing then distinguishes rc≠0 from an unexpected answer.
2. **Should failure messages carry stderr by convention?** Done ad hoc in the
   neko daemon checks and now in dagster A2. As a convention it would fix the
   class; as a per-message habit it will drift, like `target_host` did.
3. **Is there a shared probe helper to be had** — one that runs a command,
   captures both streams, and returns a structure an assertion can read
   ("could not ask" vs "asked, got X")? That is the version that cannot drift.
4. **How many messages currently speculate about a cause they have not
   established?** Dagster A2 did. A sweep would say whether that is common.

## Related

- The two instances: `for-ops-test-verify-target-host.md` (imac, 2026-08-25)
- [[INVESTIGATE-system-verification-playbooks-usage]] — same family: verifies
  that pass or fail for reasons unrelated to the service
- The `kubectl run --rm` idiom, which returns rc=0 with empty stdout, is the
  purest instance of this shape
