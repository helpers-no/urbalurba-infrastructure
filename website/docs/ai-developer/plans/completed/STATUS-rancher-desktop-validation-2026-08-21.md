# Validation record: the summer's work on a clean Rancher Desktop, 21 August 2026

## Status: Reference — a record of a test run, not a plan

**What**: first end-to-end validation of the 18 July – 19 August work on a
factory-reset Rancher Desktop cluster, on the iMac.
**Why here**: [STATUS-summer-vacation-2026-07-18-to-08-19](./STATUS-summer-vacation-2026-07-18-to-08-19.md)
recorded what was built. Nothing recorded whether it worked on a laptop, which is
Principle 0. This is that.

---

## The environment, and one detour worth recording

Rancher Desktop was factory-reset to get a clean cluster. **The fresh install came
up on Kubernetes v1.25.16 and Traefik 2.10.5** — eleven minor versions behind the
cluster it replaced (v1.36.3), and Traefik v2 rather than v3.

A fresh Rancher Desktop profile picks its own defaults rather than what was there
before. Corrected to v1.36.3 + Traefik 3.7.8 before any testing.

**Had this not been caught, `whoami` and `nginx` would both have failed on the
`traefik.io` CRD group and read as UIS regressions.** The old cluster carried
*both* CRD groups (`traefik.containo.us` and `traefik.io`) from a v2→v3 upgrade in
place, which masks the difference; a clean v3 install has only `traefik.io`.

| | asgard (production) | iMac after correction |
|---|---|---|
| Kubernetes | `v1.36.2+k3s1` | `v1.36.3+k3s1` |
| Traefik | v3 | `3.7.8` |
| CRD groups | — | 25 × `traefik.io`, no `containo.us` |

VM: 3 CPU, ~7.8 GiB allocatable, 74 GiB free disk.

---

## Results — eighteen services, zero outstanding failures

### Batch 1 — deployed and left running

| Service | Deploy | Verify | Notes |
|---|---|---|---|
| `whoami` | `ok=18 changed=2` | in-setup, 8 tasks | IngressRoute live on Traefik v3 |
| `nginx` | `ok=45 changed=13` | in-setup, 7 tasks | explicitly `traefik.io/v1alpha1` |
| `postgresql` | `ok=8 changed=2` | ✅ registered | reports **`Topology: in-cluster`** |
| `minio` | `ok=19 changed=3` | ✅ **5/5 E2E** | bucket create/write/read/delete |
| `redis` | `ok=20 changed=9` | in-setup, 1 task | **no PVC** |
| `uptime-kuma` | `ok=23 changed=6` | ✅ 4/4 | both invocation forms |

### Batch 2 — via `uis test-all --only`, which also exercises removal

Terje's point: the uninstall is a test too, and it gives the memory back.
`test-all` does deploy → verify → undeploy in dependency order, so it covers both
directions in one pass.

| Service | Deploy | Undeploy |
|---|---|---|
| `mongodb` | PASS (1m 43s) | PASS (10s) |
| `mysql` | PASS (1m 32s) | PASS (12s) |
| `qdrant` | PASS (56s) | PASS (10s) |
| `rabbitmq` | PASS (3m 56s) | PASS (13s) |

8/8 operations passed. **Eleven services validated in total, zero failures.**

`mysql` showed `Pending` briefly — transient scheduling, not the resource ceiling.
Node at peak: cpu 960m requests (32%), memory 1972Mi requests / 5546Mi limits
(24% / 69%). The box is comfortable at this batch size; the heavy services
(`elasticsearch`, `openmetadata`) are still expected to change that.

`rabbitmq` at 3m 56s is four times anything else, almost all of it Helm waiting on
the StatefulSet.

### Two warnings found, both filed

Neither broke anything. Both recorded because the platform has twice paid for
"silently wrong" over "loudly broken" — `kubectl run --rm -i` and `envsubst`.

1. **`kubernetes<24.2.0 is not supported or tested`** →
   [PLAN-system-k8s-client-version-pin](../backlog/PLAN-system-k8s-client-version-pin.md).
   Measured in the container: Python client **12.0.1** against a **v1.36** API
   server, and **not pinned anywhere** — it is whatever the base image carries.
2. **`Found variable using reserved name: namespace`** →
   [PLAN-system-ansible-reserved-var-names](../backlog/PLAN-system-ansible-reserved-var-names.md).
   Not one playbook — **21**, counted by parsing `vars:` blocks. Concentrated in
   the observability set and Traefik, i.e. the batch this run postponed, so it
   will appear in volume when that runs.

### `test-all` cannot be used incrementally

Attempting `./uis test-all --only authentik` against a cluster already running
`postgresql` and `redis` refused to start:

```
✗ Cluster is not in a clean state. The following services are deployed:
  - postgresql
  - redis
Run with --clean to undeploy all services first
```

⚠️ **Corrected after observing an actual `--clean` run.** The first version of
this note claimed `--clean` tears down the whole cluster. **It does not.** Both
the precondition check and `--clean` are scoped to the test plan: with
`--only authentik`, the check flagged only `postgresql` and `redis` (its
foundation) and ignored `minio`, `nginx`, `whoami` and `uptime-kuma`, which ran
throughout and survived untouched.

So `test-all` **can** be used incrementally. What it insists on is *owning* the
services in its own plan — it will not test against an instance it did not create.

Practical consequences:

- Every batch redeploys its foundation (`postgresql` ~33s, `redis` ~44s) even
  when already running and healthy, because it will not adopt them.
- You cannot test against a *pre-existing* dependency, only one this run built.
  For a service whose behaviour depends on that dependency's state, that is a
  different test.
- The `--dry-run` output does **not** show the clean step. It printed 6
  operations; the real run began with two undeploys. **This one is worth fixing**
  — a dry-run that omits the destructive half of its plan is the same
  "reports success while missing the case" shape this repo keeps paying for.

Otherwise not a defect; the precondition is defensible.

### Batch 3 — the four with registered verify playbooks

| Service | Deploy | Verify | Undeploy |
|---|---|---|---|
| `temporal` | PASS | PASS | PASS |
| `argocd` | PASS | PASS (4/4 critical) | PASS |
| `backstage` | PASS (3m 43s) | PASS | PASS |
| `enonic` | PASS | PASS (6/6 critical) | — |

**18 services validated, zero outstanding failures.**

ArgoCD and Enonic both verify that authentication *rejects* a wrong password, not
only that it accepts a right one. Enonic additionally does a repository
read-back. These are the strongest tests in the repo after Authentik's.

### Backstage: three causes, two of them ours

Backstage was undeployable. Three attempts, each ~10m 43s, each ending
`context deadline exceeded` — which read like a slow box and was not.

1. **The catalog generator emitted an invalid ConfigMap key.** One trailing
   comment in `service-postgrest.sh` became three catalog entities named `#`,
   `TODO(backstage):` and `<app>-rest`. `kubectl create configmap --from-file`
   uses filenames as keys, `#` is invalid, and the *whole* ConfigMap is rejected.
   Fixed in the generator, not the comment — commit `3aa3ef2`.
2. **A floating third-party index.** `includes: dynamic-plugins.default.yaml`
   makes the installer resolve RHDH's entire default plugin set from
   `quay.io/rhdh/plugin-catalog-index:next`, and one unpublished entry aborts
   everything. Red Hat hit the identical error in their own CI the same morning
   (redhat-developer/rhdh#5289, RHDHBUGS-3678). Fixed by `includes: []` and
   pinning the chart — commit `c7dae01`.
3. **My first attempt at (2) was a no-op.** Removing the `includes` key does
   nothing: it is a *chart default*, and Helm merges maps. The file parsed, the
   copy landed, and the rendered ConfigMap still had it. Only reading what the
   cluster actually received revealed it.

The 600s Helm timeout was never the problem — **3m 43s** once the init container
stopped crash-looping.

### The namespace-termination race — found by running the suite

`enonic` reported FAIL four times. It was never broken: on a quiet cluster it
deploys clean and passes 6/6 verify tests. `undeploy backstage` returned in 9s
while its namespace was still `Terminating`, and `apply_secrets` — one
`kubectl apply` over a file carrying a namespace and secret for *every* service —
was rejected by the dying namespace and returned non-zero, aborting the next
deploy.

Fixed in commit `91fd276`: wait for terminating namespaces, up to 60s, then warn
and proceed. Verified by reproducing the exact condition.

**This is the third failure today that named the wrong service.** OBS-F6 blamed
Grafana, this blamed enonic, and the Backstage diagnosis went through two wrong
causes first. Timing- and load-dependent failures that accuse an innocent
component appear to be this platform's characteristic bug shape, and they are
expensive because the obvious next step — investigate the named service — is
always wrong.

### Two coverage gaps in `test-all` itself

- **`gravitee` is permanently skipped** — `SKIP_SERVICES_ALWAYS="gravitee"`,
  commented *"broken or not testable"*, with no date and no linked issue. It will
  never appear in a test run and nothing reports its absence.
- **`SKIP_SERVICES_CONDITIONAL` is empty.** The mechanism for skipping services
  whose credentials are still placeholders exists and has no entries, so such a
  service will attempt to deploy with `LocalDev` values and fail as if broken.
  Related to [INVESTIGATE-secrets-dev-to-production](../backlog/INVESTIGATE-secrets-dev-to-production.md).

### What this actually establishes

**The external-services convention holds on the laptop side.** This was the
summer's largest structural change and only the *production* half had ever been
exercised — by construction, since the convention is about services running
outside the cluster. `postgresql`'s verify detects its own topology and passes the
identical test it passes against the external proxy on asgard:

```
A. Database answers a real query:  PASS
B. Topology: in-cluster
```

**MinIO works in-cluster.** Flagged by Terje as never tested with UIS on Rancher
Desktop. Deploy plus full E2E, first time.

**Redis's PVC removal took** (19 Aug change). Worth recording because Redis has no
registered verify, so nothing else would have caught a regression.

**The verify-registration fix held.** Both `uis verify uptime-kuma` and
`uis uptime-kuma verify` run — first clean-cluster proof that
[PLAN-cli-verify-registration-fix](../backlog/PLAN-cli-verify-registration-fix.md)
Phase 1 actually fixed the three-place defect.

**Uptime Kuma warns about its own deployment** — *"If you have just deployed it
onto the cluster you intend to monitor, it cannot tell you when that cluster is
down."* Correct and well-placed. This instance is a functional test, not a usable
watchdog.

---

## What this run does NOT establish

- **The `kubectl run --rm -i` race is untested here.** It is load-dependent, and
  six light services do not load a box. The steps most likely to trigger it —
  observability and litellm — were deliberately postponed. A green sweep is not
  evidence that defect is gone.
- **Nothing about the postponed services**: the observability stack, litellm
  (expect F7/F8 — no Ollama on the iMac, so a model will list and not answer),
  and the 26 services not deployed at all.
- **Not a resource test.** Six light services on 3 CPU / 7.8 GiB says nothing
  about whether the full stack fits. It does not.

---

## Correction recorded deliberately

The first report of this run described `whoami`, `nginx` and `redis` as having
"no playbook". That was wrong, and Terje caught it: it conflated *"no registered
verify playbook"* with *"not tested"*. `025-setup-whoami-testpod.yml` is titled
**"Setup and Verify Whoami Test Application"** and carries 8 test tasks; nginx
carries 7.

Measuring properly produced a more useful finding than the original claim — see
[INVESTIGATE-system-verification-playbooks-usage](../backlog/INVESTIGATE-system-verification-playbooks-usage.md),
which now carries the full survey. The short version: tests are not missing, they
are on the deploy gate.
