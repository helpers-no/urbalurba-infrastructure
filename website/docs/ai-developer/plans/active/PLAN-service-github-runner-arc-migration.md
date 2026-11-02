---
title: "github-runner: migrate to Actions Runner Controller (ARC) for scale-to-zero + capacity-aware scheduling"
status: backlog
type: PLAN
area: service
severity: medium
created: 2026-10-30
---

# github-runner: migrate to Actions Runner Controller (ARC)

**Arms**: [`INVESTIGATE-service-github-runner-scale-and-scheduling`](../backlog/INVESTIGATE-service-github-runner-scale-and-scheduling.md)
**Directive**: `urb-agents#2075` — Terje, via ops: *"promote it to active and have
tor-agent solve the problem"*. Not a re-investigation; this is the design and
the build.

## Decision 1 — ARC replaces the static Deployment, for every instance

`645-setup-github-runner.yml`'s current shape (one always-on `Deployment`,
`config.sh --replace` on every container start, a short-lived registration
token minted once per `register` call) cannot scale to zero — there is no
"zero pods, wake on demand" state for a static Deployment to be in. GitHub's
own **Actions Runner Controller**, specifically the modern Helm-based
`gha-runner-scale-set` generation (not the deprecated CRD-only v1 ARC), is the
standard, supported answer and fits this cluster without new infrastructure
classes:

- **No cert-manager dependency** (that was the old v1 ARC; the current chart
  doesn't need it).
- **The listener makes outbound connections to GitHub only** — no inbound
  webhook, no public endpoint required. Matches this fleet's own stated
  network model exactly (`self-hosted-actions-runner` guide: *"the runner
  polls GitHub, so no inbound access is needed"*).
- **Authentication is the same PAT this service already requires** — a
  classic PAT with `repo` scope, or a fine-grained PAT with the
  `Administration` repository permission. No new secret, no new token type;
  `GITHUB_ACCESS_TOKEN` (the one `uis argocd register` already uses) still
  covers it.
- **Scale-to-zero is one chart value**: `minRunners: 0`. Jobs trigger ARC to
  create an ephemeral runner pod; it's torn down after.
- **Node placement is a chart value too**: `template.spec.affinity` /
  `nodeSelector` on the runner pod template — exactly the hook Ask 2 needs.

**Coexistence was considered and rejected.** Keeping the static-Deployment
mechanism alive alongside ARC for "instances that want always-on" would mean
maintaining two completely different registration architectures
indefinitely, for a benefit nobody has asked for — every existing instance
(urb-agents' own, bifrost's) is exactly the bursty, not-always-busy shape
scale-to-zero is for. One mechanism, replacing the old one outright.

**A real, favorable side effect**: ARC's listener mints JIT runner
registration tokens itself, continuously, for every ephemeral runner it
creates. The current design's documented limitation — *"a pod restart needs a
fresh `uis deploy` run with a valid PAT, because the one-hour registration
token has expired"* — goes away entirely. There is no long-lived pod to
restart; each job gets a fresh runner with a fresh token, automatically.

**A real, unfavorable tradeoff, stated plainly, not hidden**: today's design
deliberately never persists the operator's PAT — it's used once to mint a
token and discarded (`645-setup-github-runner.yml`'s own header: *"no PAT
needs to live in the cluster long-term"*). ARC's architecture cannot work that
way: the listener needs to keep minting tokens for as long as the scale set
exists, with no human in the loop, so the PAT (or GitHub App key) **must** be
stored as a persistent Kubernetes Secret. This is the cost of scale-to-zero
working unattended, not an oversight — and it is the same PAT, with the same
narrow `Administration` permission, that already exists for this purpose; the
change is in its lifetime, not its scope.

## Decision 2 — capacity-aware scheduling as a ranked, opt-in soft preference, not a hard requirement

The three test k3s nodes are identically-sized VMs regardless of the real
headroom on the hypervisor underneath — there is nothing today for a
`nodeSelector` to discriminate on, and **sizing the nodes unevenly (or adding
RAM to the test cluster) is Proxmox/platform-repo work, ops's domain, not
this repository's**. What this repo *can* ship, now, independent of that:

- A **ranked list of soft (preferred, not required) node-affinity terms**,
  `github_runner_node_preference`: a list of `{hypervisor, weight}` entries,
  defaulting to `[]`. Each entry becomes its own
  `preferredDuringSchedulingIgnoredDuringExecution` term matching
  `urbalurba.no/hypervisor In [<hypervisor>]`.
- **A ranking, not a single avoid-one-node rule, deliberately.** "Most
  powerful host" and "most free headroom right now" are not the same node:
  `urb-agents#2080` asked to prefer `tor` for its CPU, but the live
  capacity-reporting numbers in `urb-agents#2075` instead showed **frigg**
  with the most free memory (17.7GB/35% committed) and tor only mid-pack
  (10.3GB/93% committed) — `odin` is weakest on both counts. A single
  avoid/allow label can express "stay off the one tight node"; it cannot
  express "prefer frigg, then tor, over odin." The ranked list can, and stays
  re-tunable later (just reorder/reweight entries) as real headroom shifts —
  without touching this repo again.
- **Soft, not hard, deliberately**: a `requiredDuringScheduling` rule would
  leave every pod `Pending` forever if the only available node were the
  least-preferred one (or if headroom turns out to vary by job size, not by
  node) — `preferredDuringSchedulingIgnoredDuringExecution` degrades to
  "schedule anywhere" instead of refusing to run at all.
- **Inert by construction until the list is non-empty.** Default `[]`, so
  this ships with **zero behavior change** for every existing instance — the
  same "default renders byte-for-byte as before" bar this service's
  multi-instance work already met (`urb-agents#2053`/`#2032`).
- **The underlying `urbalurba.no/hypervisor` label must be declared at node
  provisioning time, not applied by hand after the cluster is already
  running.** A human running `kubectl label node` once is a one-off that a
  cluster rebuild silently loses — the next `odin-k3s-test` would come up
  unlabelled, the preference would go quietly inert again, and nothing would
  show that drift anywhere. This repo can't fix that (node provisioning is
  platform-repo work), but it ships the convention the platform repo's own
  IaC should set the label *from*: see Rollout step 1 below for the exact
  mechanism this needs, flagged precisely (`urb-agents#2081`), not left as
  "label it by hand when ready."
- Passing an empty `github_runner_node_preference` removes the affinity block
  from the rendered values entirely, for a cluster that wants no preference
  at all.

**Node sizing itself is out of scope here and flagged back to ops** (see
Rollout, below) — this ships the Kubernetes-side half only.

## What changes, concretely

### `ansible/playbooks/645-setup-github-runner.yml` — rewritten

Same operator contract (`target_host`, `github_runner_repo`,
`github_runner_pat`, `github_runner_instance`, `github_runner_force` — same
names, same validation order instance-before-API-call). Internals replaced:

1. Validate args (unchanged logic from today — repo shape, PAT presence,
   instance name shape, instance validated before anything touches the
   network).
2. `helm upgrade --install arc` — the `gha-runner-scale-set-controller` chart,
   **pinned `--version 0.15.1`**, OCI ref
   `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`,
   into a fixed `arc-systems` namespace. Idempotent and instance-independent —
   runs on every `register` call, no-ops once installed. **Never removed by
   the remove playbook** — deliberate simplification; CRD churn from
   repeated install/uninstall is a worse tradeoff than one small permanent
   controller pod.
3. Collision check, same shape as today's task 3b/3c but reading a Helm
   release instead of a Deployment: if a release named
   `{{ github_runner_resource_name }}` already exists in the `github-runner`
   namespace, `helm get values <release> -n github-runner -o json` and
   compare `githubConfigUrl` against the requested repo; refuse unless they
   match or `-e github_runner_force=true`.
4. **Detect an old-style static Deployment under the same resource name and
   warn loudly — never auto-delete it.** During migration, both the old
   Deployment and the new scale set would otherwise register two separate
   runners against the same repo (harmless, just redundant) until an operator
   removes the old one by hand. Same "ask what's there, don't silently act"
   rule the collision check itself already follows.
5. Apply/patch the PAT Secret (`{{ github_runner_resource_name }}-token`,
   key `github_token` — ARC's own convention), `no_log: true`, same as today.
6. Render a per-instance Helm values file from a new Jinja2 template
   (`645-github-runner-values.yaml.j2`) and `helm upgrade --install
   {{ github_runner_resource_name }}` the `gha-runner-scale-set` chart,
   **pinned `--version 0.15.1`**, into the shared `github-runner` namespace —
   same namespace-sharing choice as today, same isolation caveat restated
   (every instance's `dind` containerMode sidecar is still privileged).
7. Wait for the `AutoscalingRunnerSet` to report ready / the listener pod to
   come up (replaces today's "wait for pod + tail logs for 'Listening for
   Jobs'" — ARC's ephemeral runners don't exist until a job is queued, so
   this waits on the **listener**, not a runner pod).

### `645-github-runner-values.yaml.j2` (new)

Renders: `githubConfigUrl` (`https://github.com/{{ github_runner_repo }}`),
`githubConfigSecret` (the predefined-secret variant, naming the Secret from
step 5), `minRunners: 0`, `maxRunners` (new, configurable,
`github_runner_max_runners`, default small e.g. `3`),
`containerMode.type: dind` (parity with today — `kubernetes` mode, which
would drop the privileged sidecar entirely, is a real future improvement but
a separate change, not bundled into this migration), pinned runner image
(reuse the exact already-proven `ghcr.io/actions/actions-runner:2.337.0`,
not the chart's own floating default), `resources` (reuse
`github_runner_memory_request`/`_limit`, same vars, same defaults — the
`urb-agents#2032` memory fix carries forward unchanged), `scaleSetLabels`
(from `github_runner_labels`), and the optional soft node anti-affinity from
Decision 2.

### `ansible/playbooks/645-remove-github-runner.yml` — rewritten

`helm uninstall {{ github_runner_resource_name }} -n github-runner`, then the
Secret if `helm uninstall` doesn't already remove it. Namespace-deletion logic
unchanged in spirit: delete the `github-runner` namespace only if no
`AutoscalingRunnerSet` remains in it. The `arc-systems` controller is never
touched here (Decision 1).

### `provision-host/uis/manage/uis-cli.sh` — `cmd_github_runner_list` only

Today's `list` greps Deployments for a `GITHUB_RUNNER_REPO` env var that no
longer exists once an instance is ARC-backed. Rewritten to `kubectl get
autoscalingrunnersets -n github-runner -o jsonpath=...`, reading
`.spec.githubConfigUrl` per resource instead. `register`/`remove` are
unchanged — same flags, same validation, same playbooks invoked, only the
playbooks' own internals differ.

### Docs

`website/docs/services/management/github-runner.md`'s `## Configuration`
section gets the ARC architecture explained plainly (what changed, why the
PAT now persists, the soft-affinity convention and how to activate it), and a
note that `maxRunners` is configurable the same way `github_runner_memory_limit`
already is.

## What this does NOT do

- Does not touch node sizing. Flagged to ops as the companion action (see
  Rollout).
- Does not adopt ARC's `kubernetes` containerMode (drops the privileged dind
  sidecar) — real future improvement, deliberately not bundled here to keep
  this change to the two asks actually in scope.
- Does not migrate GitHub App authentication — PAT stays the auth method,
  matching every other GitHub-integrated UIS service.

## Verification (here, no live cluster)

- `ansible-playbook --syntax-check` on both rewritten playbooks.
- Jinja2 render test for the new values template: default instance renders
  with no `instance` scaleSetLabel and no affinity block (label key/value
  empty by default triggers the "omit entirely" branch — confirm this via an
  explicit empty-string case, not just the documented-default case); a named
  instance renders `maxRunners`/resources/labels correctly; the default
  anti-affinity convention renders when the key/value are left at their
  non-empty defaults.
- `provision-host/uis/tests/run-tests.sh static unit` at 100%, including the
  rewritten CLI list test and the new Jinja2 cases. Mutation-test every new
  assertion.
- `website`: `npm run build` clean.
- **Cannot verify here**: that `helm upgrade --install` of either chart
  actually succeeds against a real cluster, that the listener actually
  connects and an ephemeral runner actually runs a real job, or that the
  migration runbook below is safe to execute against the two **live**
  registrations (urb-agents' own, bifrost's). Flagged honestly, same as every
  other UIS change this session that touches a live service.

## Rollout — ops's half, not self-executed here

1. **Node sizing (ops/Terje, Proxmox side) — the primary, lead fix, not an
   afterthought.** Size the test k3s VMs unevenly to actually reflect real
   hypervisor headroom (ops's own capacity-reporting numbers already say how:
   odin tight, frigg roomy), rather than leaving all three identically sized
   regardless of the host underneath. This is the more durable fix because
   Kubernetes' **default scheduler already does live, dynamic bin-packing** —
   at every scheduling decision it compares each node's actual remaining
   allocatable memory against what's already running there and favors the
   less-loaded one, automatically, for every workload on the cluster, not
   just this one service. It only fails to help today because there's
   nothing real for it to compare (identically-sized VMs). Fix the sizing and
   the default scheduler starts solving this on its own, continuously, with
   no custom affinity config to maintain. **Caveat, stated plainly**: this is
   dynamic *within* each VM's fixed ceiling, not infinitely dynamic — if a
   host's real contention changes later (e.g. another CT lands on odin), the
   VM's advertised capacity doesn't auto-shrink; a human still has to notice
   and resize it again. While sizing this, also worth a look: on `odin`
   specifically, the production node (`odin-k3s`, 3072MB alloc) is sized
   *smaller* than its own test node (`odin-k3s-test`, 4096MB alloc) on the
   same host — backwards from "production gets priority for resources,"
   though `odin-k3s-test` is also currently using more memory right now
   (1616MB vs 948MB), so this may reflect real current load rather than pure
   misconfiguration. Ops's/Terje's call, not assumed here as a bug.
2. **Node labeling (ops, Proxmox/platform side) — a cheap, complementary
   layer, declared in IaC, not run by hand.** Decision 2's ranked
   `urbalurba.no/hypervisor` preference costs nothing while unconfigured, and
   adds one thing VM memory sizing alone can't express: **CPU strength is a
   separate axis from memory headroom** — a host could in principle have fine
   memory and a weak CPU, and bursty CI builds (yarn install + docker-in-
   docker) care about both. Worth keeping even once sizing is fixed, not a
   substitute for it. `platform` (terchris/home) already has the right
   convention for this: each k3s VM is declared in its own
   `ansible/vars/vms/<host>-k3s[-test].yml` (vmid, cores, memory, ip, a
   `k3s:` dict), consumed by `ansible/playbooks/k3s-ensure.yml` →
   `ansible/roles/k3s/`. Today that role passes no `--node-label` to the k3s
   install command, and the *only* existing labeling path is
   `platform/how-to-add-k3s-node.md`'s manual, human-run `kubectl label node
   ... --overwrite` — exactly the non-reproducible pattern to avoid here, not
   a template to follow. The fix: add an optional `k3s.labels` (or
   `node_labels`) key to **every** `vars/vms/<host>-k3s[-test].yml` (e.g.
   `urbalurba.no/hypervisor: odin` / `tor` / `frigg` — one value per physical
   host, on both its prod and test node), read it into
   `roles/k3s/defaults/main.yml` as `k3s_node_labels`, and append a
   `--node-label` argument where the role already builds other optional
   server args (`roles/k3s/tasks/main.yml`). Once declared this way, every
   rebuild of that node reproduces the label automatically — no human step,
   no drift, no silent loss of the preference on a rebuild. Until this lands,
   Decision 2's affinity preference is inert everywhere — safe to ship code
   ahead of this step, and independent of whether/when sizing (above) lands.
3. **Migrate each existing instance, one at a time, live**: re-run `./uis
   github-runner register <instance> <repo>` for urb-agents' own (default)
   instance and for bifrost's — this installs the ARC controller (first call
   only) and the new per-instance scale set, side by side with the old static
   Deployment. The new playbook's step 4 will warn that an old-style
   Deployment exists under the same name; ops then removes it by hand
   (`kubectl delete deployment/secret -n github-runner <name>
   <name>-token`) once the new runner is confirmed listening — never
   automated, by design.
4. **Verify**: a real `workflow_dispatch` against each migrated repo,
   confirming an ephemeral runner pod appears, runs the job, and disappears
   (`minRunners: 0` actually scaling to zero afterward) — ops's test, per
   this fleet's build/verify split.

## Related

- [`INVESTIGATE-service-github-runner-scale-and-scheduling`](../backlog/INVESTIGATE-service-github-runner-scale-and-scheduling.md)
- `urb-agents#2073`, `#2075`
- `urb-agents#2067`, `#2071`, `#2072` — the live debugging that prompted this
