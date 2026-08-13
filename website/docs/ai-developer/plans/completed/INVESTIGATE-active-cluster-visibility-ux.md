# Investigate: cluster visibility + switching across the UIS shell and commands

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — design questions locked 2026-05-11, ready for child PLAN(s)

**Last Updated**: 2026-05-11 — Q1/Q2/Q3/Q4/Q5 decisions locked after talk47 cycle. First gap-sweep settled implementation contracts (status.sh API for `list` consumption, external-context handling, env-file naming convention, banner ownership, performance budget). Second gap-sweep added the C-1 state-machine discriminator + rancher-desktop reinterpretation, renamed flags from `--probe`/`--no-probe` to `--deep`/`--offline` (the two probes are now unambiguous), and added C-9 spelling out that Layer 1's banner is a direct probe (not a `status.sh` consumer). Third gap-sweep unified `use --offline` with `list --offline` (single flag name), dropped `cluster-config.sh` from the `use` success output, specified banner output goes to stderr, fixed banner-format consistency (success one-liner, failure block), added the "no active context" hint pointing at rancher-desktop, and pinned the `use` / `list` consumption flow to `status.sh --summary`. **Layer 4 (`./uis platform list / use`) ships bundled with Layer 1 (per-command banner)** — switching without per-command visibility would leave the same gap talk47 surfaced. Inventory source: `platforms/*/scripts/init.sh` directory listing — see Q3 below.

**Source**: Tester's UX proposal in `testing/uis1/talk/UX-active-cluster-visibility.md` (2026-05-09). Originally triggered by the AKS Tier A verification rounds, where stale kubectl contexts produced silent failures — operators couldn't tell from prompt or command output that they were acting against a dead/wrong cluster.

**Scope expansion 2026-05-10**: this investigation originally covered only *visibility* (banner, PS1, status header). When the AKS novice-onboarding investigation ([INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md)) proposed `./uis platform up azure-aks` as a wrapper that ships clusters in 5 commands, "I now have rancher-desktop and azure-aks both running, how do I switch?" became the load-bearing follow-up. Switching folds in here because it shares the same source-of-truth question (Q1) and the same reachability-probe building block as the visibility layers; splitting the two would risk the investigations picking different definitions of "the active cluster".

---

## Problem Summary

Today there is **no signal** in the UIS shell or in `./uis` command output that tells the user which cluster the next destructive command will hit:

- The container prompt is `ansible@lima-rancher-desktop:/mnt/urbalurbadisk$` — that's the **lima VM hostname**, not the Kubernetes cluster. Identical whether kubeconfig points at Rancher Desktop, AKS, or a deleted context.
- `./uis deploy …`, `./uis expose …`, `./uis configure …` print colour-banner output (`[INFO]`, `[SUCCESS]`) that doesn't include the target cluster.
- `cluster-config.sh` (`TARGET_HOST` / `CLUSTER_TYPE`) and `kubectl current-context` can drift apart silently — and both being wrong-but-self-consistent is also possible.

**Blast radius**: whatever cluster `kubectl` happens to be pointed at. A wrong context can produce a destructive operation against the wrong cluster with no signal in the workflow to catch it.

### Concrete recent incidents this would have prevented

- **Tier A retry №3 silent false positive** (PR #149 testing) — tester's `./uis deploy nginx` ran a phantom replay against rancher-desktop's existing release while the brand-new AKS cluster sat empty. Both the playbook output and the helm chain reported "success". A cluster-banner at the top of `./uis deploy` would have shown `kube_context = rancher-desktop` (not `azure-aks`) and the tester would have caught it before declaring the round green.
- **Stale port-forward after AKS destroy** (talk41 round) — `kubeconf-all`'s `current-context` still pointed at the destroyed cluster after `03-destroy.sh`. `./uis expose postgresql` happily reported `[SUCCESS]` while `kubectl port-forward` zombied behind the scenes. **Partially mitigated** by `03-destroy.sh`'s kubeconfig-context-delete + cluster-config.sh-reset added in PR #149 (lines 171–199), but a Layer 1 reachability probe would still catch any divergence introduced manually between flips.
- **talk47 R7 final state observation** — even with `03-destroy.sh`'s cleanup, the operator coming back to UIS the next day has *no* command that answers "what platforms do I have here, and which one is the next `./uis deploy` going to target?" without `cat`-ing config files by hand. This investigation's Layer 4 (`list / use`) is the answer.
- **Earlier multi-cluster confusion incidents** — talk37 (postgres purge) and talk23-ish (backstage 401 verify) both involved "where is this command actually going" ambiguity.

### The switching gap (added 2026-05-10)

Beyond visibility, there's no first-class way to *change* the active cluster from inside UIS:

- **No inventory.** "Which clusters do I have?" requires reading `kubectl config get-contexts` + `.uis.secrets/cloud-accounts/*.env` + `cluster-config.sh` history by hand and reconciling them mentally.
- **No switch verb.** Moving from rancher-desktop to azure-aks today means `kubectl config use-context azure-aks` (which doesn't flip cluster-config.sh's `TARGET_HOST`), plus a manual edit of cluster-config.sh to match. The two halves of "the active cluster" drift every time someone forgets the second step.
- **No reachability gate on switch.** Switching to a destroyed cluster's stale context "succeeds" silently until the next `kubectl` call times out — same failure mode as the talk41 stale-port-forward incident, just triggered earlier.

The platform wrappers ([INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md)) make this gap concrete: once `./uis platform up azure-aks` lands, every novice has 2+ clusters within their first session and immediately needs `list` + `use`.

---

## Design questions to settle

### Q1 — What is "the active cluster"?

Two candidates:

- `cluster-config.sh`'s `TARGET_HOST` — what UIS *thinks* it's targeting (Ansible inventory hint, sourced by service-deployment scripts).
- `kubectl current-context` — what `kubectl` / `helm` actually talks to.

The truth is **both must agree**, and divergence between them is its own class of bug worth surfacing (the Tier A rounds had this exact divergence).

**Decision (2026-05-11)**: `kubectl current-context` is **truth for reads** — every consumer that needs to know "where am I" reads it. `cluster-config.sh.TARGET_HOST` becomes a **cached projection** that's written by `use` (Q4) in lockstep with the kubectl context, and never read independently for "which cluster?" decisions. The two-source class of bug disappears because the only writer is `use`, which keeps them aligned by construction. (Ansible playbooks that today read `TARGET_HOST` from cluster-config keep doing so — they're reading the cached projection, not making an independent decision.)

### Q2 — Where should the signal live?

- **Container prompt (PS1)** — visible all the time, no per-command cost. Catches "what am I about to do" before commands run.
- **Per-`./uis` command output** — visible per command, including from outside the shell. Makes logs/screenshots self-describing.
- **Both** — they serve different audiences. Both are cheap.

**Decision (2026-05-11)**: **per-command banner (Layer 1) is a hard co-ship with Layer 4**, not deferred. The rule: *every `./uis` command that operates on a cluster must display which platform it's targeting before doing anything else*. Without this, Layer 4's `use` would let you switch platforms but the next `./uis deploy` would give no signal of where it's heading — recreating the exact "where does this go?" gap that talk47 surfaced.

Banner applies to all cluster-touching commands: `./uis deploy`, `./uis undeploy`, `./uis configure`, `./uis expose`, `./uis status`, `./uis list`, `./uis stack install`, `./uis test-all`, *and* `./uis platform up / down / status / use`. Excluded: purely-informational commands that touch no cluster (`./uis help`, `./uis version`, `./uis container`, `./uis pull`, `./uis build`).

PS1 (Layer 2) stays deferred — it only helps in-shell users, and the per-command banner already covers them too.

### Q3 — What's in the cluster inventory?

`./uis platform list` (Layer 4 below) needs to enumerate available clusters from somewhere. Three candidate sources, each with different drift modes:

- **Kubeconfig contexts** (`kubectl config get-contexts`). Authoritative for "what `kubectl` can connect to". Drift mode: accumulates stale entries from destroyed clusters — *partially mitigated* by `03-destroy.sh`'s `delete-context` (PR #149), but only for clusters torn down via UIS.
- **`.uis.secrets/cloud-accounts/*.env` files**. Tells you "what UIS has been told about" via the wizard, survives `down`. Drift mode: shows nothing about platforms the user hasn't yet initialized.
- **`cluster-config.sh` history**. Only knows about the *last* cluster UIS touched, not the full set.

**Decision (2026-05-11) — narrowed from "union of three" to a single source: `platforms/*/scripts/init.sh` directory listing**. Reasoning:

- The user's framing (talk47 discussion) is **"potential platforms and their status"** — not "currently-reachable clusters" and not "configured clusters". So the inventory is *every platform UIS knows how to onboard you to*, regardless of whether you've started it. A platform exists in `./uis platform list` from the moment its `init.sh` is added to the repo.
- Inventory is the directory listing — bulletproof, no drift, no central registry to maintain. When `google-gke`, `aws-eks`, or `azure-microk8s` ships, it appears in `list` automatically.
- **rancher-desktop is the one special case** — it has no `init.sh` because Rancher Desktop is installed at the OS level, not via UIS. Hard-coded as an always-present row.
- **Per-row status comes from each platform's own `status.sh`**, not from a central inventory module. Today only `azure-aks/scripts/status.sh` exists; rancher-desktop needs a trivial `status.sh` added (kubeconfig-context-present-and-reachable check). Each platform owns its own status reporting.
- Kubeconfig and cloud-accounts files are *status inputs*, not inventory sources. `status.sh` reads them to decide which of {not initialized / configured but not running / running / unreachable} to report.

What `list` displays in the post-talk47 world (one initialized platform, rancher-desktop as default, three future platforms not yet in `platforms/`):

```
$ ./uis platform list

Active: rancher-desktop

PLATFORM         STATUS
rancher-desktop  ✓ running
azure-aks        · configured, not running   (run './uis platform up azure-aks' to start it)
```

If `azure-aks` is up:

```
PLATFORM         STATUS
rancher-desktop  ✓ running
azure-aks        ✓ running                   (active)
```

If the user never ran `init`:

```
PLATFORM         STATUS
rancher-desktop  ✓ running                   (active)
azure-aks        · not initialized           (run './uis platform init azure-aks' to set up)
```

Future platforms (`google-gke`, `aws-eks`, `azure-microk8s`) appear automatically once their `platforms/<name>/scripts/init.sh` lands. No table-update work needed.

### Q4 — How does `use` write the active cluster?

Switching means flipping both `kubectl current-context` and `cluster-config.sh`'s `TARGET_HOST` so they agree. Three options:

- **(a) Lockstep flip.** Concrete and explicit; adds a write path to `cluster-config.sh` that today only `02-post-apply.sh` and `03-destroy.sh` touch (via `sed -i`).
- **(b) Flip kubectl context only; treat `cluster-config.sh` as derived.** Regenerate `TARGET_HOST` from the new context's name on every read. Simpler invariant but requires that context names map cleanly to UIS cluster types — true today (`rancher-desktop`, `azure-aks`) but fragile if someone renames a context.
- **(c) Flip kubectl context, then warn if `cluster-config.sh` disagrees** — leaving the user to decide. Punts the problem and breaks Q1's "both must agree" invariant.

**Decision (2026-05-11)**: **(a) lockstep flip**. Concretely:

- `./uis platform use <name>` writes both `kubectl current-context` (via `kubectl config use-context`) AND `cluster-config.sh.{CLUSTER_TYPE,TARGET_HOST}` (via the same `sed -i` pattern that `02-post-apply.sh` and `03-destroy.sh` already use).
- `02-post-apply.sh`'s auto-flip-on-up and `03-destroy.sh`'s auto-reset-on-destroy *also* go through this same shared writer once `use` exists — the three call sites converge on one function in `provision-host/uis/lib/platform-switching.sh` so the write logic lives in one place.
- `cluster-config.sh` becomes a **cached projection** that is *always written by `use`* and *never read independently* for "active cluster" decisions. Ansible playbooks that today read `TARGET_HOST` are reading the cached projection, not making their own decision — by construction it agrees with kubectl.

### Q5 — What's the switch verb?

`./uis platform use <name>` (kubectl-style, fast, no reachability check) vs `./uis platform switch <name>` (with reachability probe + lockstep flip)? Or just one verb with both behaviours?

**Decision (2026-05-11)**: one verb, `./uis platform use <name>`, with **refuse-unless-initialized-and-reachable** by default. The state-machine call: `use <name>` invokes `<name>'s status.sh --summary` (the C-1 contract), parses field 1, and dispatches on the enum:

- **`not-initialized`** — refuse with pointer at `./uis platform init <name>`. (`--offline` cannot override this — there's no platform to switch *to*.)
- **`configured-not-running`** — refuse with pointer at `./uis platform up <name>`. The inverse of `init` — you can't `use` a platform that isn't actually running. (`--offline` cannot override this either; the kubectl context doesn't even exist in kubeconf-all yet.)
- **`running`** — lockstep flip (Q4), success banner showing the transition.
- **`unreachable`** — refuse with pointer at `./uis platform status <name>` + recovery hint. **`--offline` overrides this case only** — switches anyway, for the "I know it's broken, I want to inspect / clean up" workflow.
- **No-op + reachability re-probe** if you `use` the already-active platform — useful as an "is my cluster still up?" check. If the re-probe fails, emit `✗ <name> is no longer reachable` + recovery hint, exit non-zero; the active platform doesn't change (it was already the target).

For **rancher-desktop** specifically, only 3 of the 4 cases fire per C-1's rancher-desktop subsection — `configured-not-running` never applies (Rancher Desktop is installed at the OS level, not provisioned by UIS).

Flag name `--offline` (not `--no-probe`) is intentional — it matches `list --offline`. Both flags mean "skip the kubectl reachability probe"; the operational difference is the consumer (`list` shows all platforms optimistically vs. `use` switches to *one* platform optimistically). Same underlying mechanic, same flag name.

Verb name `use` matches `kubectl config use-context` in feel and `./uis platform up/down/init/status/use` keeps the family consistent.

---

## Implementation contracts (settled 2026-05-11)

Decisions on the shapes the child PLAN must respect. Pulled out of "implementation deferred" because each of these has at least one consumer (`list`, `use`, banner) that can't be designed without them.

### C-1 — `status.sh --summary` contract

Each platform's `platforms/<name>/scripts/status.sh` gains a `--summary` flag. Without the flag it keeps emitting today's human-readable multi-line banner (azure-aks already does this, unchanged). With the flag it emits **exactly one line** to stdout, tab-separated:

```
<state>\t<one-line-hint>
```

Where `<state>` is one of a fixed enum:

| State | Meaning | Example second-field hint |
|---|---|---|
| `not-initialized` | No env file or equivalent setup; UIS has never been told about this platform | `run './uis platform init azure-aks' to set up` |
| `configured-not-running` | Initialized (env file present) but no cluster is currently provisioned | `run './uis platform up azure-aks' to start it` |
| `running` | Cluster is provisioned and reachable | `1× Standard_B2s_v2 in westeurope, k8s 1.34` |
| `unreachable` | Cluster expected up (kubectl context exists in kubeconf-all) but the API server is unreachable | `API server timeout after 3s; run './uis platform status azure-aks' for details` |

#### State-machine discriminator

Two signals fully determine the state for a cloud-managed platform — no other inputs needed:

1. **Env file presence** at the cloud's path (per C-3): `.uis.secrets/cloud-accounts/<cloud>-default.env`
2. **kubectl context presence** in `kubeconf-all` (matching the platform directory name per C-5)
3. **Reachability probe** (only when both above are present): `kubectl --context <name> --request-timeout=3s get --raw /version`

The mapping:

| Env file | kubectl context in kubeconf-all | Reachability probe | State |
|---|---|---|---|
| absent | — | — | `not-initialized` |
| present | absent | — | `configured-not-running` |
| present | present | succeeds | `running` |
| present | present | fails | `unreachable` |

This works because `02-post-apply.sh` adds the kubectl context to `kubeconf-all` only when the cluster is actually provisioned, and `03-destroy.sh` removes it on tear-down. So *kubectl-context-in-kubeconf-all* is a reliable proxy for "cluster was successfully provisioned" — without it we couldn't distinguish "configured but not yet up" from "configured and running but currently broken".

#### Rancher-desktop is special

Rancher Desktop is installed at the OS level, not by UIS, so it has no env file (C-3). Its `status.sh --summary` uses **3 of the 4 states** with `not-initialized` reinterpreted:

| kubectl context `rancher-desktop` in kubeconf-all | Reachability probe | State for rancher-desktop |
|---|---|---|
| absent | — | `not-initialized` — semantically "Rancher Desktop not installed or never started"; hint: `install Rancher Desktop and start it, then './uis start'` |
| present | succeeds | `running` |
| present | fails | `unreachable` — Rancher Desktop is installed but not currently running; hint: `start Rancher Desktop` |

`configured-not-running` doesn't apply to rancher-desktop (there's nothing UIS can "configure" — installation is the user's OS step).

#### Cross-context kubectl invocation

When `azure-aks/scripts/status.sh --summary` runs while the operator is currently on the rancher-desktop context, the probe MUST explicitly target the platform's own context: `kubectl --context azure-aks --request-timeout=3s get --raw /version`. Bare `kubectl` would probe the active context (rancher-desktop), giving wrong-cluster answers — exact F12 from talk46. Each platform's status.sh hard-codes `--context <its own platform name>`.

#### Output, exit codes, performance

`list` parses field 1 to pick the row's visual treatment (✓ / · / ✗), prints field 2 verbatim as the right-hand hint. Exit code: 0 in all four states (`--summary` is a state report, not a check; the state itself encodes "healthy or not"). Non-zero exit only if the script itself errors (missing tools, malformed env file, etc.) — in which case `list` shows `? error` for that row and the user runs the script bare for the full diagnostic.

`--summary` MUST be fast (target: under 200 ms). It reads local files (env file presence, kubectl context list) and at most does one short-timeout kubectl probe against the platform's own context. **It does NOT call cloud APIs** (`az aks show`, `gcloud container clusters describe`, etc.) — those go in the no-flag deep-status path. This bounds `list`'s total time to ~200 ms × N-platforms / parallelism.

A `status.sh --summary --deep` variant additionally runs cloud-API calls for richer status (cluster age, node-pool details, cost estimate), invoked by `list --deep` (see C-7). Default `list` skips it.

### C-2 — Active platform when kubectl points outside `platforms/`

Possible states of kubectl current-context vs the platforms inventory:

| kubectl current-context state | `Active:` header in `list` | `(active)` row annotation |
|---|---|---|
| Matches one of the listed platforms | `Active: <name>` | Yes, on that row |
| Matches a context not in `platforms/` (e.g. user's personal `prod-cluster`) | `Active: <name> (not a UIS platform — use './uis platform use <name>' to switch to one)` | No row gets it |
| Unset / empty | `Active: (none — run './uis platform use <name>' to pick one)` | No row gets it |

`list` does not surface non-UIS contexts as rows (Q3 — inventory is `platforms/*/scripts/init.sh`, not kubeconfig). It only acknowledges them in the `Active:` header so the user isn't confused when no row says `(active)`.

### C-3 — Env-file naming convention (per-cloud, not per-platform)

`.uis.secrets/cloud-accounts/<cloud>-default.env` files are **per-cloud**, not per-platform. One file serves every platform on that cloud. So:

| File | Serves |
|---|---|
| `azure-default.env` | `azure-aks`, `azure-microk8s` (the latter when it lands) |
| `google-default.env` | `google-gke` (and any future `google-*` platforms) |
| `aws-default.env` | `aws-eks` (and any future `aws-*` platforms) |

Reasoning: identity (tenant/subscription/region) is cloud-scoped, not platform-scoped. The wizard for `azure-microk8s` would re-use the same `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` the AKS wizard wrote. Forcing a separate `azure-aks-default.env` and `azure-microk8s-default.env` would either duplicate identity values or require the user to pick which one to write.

Per-platform overrides (e.g. `AZURE_AKS_NODE_SIZE`, `AZURE_AKS_CLUSTER_NAME`) sit inside the same file as commented optional overrides — the existing AKS pattern, extended cloud-wide when new platforms ship. `rancher-desktop` doesn't have an env file (it's installed at the OS level, not by UIS).

`status.sh --summary` for each platform reads its cloud's env file by hard-coded path: `azure-aks/scripts/status.sh` reads `azure-default.env`, `google-gke/scripts/status.sh` reads `google-default.env`. The mapping is platform-internal, not centrally registered.

### C-4 — Banner ownership: dispatcher prints, playbooks never

The Layer 1 banner is emitted **exactly once per `./uis` invocation**, by the dispatcher layer (`uis-cli.sh`'s `cmd_<verb>` function), before delegating to anything else. Ansible playbooks, helm chains, and sub-shell scripts the dispatcher invokes never emit their own banner — they inherit it by virtue of running underneath the parent invocation.

This sidesteps the `UIS_BANNER_PRINTED=1` env-var propagation question: there's no inheritance needed because the banner is a dispatcher-layer concern, not a playbook-layer concern. The playbooks keep emitting their own `[INFO]` / `[SUCCESS]` / per-task output — different signal, different layer.

`./uis stack install` (which fans out to multiple `./uis deploy <service>` calls) is the one exception: it'd want a single banner at the parent invocation, then *suppress* the per-deploy banners that follow. Implementation: the parent sets `UIS_BANNER_PRINTED=1` in its environment before invoking children; child dispatchers check it and skip. This is the only place the env var is needed.

### C-5 — Convention: platform directory name == kubectl context name

`./uis platform use azure-aks` assumes the kubectl context named `azure-aks` exists in `kubeconf-all`. This is true today (`02-post-apply.sh` writes `kubeconf-all` with context name = `${AZURE_AKS_CLUSTER_NAME:-azure-aks}` = the platform directory name). The convention is: **each platform's `init.sh` / lifecycle scripts MUST write a kubectl context whose name equals the platform's directory name under `platforms/`**.

Future platforms that need to deviate (e.g. multi-cluster setups where one platform spawns several contexts) get a separate design conversation. For the current 5-platform horizon, the convention holds.

### C-6 — `list` performance budget + the three list modes

There are two distinct "probes" in this design and the flag names must keep them straight:

- **kubectl reachability probe** — cheap (~200 ms), in-cluster, runs by default. Fires the C-1 state machine's reachability check.
- **cloud-API deep check** — expensive (~2-5 s), hits Azure/GCP/AWS APIs, off by default. Fetches rich status (cluster age, node-pool details, cost).

Three `list` modes flow from this:

| Command | kubectl probe? | Cloud-API check? | Target time | When to use |
|---|---|---|---|---|
| `list` (default) | yes | no | ~500 ms | normal case |
| `list --offline` | no | no | under 100 ms | offline / "just show me the inventory, don't connect" |
| `list --deep` | yes | yes | 2-5 s typical | "give me everything"; platform-dependent |

The same `--offline` flag is honored by `./uis platform use` per Q5 — both consumers skip the reachability probe under that flag. `--deep` is `list`-only (it'd be wasted on `use`, which only cares about one platform's reachability).

**Performance target for the default `list`**: under 500 ms with up to 8 platforms.

Achieved by:
- Each `status.sh --summary` call is under 200 ms (no cloud-API calls — see C-1)
- `list` invokes them in parallel (one background process per platform, `wait`, collect outputs)
- Total time ≈ max-single-status-summary-time + a small parallel-coordination overhead

### C-7 — `list --offline` semantics

`list --offline` skips the kubectl reachability probe entirely. Each platform's row state is decided by the C-1 discriminator's first two columns only (env file presence + kubectl context presence in kubeconf-all). State outcomes change:

| Env file | kubectl context | State under `--offline` |
|---|---|---|
| absent | — | `not-initialized` |
| present | absent | `configured-not-running` |
| present | present | `running` (assumed — we don't actually check) |

The `unreachable` state never fires under `--offline`. The trade-off is explicit: when the user adds the flag, they accept "I'll find out later if these clusters are actually up". Useful when the user is offline, knows the clusters are up, or just wants the inventory list fast for a script.

Internally, `--offline` is propagated to each platform's `status.sh --summary --offline` so each script can short-circuit its own probe.

### C-8 — `use` interactive picker

`./uis platform use` with no argument prints the same table `list` shows, but **only the rows in state `running` get numbered `[N]` selectors**. Other rows appear in the table without selectors, with their inline pointer (e.g. `run './uis platform up azure-aks' to start it`) visible — no dimming, no ANSI tricks, just absence of the `[N]`. A footer line tells the user how to make unreachable rows selectable. Implementation: plain numbered `read -p` prompt. No `fzf` dependency.

Example with one running platform + one configured-but-not-running platform:

```
$ ./uis platform use

PLATFORM             STATUS
[1] rancher-desktop  ✓ running                   (currently active)
    azure-aks        · configured, not running   (run './uis platform up azure-aks' to start it)

Pick a platform [1-1]: 1
ℹ  Already active: rancher-desktop. Re-probing... ✓ still reachable.
```

### C-9 — Layer 1 banner: probe model, output stream, format

Layer 1's banner asks a different question from `list`'s rows. `list` enumerates platforms and renders per-row status; the banner names the *currently active* one and confirms it's reachable, before whatever command the user just typed runs.

**Probe model**: in the common case (active context reachable), Layer 1 directly reads `kubectl current-context` and runs the cheap reachability probe — does NOT route through `status.sh --summary`. That would be one indirection too many for a per-command banner that fires ~50 times in a typical session. **Only in the unreachable case** does the banner call `<active-platform>'s status.sh --summary` to pull the platform-specific recovery hint (cost: one extra ~200 ms call, only on the rare error path).

The shared primitive both Layer 1 and `status.sh --summary` use lives in `provision-host/uis/lib/platform-switching.sh`:

```bash
pf_probe_reachable <context>   # 0 if reachable, non-zero otherwise; timeout 3s
```

Both consumers call this same function. Layer 1 wraps it to print the banner; `status.sh --summary` wraps it to decide the C-1 state.

**Output stream**: banner writes to **stderr**, not stdout. Users piping `./uis deploy <service> > log.txt` (or `| grep ...`) get the data on stdout and the banner stays visible in their terminal. Matches Unix convention for status/diagnostic output.

**Format by case** (success cases one-liner, fail cases multi-line block with recovery — deliberate asymmetry: success doesn't need instructions, failure does):

| Active context state | Banner |
|---|---|
| In `platforms/` AND reachable | one-liner: `ℹ  Platform: azure-aks (reachable)` |
| In `platforms/` BUT unreachable | multi-line block: `✗ Platform: <name>, but the API server is unreachable.` + recovery hint from `<name>'s status.sh --summary` field 2 + abort |
| Not in `platforms/` (e.g. user's personal context) | one-liner: `⚠  Platform: <name> (not a UIS platform — proceeding with kubectl context anyway)` |
| Unset | multi-line block: `⚠  No active kubectl context set.` + `Run './uis platform use rancher-desktop' (the default) or './uis platform list' to see what you have.` + abort |

For the unset case, the hint specifically names `rancher-desktop` because it's the always-present default (per Q3) — a fresh-from-zero user with no Azure setup yet can recover by switching to rancher-desktop without needing to first run `init`.

Divergence between kubectl context and `cluster-config.sh` is **not** a banner case — post-lockstep it's impossible by construction, and surfacing `cluster-config.sh` (an internal cached projection) to the user would leak implementation. The banner targets only the kubectl context (Q1's truth).

---

## Layered design sketch

### Layer 1 — `./uis` output banner (co-ships with Layer 4)

Every `./uis` subcommand that touches a cluster prints a one-line banner before its first action. Per C-9, the banner is driven by kubectl current-context + the cheap reachability probe — it does NOT route through `status.sh --summary`. Four cases per C-9; the most common two:

Active and reachable:

```
ℹ  Platform: rancher-desktop  (reachable)
```

Active but API server unreachable (talk41 case):

```
✗  Platform: azure-aks, but the API server is unreachable.
   Likely the cluster was destroyed or stopped.
   Recover with: ./uis platform status azure-aks
   Or switch:    ./uis platform use rancher-desktop  (or another reachable platform)
   Aborting.
```

The remaining two cases (active context isn't a UIS platform / no active context) are in C-9. Divergence between kubectl context and `cluster-config.sh` is **not** a banner case — post-lockstep it's impossible by construction, and surfacing `cluster-config.sh` (an internal cached projection) to the user would just leak implementation.

**Implementation shape**: shared primitive in `provision-host/uis/lib/platform-switching.sh` (`pf_probe_reachable <context>`). Same primitive used by `status.sh --summary` per C-1.

**Touches**: every cluster-touching command from Q2 — `./uis deploy`, `./uis undeploy`, `./uis configure`, `./uis expose`, `./uis status`, `./uis list`, `./uis stack install`, `./uis test-all`, plus the `./uis platform` family (`up`, `down`, `status`, `use`). Skip purely informational commands (`./uis help`, `./uis version`, `./uis container`, `./uis pull`, `./uis build`).

### Layer 2 — coloured PS1 inside `./uis shell`

Modify the container's bashrc so PS1 includes a platform tag:

```
[rancher-desktop] ansible@uis:/mnt/urbalurbadisk$
```

Colour by sensitivity:

| Platform type | Colour | Why |
|---|---|---|
| `rancher-desktop` (or anything tagged "local" in platform types) | green | safe sandbox |
| `azure-aks`, `aws-eks`, `google-gke`, `azure-microk8s` (sandbox tier) | yellow | cloud, real cost, but disposable |
| Anything explicitly tagged `production` in cluster-config.sh | red, with the word `PROD` | maximum visibility |

Driven by kubectl current-context (Q1's source of truth). Re-evaluated on each prompt; switches mid-session update immediately.

While we're touching the prompt: replace the misleading `lima-rancher-desktop` hostname (`\h` shows the lima VM, not the cluster). Either drop `\h` or substitute a fixed `uis` literal.

### Layer 3 — `./uis status` should make this its first line

Today's `./uis status` shows deployed services. The header should be:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UIS Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Platform:   rancher-desktop  (reachable, k8s v1.32.0)
Namespace:  default

Deployed services:
  …

Other platforms: 'uis platform list'
```

Makes "where am I" the first thing the operator sees on the standard "what's going on" command. Drops the separate `Context:` / `Config:` lines from the original sketch — post-lockstep (Q4) they're always in sync, so surfacing them as separate values is just noise. The footer pointer links to `list` for users who want to see the full inventory.

### Layer 4 — `./uis platform list / use` (the agreed first-ship)

Two new commands, parallel to `./uis platform up/down/init/status` from the AKS novice-onboarding investigation.

**`./uis platform list`** — enumerate every platform UIS knows how to onboard, plus rancher-desktop, with current status per row:

```
$ ./uis platform list

Active: rancher-desktop

PLATFORM         STATUS
rancher-desktop  ✓ running                   (active)
azure-aks        · configured, not running   (run './uis platform up azure-aks' to start it)
```

Inventory source per Q3: `platforms/*/scripts/init.sh` directory listing + hard-coded rancher-desktop row. Status per row comes from each platform's own `status.sh` (rancher-desktop gets a trivial one added). Reachability probes run in parallel for fast `list`.

State-to-display mapping:

| Platform state | Row status |
|---|---|
| No `init.sh` for this name, not rancher-desktop | (not listed — UIS can't onboard you) |
| `init.sh` exists, no env file | `· not initialized` + pointer to `./uis platform init <name>` |
| Env file exists, cluster not provisioned | `· configured, not running` + pointer to `./uis platform up <name>` |
| Cluster running, reachable | `✓ running` (with `(active)` annotation if it matches kubectl current-context) |
| Cluster expected running but unreachable | `✗ unreachable` + recovery hint |

**`./uis platform use <name>`** — switch the active platform (per Q4 lockstep, per Q5 refuse-unless-initialized-and-reachable):

```
$ ./uis platform use azure-aks
ℹ  Probing azure-aks ... ✓ reachable (k8s v1.34)
✓  Switched: rancher-desktop → azure-aks
```

The success line names only the active platform (not the internal kubectl context name or `cluster-config.sh` state) — per N-C5/C-9, internal projections don't surface to the user. By the lockstep flip's construction (Q4) the kubectl context and `cluster-config.sh` are always in sync after `use`; there's nothing to display separately.

Refusal modes:

```
$ ./uis platform use google-gke
✗ google-gke is not initialized.
  Run './uis platform init google-gke' first.

$ ./uis platform use azure-aks   # platform initialized but cluster not running
✗ azure-aks is configured but not running.
  Run './uis platform up azure-aks' to start it.

$ ./uis platform use azure-aks   # cluster expected up but unreachable
✗ azure-aks is unreachable (API server timeout after 3s).
  Check the cluster state with './uis platform status azure-aks'.
  To switch anyway (e.g. to clean up stale kubectl state), use --offline.
```

With no argument, `use` presents an interactive numbered picker over the same set `list` shows — per C-8, only `running` rows get `[N]` selectors; others appear without selectors (no dimming, no ANSI tricks).

**Note on `Active:` header + `(active)` row annotation**: the same information appears twice — once in the `Active: <name>` header above the table, once as `(active)` on the matching row. This is deliberate redundancy. The header is what the user reads first; the per-row annotation is what they scan for when comparing rows. Both stay.

**Implementation shape**: `cmd_platform_list` and `cmd_platform_use` in `provision-host/uis/manage/uis-cli.sh`, delegating to a shared helper at `provision-host/uis/lib/platform-switching.sh`. That same helper hosts both:
- the lockstep writer (Q4) — also called by `02-post-apply.sh` and `03-destroy.sh` so all three call sites (`up`'s auto-flip, `down`'s auto-reset, `use`'s manual flip) converge on one writer
- the reachability-probe primitive — also called by Layer 1's banner code (which co-ships)

Sourcing pattern is the same one `02-post-apply.sh` already uses: `source "/mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh"` — the bind mount makes the path stable from any script running inside the container.

**Decision flow for `use` and `list`** — both consume the C-1 contract:

- `list` calls each platform's `status.sh --summary` (in parallel), parses field 1 per row to pick the visual treatment, prints field 2 as the hint. `--offline` flag propagates so each `status.sh --summary --offline` skips its probe.
- `use <name>` calls *just* `<name>'s status.sh --summary`, parses field 1, and dispatches per Q5's enum table (refuse for `not-initialized` / `configured-not-running`, lockstep-flip for `running`, refuse-with-`--offline`-hint for `unreachable`). With `--offline`, `use` skips the probe and proceeds even on `unreachable` — but still refuses on `not-initialized` / `configured-not-running` (there's no kubectl context to switch *to* in those states).

Layer 1's banner is the only consumer that bypasses `status.sh --summary` (per C-9) — it probes kubectl directly for the common reachable case and only escalates to a `status.sh --summary` call on the unreachable path (for the platform-specific recovery hint).

**Scope of "kubeconfig" in this design**: every kubeconfig reference above means **the merged kubeconfig inside the `uis-provision-host` container** at `/mnt/urbalurbadisk/kubeconfig/kubeconf-all`. The lockstep flip updates *that* file via `kubectl config use-context`, which is enough for every tool that runs inside the container (`./uis deploy`, `./uis shell` → `kubectl`/`helm`, ansible playbooks). **Host-side tools (`k9s`, `lens`, raw `kubectl` from a macOS terminal) are explicitly out of scope** — see "Out of scope" below. The host's `~/.kube/config` is untouched by `./uis platform use`.

**Edge cases this layer adds**: see the global "Edge cases to think through during design" section below — items #7 (`use` to active that's now unreachable), #8 (hidden directories), #9 (concurrent `use`), #10 (CLUSTER_TYPE vs TARGET_HOST) cover everything Layer 4 introduces. Kept in one place to avoid drift.

---

## Edge cases to think through during design

1. **No cluster reachable at all** (e.g. Rancher Desktop installed but stopped). Layer 1's probe of the active context returns `unreachable`; the banner emits the "API server unreachable" block + abort (see C-9). For rancher-desktop specifically, the recovery hint reads `start Rancher Desktop` rather than the generic `./uis platform status` (rancher-desktop's status.sh emits this hint per C-1's rancher-desktop subsection).
2. **Multiple kubeconfig files** — UIS pins the in-container `KUBECONFIG` to `/mnt/urbalurbadisk/kubeconfig/kubeconf-all` for the cluster-touching layer; that's the single file Q4's lockstep flip targets. Operators who override `KUBECONFIG` inside the container to point elsewhere are doing it as a power-user escape — Layer 1's banner will probe whatever's set, but `./uis platform use` ignores the override and writes to `kubeconf-all` (so the user's override and UIS's view can diverge until they unset it). Host-side `KUBECONFIG` is irrelevant to this design (see "Out of scope").
3. **Performance** — `--summary` is under 200 ms per platform (C-6) and Layer 1's banner is the same single probe (C-9). No caching needed for the default `list` or the per-command banner. (An earlier sketch proposed a `/tmp` probe cache for the banner — dropped because C-1's design already bounds the per-command cost.)
4. **CI / non-interactive contexts** — colour codes should respect `NO_COLOR=1` and detect non-TTY (`[[ -t 1 ]]`). Banner stays, just without ANSI.
5. **`./uis` invoked from outside `./uis shell`** — the wrapper docker-execs into the container; PS1 doesn't help there. Layer 1 covers this.
6. **Nested invocations** — only `./uis stack install` (which fans out to many `./uis deploy <service>` children) needs banner suppression in children. Per C-4 the parent sets `UIS_BANNER_PRINTED=1` before invoking children; child dispatchers check it and skip the banner. Ansible playbooks and other sub-shells the dispatcher invokes never print a banner to begin with — banner is a dispatcher-layer concern, not a playbook one.
7. **`use` to currently-active platform that's *now* unreachable** — the re-probe path of C-8's no-op behavior. If the user picks the already-active row and it now fails the probe, emit `✗ <name> is no longer reachable (API server timeout after 3s)` + recovery hint, exit non-zero. The active platform doesn't get changed (it was already the target); the user knows their session is now broken and what to do.
8. **Hidden / under-development platform directories** — `list` skips any `platforms/<name>/` whose name starts with `_` or `.`. Lets contributors prototype a new platform without it showing up in user output until they're ready to rename.
9. **Concurrent `use` from two terminals** — last write wins on both halves of the lockstep flip (kubectl context, cluster-config.sh). The shared writer in `platform-switching.sh` issues both writes back-to-back; interleaving is *possible* in theory but the window is sub-millisecond. Document the limitation, don't engineer a lock.
10. **`cluster-config.sh` CLUSTER_TYPE vs TARGET_HOST** — by convention since PR #146-era, both fields always hold the same string (the platform directory name). The lockstep writer writes both for backward compat with existing readers, but they're effectively the same value. Future work could collapse the two; out of scope here.

---

## Suggested rollout (revised 2026-05-11 after talk47)

The talk47 discussion flipped the original Layer-1-first ordering and tightened the Layer-1/Layer-4 coupling. The primary user need surfaced by talk47 is *"I have 2+ platforms; let me see them, let me switch, and tell me which one I'm on whenever I run a command"* — that's Layer 4 AND Layer 1 as one cohesive UX, not two sequenced shipments.

1. **Layer 4 + Layer 1 ship together** (or back-to-back PRs same day) — `./uis platform list / use` for the switching half, banner-at-top-of-every-cluster-command for the per-command visibility half. Bundle the lockstep-flip refactor: extract `cluster-config.sh` writing from `02-post-apply.sh` / `03-destroy.sh` into the shared helper at `provision-host/uis/lib/platform-switching.sh` so all three call sites (`up`'s auto-flip, `down`'s auto-reset, `use`'s manual flip) converge on one writer. The reachability-probe primitive lands here too, used by both layers.
2. **Layer 3 next** — `./uis status` (the global status command, not `./uis platform status <provider>`) becomes "where am I and what else is reachable?" The cluster header reuses Layer 1's banner machinery; a one-liner "other platforms: ..." pointer at the bottom links to Layer 4's `list`.
3. **Layer 2 last** — coloured PS1 inside `./uis shell`. Touching the container's bashrc coordinates with the container build; lowest-priority because it only helps in-shell users (and Layer 1's banner already covers them too).

Layer 4 + Layer 1 together deliver the "potential platforms + active visibility + safe switching" loop end-to-end. Layers 2/3 are polish on top.

---

## Out of scope for this investigation (deliberately)

- **Cross-cluster broadcasts** in a single `./uis` invocation (e.g. "deploy this to both local AND AKS"). UIS stays single-cluster-per-invocation; switching just makes it cheap to rotate which cluster that is.
- **Production-vs-sandbox enforcement.** Once Layer 2's colour scheme is in, building actual confirmation prompts ("Type the cluster name to continue against PROD") is a natural follow-up but separate.
- **Removing `cluster-config.sh` entirely.** Q4's lockstep-flip proposal bounds the source-of-truth question (kubectl context = truth for reads, `use` writes both atomically, `cluster-config.sh` is a derived projection). A larger refactor that removes `cluster-config.sh` outright (everything reads kubectl context, nothing reads `cluster-config.sh`) is a separate question. Mostly an Ansible-inventory-shape change rather than a UX one.
- **Provisioning new clusters from `list`.** `list` shows what exists; provisioning is `./uis platform up <name>` (separate command, scoped in [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md)). No "click to provision" affordance from inside `list`.
- **Host-side kubectl integration (`k9s`, `lens`, raw `kubectl` from macOS Terminal).** The lockstep flip in Q4 updates the kubeconfig *inside the `uis-provision-host` container* (`kubeconf-all`), which is enough for every tool that runs inside the container — including everything UIS itself invokes. The host's `~/.kube/config` is **not** touched and host-side tools won't see the selected platform unless the user wires `KUBECONFIG` up themselves (e.g. by pointing at the bind-mounted copy under `.uis.secrets/generated/kubeconfig/`). Cross-boundary kubeconfig sync (e.g. an `./uis env` helper that emits `export KUBECONFIG=...` for host shells, or a host-side merge of UIS contexts into `~/.kube/config`) is its own design problem and outside this investigation. The decision: target only the in-container `kubeconf-all`; host-side is the user's environment to manage.

---

## What this investigation needs to produce

**Status 2026-05-11**: Q1/Q2/Q3/Q4/Q5 all decided above. Rollout order locked (Layer 4 + Layer 1 together, then Layer 3, then Layer 2). Ready for child PLANs.

**Next concrete piece** — natural follow-on to the AKS novice-onboarding sequence (PRs #154–#159):

- **PLAN-platform-list-use-and-banner.md** (Layers 4 + 1, bundled) — covers:
  - `./uis platform list` (inventory + status from per-platform `status.sh`, plus the rancher-desktop special case)
  - `./uis platform use <name>` (refuse-unless-initialized-and-reachable + lockstep flip)
  - `provision-host/uis/lib/platform-switching.sh` shared helper hosting the lockstep writer + reachability probe
  - Convergence of `02-post-apply.sh` and `03-destroy.sh`'s existing `sed -i` flips onto the shared writer
  - **Banner-at-top of every cluster-touching `./uis` command** (Layer 1) reusing the same reachability probe — single tracer-bullet through `./uis deploy` first, then fan out
  - Trivial `platforms/rancher-desktop/scripts/status.sh` so the row can report its state

  Estimated scope: ~150 lines of bash across `platform-switching.sh` + two `cmd_platform_*` dispatchers + banner-injection at ~8 cluster-touching command call sites + one new rancher-desktop status script. Single PR is doable; splitting into two same-day PRs (switching first, banner second) is also fine.

Subsequent PLANs (smaller, post-Layer-4+1):

- **PLAN-uis-status-cluster-header.md** (Layer 3) — one-script change to add a cluster header to `./uis status`. Trivial once banner machinery exists.
- **PLAN-ps1-cluster-tag.md** (Layer 2) — container bashrc change; coordinated with the Dockerfile.

Implementation contracts settled in "Implementation contracts" section above (C-1 through C-9). The child PLAN drafts the function signatures and ANSI-stripping details against those contracts.

Remaining open question, deferred to the PLAN (not a blocker):

1. **Exact internal API of `platform-switching.sh`** — function names + signatures. Sketch: `pf_active_platform()`, `pf_probe_reachable <context>`, `pf_lockstep_flip <context> <platform>`, `pf_platform_summary <platform>` (parses the platform's `status.sh --summary` output), `pf_list_platforms()` (returns the inventory honoring the `_` / `.` hidden-directory skip). Names are the PLAN's call; the **contracts they implement** are settled above.

## Related

- [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — proposes the `./uis platform <verb> <target>` shape this investigation extends with `list` + `use` verbs. The two investigations share Q1 (canonical signal) and the reachability-probe building block. Land Layer 4 alongside the platform-wrappers PRs so novices are never stuck after `./uis platform up azure-aks` with no way to see or rotate what they've created.
- [PLAN-platform-aks-destroy-kubeconfig-cleanup.md](./PLAN-platform-aks-destroy-kubeconfig-cleanup.md) — fixes one source of the "stale kubectl context" problem this UX surfaces. Both plans address the same operator-safety concern from different angles.
- Tester's original write-up: `testing/uis1/talk/UX-active-cluster-visibility.md` (2026-05-09).
