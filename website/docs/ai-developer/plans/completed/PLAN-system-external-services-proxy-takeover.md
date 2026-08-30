# Make the external-services proxy actually take over the service it stands in for

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: A service declared in `.uis.extend/external-services.yaml` is genuinely served from
outside the cluster, the verify can prove which topology answered, and removing the declaration
returns cleanly to in-cluster.

**Last Updated**: 2026-08-30

**Priority**: High — production and the test environment ran disjoint topologies until this closed.

⚠️ **Backfilled 2026-08-30, after the work was merged.** This plan did not exist while the work was
done: it ran as three rounds of `talk/` messages with nothing in `active/`, which meant an honest
`active: 0` in the status report concealed a day of in-flight work. Recorded here because six
defects and their causes are worth keeping, and because the gap was worth admitting rather than
quietly closing.

## Problem Summary

On 2026-08-30 the independent tester exercised the external-services proxy topology for the first
time. It failed on the first attempt, in the worst possible way:

```
$ uis verify postgresql
A. Database answers a real query:  PASS
B. Topology: EXTERNAL - proxied to <external host>
$ echo $?
0
```

The server answering was the **in-cluster StatefulSet**. Proven by fingerprint, because the tester
made the two databases distinguishable *before* starting — without that, a false green is
indistinguishable from a pass.

Six defects, and the first is why the other five survived:

| # | Defect |
|---|---|
| 1 | `uis verify` derived its topology line by **reading the declaration file** and printing it back, so it could never contradict the cluster |
| 2 | `kubectl apply` **strategic-merges a selector map**: the proxy's one label merged into the chart's three, so the proxy was never selected |
| 3 | The in-cluster workload kept serving alongside the proxy |
| 4 | The declared external port also set the **in-cluster** Service port, moving `postgresql` off 5432 and breaking every consumer |
| 5 | Reverting orphaned the proxy Deployment **and left the Service selecting nothing** — the database came back healthy and unreachable |
| 6 | The default external port was `SCRIPT_EXPOSE_PORT`, the **host-side** forwarded port, while the shipped docs promised the service's normal port |

## Phases with Tasks

## Phase 1: Make the verify capable of telling the truth

- [x] 1.1 Stop deriving topology from the declaration file
- [x] 1.2 Prove which server answered, by an instrument that survives NAT and DNS names
- [x] 1.3 Bound the run: a wrong target must fail, not hang
- [x] 1.4 Remove the "not proven" path that exited 0

### Validation

Tester round. **First attempt FAILED** — see Implementation Notes.

---

## Phase 2: Make the proxy take over

- [x] 2.1 Replace the Service selector outright rather than merging into it
- [x] 2.2 Stand the in-cluster workload down without touching its PVC
- [x] 2.3 Separate the in-cluster Service port from socat's upstream port
- [x] 2.4 Own the teardown: remove the proxy and restore the selector on revert

### Validation

Tester round: takeover PASS first time; round trip FAILED first time, fixed, then PASS.

---

## Phase 3: Close the record

- [x] 3.1 Document that consumers holding long-lived connections need a restart after a swap
- [x] 3.2 Capture the original selector *before* the apply, not after

## Acceptance Criteria

- [x] A declared-external database is genuinely served from outside the cluster
- [x] `uis verify` fails when the declared topology is not the real one
- [x] `uis verify` fails when it cannot prove which database answered
- [x] A plain in-cluster installation still passes
- [x] `port: <non-default>` does not move the in-cluster Service port
- [x] The data survives: StatefulSet scaled to 0, PVC untouched, same UID
- [x] Removing the declaration restores the previous state with no manual repair
- [x] An installation that never ran the service in-cluster is unaffected

## Implementation Notes

**Two rounds failed before passing, and both failures were instrument failures.**

*Round A* proved the topology with `inet_server_addr()`. That returns the address of the server end
**as the server sees itself**, so behind any bridge or NAT it is an internal address and never the
one the client dialled — it rejected a genuinely working proxy. It also parsed its input from
`kubectl run --rm`, which prints `pod "X" deleted` **on stdout**, so the parsed value could never
match anything: one check could never fire and its opposite fired on every run, redding the default
topology on every developer machine.

The replacement uses no address at all: **which pod backs the Service and does it carry the proxy
marker**, plus **`system_identifier` through the Service compared against a direct connection to the
declared host**. That is the cluster's permanent identity from initdb — it survives socat, NAT and
DNS names.

**A second-order lesson worth keeping**: the first fix for defect 5 stored the original selector
*after* applying the proxy, so it captured a merged value. It equalled the original only because
postgres's proxy selector is a subset of the chart's — a proxy carrying a key the chart lacks would
have restored a selector matching nothing, reintroducing the exact stranding it was written to
prevent.

**Deliberately not done**: nothing here was exercised against the production installation, which is
the only one running the proxy shape. Everything was found and proved on a single laptop fixture,
rebuilt three times by one tester. Closing this plan closes the *code* gap, not that one.

## Files Modified

- `ansible/playbooks/040-test-postgresql.yml`
- `ansible/playbooks/900-external-service-proxy.yml`
- `ansible/playbooks/templates/040-postgresql-external-proxy.yml.j2`
- `ansible/playbooks/templates/045-minio-external-proxy.yml.j2`
- `provision-host/uis/lib/service-deployment.sh`
- `provision-host/uis/lib/external-services.sh`
- `website/docs/services/databases/postgresql.md`
