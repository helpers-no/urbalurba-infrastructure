# Fix: `test-all` hides work in `--dry-run` and skips a service permanently

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: `test-all` reports what it will do and what it did not do.

**Created**: 2026-08-21, during the Rancher Desktop validation run —
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).

**Investigation**: [INVESTIGATE-system-verification-playbooks-usage](./INVESTIGATE-system-verification-playbooks-usage.md)
— all three findings below are its "reports success while missing the case" shape.

**Priority**: Medium. Defect 1 can cost real state; 2 and 3 are silent coverage
gaps.

---

## Defect 1 — `--dry-run` omits the destructive half of the plan

`./uis test-all --only authentik --clean --dry-run` printed **6 operations**,
beginning with `deploy postgresql`. The real run began by undeploying two
services first, which the plan never mentioned.

A dry-run exists so someone can see what is about to happen before it happens.
One that shows the constructive half and hides the destructive half is worse than
none: it invites confidence precisely where care is needed. On a test cluster it
costs nothing. On any cluster someone cares about, "I checked the dry-run first"
would be a reasonable thing to have believed.

### Tasks

- [ ] 1.1 Include the clean phase in `--dry-run` output, naming each service to
      be undeployed
- [ ] 1.2 State the precondition in the output — that `test-all` will not adopt a
      service it did not create, and `--clean` removes those in its plan's scope
- [ ] 1.3 Make the scoping explicit. `--clean` is **not** cluster-wide: with
      `--only authentik` it touched only `postgresql` and `redis`, leaving
      `minio`, `nginx`, `whoami` and `uptime-kuma` untouched. That is good
      behaviour, undocumented, and easy to assume wrongly in either direction

### Validation

`--dry-run` operation count equals the real run's, on a cluster with services
already deployed.

---

## Defect 2 — `gravitee` is skipped permanently, silently

```bash
# Services always skipped (broken or not testable)
SKIP_SERVICES_ALWAYS="gravitee"
```

No date, no linked issue, no explanation of which of "broken" or "not testable"
applies. It cannot appear in any test run, and **nothing reports that it was
omitted** — a full-suite pass reads as "everything works".

Gravitee is not a stub: it has a service definition, a pinned chart (`4.11.3`),
a setup playbook and a docs page. Something made it untestable and that reason is
now lost.

### Tasks

- [ ] 2.1 Establish why. Try deploying it by hand on a clean cluster and record
      what happens — that is the missing information
- [ ] 2.2 Either fix it and remove the skip, or keep the skip **with a linked
      issue and a date**
- [ ] 2.3 Make skipped services visible in the run summary, not only the plan —
      a suite that silently omits a service reports a coverage level it does not
      have

### Validation

The summary names every skipped service and why. `gravitee` is either tested or
has a written reason with a date.

---

## Defect 3 — the conditional skip list is empty

`SKIP_SERVICES_CONDITIONAL` exists to skip services whose credentials are still
placeholders, and it is checked at runtime by `_build_skip_list`. It has **no
entries**.

So a service needing a real credential deploys with a `LocalDev` placeholder and
fails as though broken. The mechanism to prevent exactly that was built and never
populated — the same shape as
[INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md),
where validation is a hardcoded allowlist that new secrets never join.

### Tasks

- [ ] 3.1 Identify services requiring real credentials to deploy successfully
- [ ] 3.2 Register each with its required variables
- [ ] 3.3 Confirm a placeholder value produces `SKIPPED (credentials not
      configured)` and not `FAIL`

### Validation

With placeholder credentials, such a service is reported skipped, with the reason.

---

## Acceptance Criteria

- [ ] `--dry-run` shows the clean phase and matches the real run
- [ ] The scoping rule is documented in the output
- [ ] No service is skipped without a written, dated reason
- [ ] Skips appear in the run summary
- [ ] `SKIP_SERVICES_CONDITIONAL` reflects reality
- [ ] A full run's summary states its own coverage honestly

---

## Implementation Notes

**These three share one root**: `test-all` reports what it did, not what it did
not do. A suite whose omissions are invisible overstates its coverage every time
it passes — and the value of a green suite is exactly the confidence it justifies.

**Counter-evidence worth keeping**: `test-all` also *found* a real defect on
2026-08-21 that nothing else would have — the namespace-termination race, where a
deploy following an undeploy died and blamed an unrelated service. That is an
argument for running it more, which is an argument for it being honest about
scope.

---

## Files to Modify

- `provision-host/uis/lib/integration-testing.sh` — dry-run output, skip lists,
  summary
- `provision-host/uis/manage/uis-cli.sh` — `test-all` help text
- `website/docs/contributors/guides/integration-testing.md`
