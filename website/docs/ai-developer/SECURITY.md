---
mdx:
  format: md
---

# Security

Read this before writing anything sensitive into the repository or a published site.

---

## Secrets

Secrets never enter git. Tokens, kubeconfig, passwords, and private keys stay on the host.
This includes urb-agents: fleet records must not contain credentials.

## Public vs private

If this repository is world-readable, do not commit internal topology, addresses, capacity, or
runtime identifiers. `project-*.md` states which.

## Published docs

This repository is **public** and publishes a documentation site. There is no read gate: anything
committed here is world-readable the moment it lands.

**The rule for internal detail, decided by Terje on 2026-08-30 and recorded in full in
[Secrets Management](../contributors/rules/secrets-management.md#decision-internal-addresses-already-in-this-repo-are-accepted):**

- The private-range addresses **already committed** are accepted. Not sanitised, not made private.
  A deliberate acceptance of a residual risk, not a finding that there is none.
- That acceptance covers **what is already there**. It is not a reason to add more — prefer a
  placeholder, and keep real values in the private fleet repository.
- It holds on two conditions, and **both** must remain true: **private-range addresses only**, and
  **no credentials of any kind**. If either stops holding, that is a new decision and it belongs to
  the platform owner, not to a contributor or an agent.

⚠️ That boundary is enforced by **review, not by a check**. Nothing in CI fails a commit that adds a
publicly routable address or a credential-shaped string. Closing that gap is filed work, not a
solved problem.

---

## Dependency alerts

**Triaged 2026-09-07** — 11 open Dependabot alerts (8 high, 1 medium, 2 low).

Two facts that scope the whole class:

- **Every alert lands in `website/package-lock.json`.** The documentation site is the only
  npm surface in this repository. Nothing in `provision-host/`, the container image, or the
  Ansible layer is affected — those pin by image tag and chart version, tracked separately.
- **None is a direct dependency.** All arrive transitively through `@docusaurus/core`, so the
  work is an `npm update` sweep, not one merge per alert.

⚠️ `npm audit` totals and the Dependabot alert count do not match and are not supposed to —
audit counts advisory/package pairs across the whole tree, Dependabot counts alerts. Do not
treat a difference as a discrepancy.

### Accepted, with a re-check condition — not fixed

Both survive the sweep because **no dependency update can resolve them.** They are recorded
here so an open alert is not mistaken for an untriaged one.

**`image-size` — 2 high, open since 2026-08-10.** No patched version exists: everything
`<= 2.0.2` is vulnerable and the advisory lists no fix. Path:

    @docusaurus/core -> @docusaurus/mdx-loader -> image-size@2.0.2

It is a **build-time** parser — it reads local image files to compute dimensions while the
docs site builds. The denial of service needs a malformed ICNS/JXL/HEIF file **committed to
this repository**, so exploiting it requires write access, and the damage is a failed build
on a machine the attacker already controls.

*Re-check when:* `@docusaurus/core` ships a release depending on a patched `image-size`.

**`qs` — 1 medium.** A fix exists (`6.16.0`) and cannot be reached. Path:

    @docusaurus/core -> webpack-dev-server -> express@4.22.2 -> qs@6.15.3

`express` 4.x pins `qs` below the fix, so bumping it needs Express 5 upstream.
`webpack-dev-server` serves `npm start` only — it is **not part of the built site** and never
runs on a server. Reachable only by whoever is already on the developer's laptop.

*Re-check when:* Docusaurus moves to Express 5, or `webpack-dev-server` stops depending on it.

### What triage must not sort by

⚠️ Sort by **age as well as severity.** The two oldest alerts here were 29 days old and were
the *least* interesting — no fix, no action possible — which is exactly how a boring finding
survives every sweep that arrives after it. An old alert with a recorded reason is closed
work; an old alert with no note is a question nobody has asked yet.

