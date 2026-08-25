---
title: "external-services is undiscoverable — no user-facing documentation"
status: backlog
type: PLAN
area: docs
severity: medium
created: 2026-08-25
---

# `external-services` is undiscoverable — no user-facing documentation

## The gap

`.uis.extend/external-services.yaml` lets an installation declare that it already
runs a service outside the cluster — a database on another host, an object store
on the hypervisor. `uis deploy <id>` then renders a transparent proxy instead of
the real thing, and nothing downstream can tell the difference.

It is a **first-class product feature**: a shipped default template, an enforced
`why:` field, convention-based template resolution, and a clear failure when a
service has no proxy template.

It is documented three ways, all of them well:

- **inline**, in `external-services.yaml.default` — genuinely good, with the
  addresses-not-credentials rule and the backplane-over-tunnel guidance
- **as design history**, in `PLAN-system-external-services-001` (completed
  2026-08-14, verified on both topologies)
- **as the decision record**, in `INVESTIGATE-system-external-or-in-cluster-services`

**None of it is on the documentation site.** No mention in getting-started, in
the advanced pages, or in the production pages. A user reading the docs would
never learn the feature exists.

## Why this is worth fixing rather than shrugging at

The inline documentation is only discoverable **after** you already know to look
in `.uis.extend/`. The people who most need this feature — someone moving from a
laptop install to a real one, with a database that already exists — are precisely
the people who have not read that directory yet. They will either run a second
database they did not need, or conclude UIS cannot use theirs.

It is also the feature the platform's dev/prod parity rests on. The two
topologies exist *because* of it.

## Not a writing job — a surfacing job

The material already exists and is good. This is mostly moving and linking:

- a page under the production or advanced section: what it is, the two-line
  example, the `why:` requirement, and the addresses-never-credentials rule
- a pointer from getting-started's "you now have PostgreSQL in your cluster"
  moment — that is where a reader with an existing database will be wondering
- a pointer from the service pages of anything commonly provided externally
  (postgresql first)
- the proxy's design constraints are worth surfacing for contributors too: the
  template header explains why the first container is a postgres image, and that
  reasoning is currently only visible to someone who opens the `.j2`

## Related

- `provision-host/uis/templates/uis.extend/external-services.yaml.default` — the
  existing inline documentation, which is the source material
- `ansible/playbooks/templates/040-postgresql-external-proxy.yml.j2` — the design
  constraints, currently invisible outside the file
- [[INVESTIGATE-system-service-category-taxonomy]] — same family: things that are
  true of the product but not findable from the docs site
