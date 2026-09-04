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
