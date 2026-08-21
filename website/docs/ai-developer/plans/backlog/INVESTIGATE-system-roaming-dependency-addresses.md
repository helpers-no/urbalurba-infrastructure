# Investigate: external dependencies whose address moves, and backends that sleep

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-08-21

## Status: Closed — product question decided, LiteLLM findings retained

**Decision (Terje, 2026-08-21)**: the `ollama-endpoint-manager` is **installation
implementation, not UIS**. It is not productised, not named as a service, and not
folded into the dependency layer. Reproducing it is ops' problem, tracked in the
home repo.

This file is kept because its LiteLLM findings (Part 1) are about LiteLLM and
survive the decision unchanged. Its recommendation (Part 4) does not — see
Part 6.

**Goal**: Decide whether UIS should own a reconciler that points a shim
`Endpoints` object at the first address in a declared candidate list that
answers a probe — and clears it when none do.

**Origin**: ops handed over a running implementation
(`ollama-endpoint-manager`) with a request for three decisions: is it general
enough for UIS, does LiteLLM already do it natively, and if not should it be
suggested upstream. This file answers all three.

**Verdict**: **LiteLLM partly covers it.** The address-selection half is native
and should be documented as a configuration recipe. The fail-fast half is not
native, is not an oversight upstream, and cannot be configured around. The
gap belongs in the **dependency layer**, not in the LiteLLM service.

**Related**:
- [PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md) — this is where the work lands, and this investigation asks for one of its Implementation Notes to be amended
- [PLAN-service-litellm-004-config-portability](./PLAN-service-litellm-004-config-portability.md) — defect F7 (`host.docker.internal`) is the same problem in miniature; see R4
- [PLAN-system-observability-006-service-probes](./PLAN-system-observability-006-service-probes.md) — probes read the Service, and would read a reconciled one identically
- [INVESTIGATE-system-external-or-in-cluster-services](./INVESTIGATE-system-external-or-in-cluster-services.md) — the same boundary, from the service-definition side

**Priority**: Medium

---

## Background

Some things UIS depends on do not sit still:

1. **The address changes with the network.** A developer's Mac running Ollama is
   on the LAN at the office and on Tailscale away from it. One static address is
   wrong half the time.
2. **A sleeping host still completes a TCP handshake** while every service on it
   is down. Requests therefore do not fail — they **hang**. The request that
   wakes the machine is always the one that dies.
3. **Two addresses in one `Endpoints` object load-balance**, so half the requests
   go to whichever address is currently dead. Listing both is not a fix.

Failure mode 1 is not hypothetical on the reference installation. The
`hosts/asgard/ollama-backends.yaml` committed to this repo declares
`mac-ollama → 192.168.68.58` and `m1-ollama → 100.127.6.20`. Read live on
asgard, 2026-08-21:

```
$ kubectl -n ai get endpoints
NAME         ENDPOINTS
m1-ollama    192.168.68.89:11434
mac-ollama   192.168.68.75:11434
```

Neither committed address is in use, and neither live address appears in the
candidate lists committed alongside them. Both hosts have moved since the file
was written and the file was not updated — which is exactly the drift a static
`Endpoints` object invites. Note both live values are **LAN** addresses in the
same subnet, so whatever set them did not need the Tailscale fallback.

*Not established*: whether the running reconciler selected these, or whether its
live candidate list was edited by hand and has itself drifted from git. Reading
that needs access to the `ollama-endpoint-manager` ConfigMap in `ai`, which the
read-only `monitor-discovery` account cannot get. **Answer this first in the
spike** — it decides whether the reference installation is currently being
reconciled or merely hand-corrected.

---

## Part 1: Findings — does LiteLLM already do this?

Verified against LiteLLM `main` (`litellm/router.py`, `litellm/proxy/health_check.py`)
and the current docs, 2026-08-21. Not verified by live spike — see Part 3.

### RD-F1 — Ordered address preference IS native (`order`)

Two deployments sharing one `model_name`, with different `api_base` and
`order: 1` / `order: 2`, give a deterministic LAN-first / Tailscale-second
preference. Confirmed in source: `_get_order_filtered_deployments` narrows
healthy deployments to the lowest order tier, and `router.py` escalates through
`order_values` as a fallback ladder when a tier fails.

Caveats:
- `order` was reported broken in **v1.80.11** (BerriAI/litellm#18444 — both
  tiers received ~50% of traffic). The issue is closed and the docs were added
  in PR #18888. **UIS does not pin the LiteLLM chart** (see
  PLAN-service-litellm-002-version-pinning) — so "which version do we get" is
  currently unanswerable, and this is a feature where a silent regression
  degrades to round-robin across a dead address.
- `latency-based-routing` is **not** a substitute. It measures latency
  empirically; it has no concept of "prefer the local path".

**Covered natively — with a version-pinning precondition.**

### RD-F2 — Health-check-driven routing IS native, and IS expensive here

`general_settings.background_health_checks: true` +
`enable_health_check_routing: true` removes a failing deployment from the
routing pool before a user request lands on it.

But LiteLLM has **no lightweight probe mode**. Every supported `mode` value
(`chat`, `completion`, `embedding`, `image_generation`, `audio_transcription`,
`audio_speech`, `rerank`, `batch`, `realtime`, `ocr`, `video_generation`) runs
real inference. `_run_model_health_check` calls `litellm.ahealth_check` with
`prompt="test from litellm"` and a 16-token cap.

The cost is per **deployment**, not per host. `hosts/asgard/litellm-models.yaml`
declares 17 model entries. Modelling each roaming backend as two deployments
makes that **34 real inference probes per interval**, against Ollama servers
that load models **serially**, on laptops holding a 13.8 GB `gpt-oss:20b`
alongside seven smaller models. That is continuous model-swap thrash on the
machine whose responsiveness we are trying to protect.

This is a known upstream complaint (BerriAI/litellm#5816, *"the checks are done
in parallel and with too many models, it times out — ollama is loading them in
serial"*), **closed as not planned**. Current `main` has since added
`_run_health_checks_with_bounded_concurrency`, which bounds parallelism but does
not make the probe cheap.

Compare: the reconciler issues **one** `GET /api/version` per host — 2 probes,
no model load, regardless of how many models each host serves.

**Covered natively, at a cost that scales with the model list rather than the
host list.**

### RD-F3 — Fail-fast when every address is down is NOT native, by design

This is the finding that decides the verdict. From `litellm/router.py`,
`_async_filter_health_check_unhealthy_deployments`:

```python
filtered: Final = [d for d in healthy_deployments if d["model_info"]["id"] not in unhealthy_ids]

if not filtered:
    verbose_router_logger.warning("All deployments marked unhealthy by health checks, bypassing health filter")
    return healthy_deployments
```

When **every** candidate address for a model group is unhealthy, LiteLLM
deliberately routes to them anyway. The docstring calls it a "safety net". For a
cloud provider it is one. For a sleeping Mac it is precisely the failure being
engineered against: the request is dispatched to an address that completes the
handshake and then stalls, so `fallbacks` to the twin model on the other host do
not fire until `request_timeout` expires. asgard sets `request_timeout: 300` —
and it must stay high, because a *present but busy* backend legitimately takes
minutes. Fail-fast and generous timeouts cannot both come from LiteLLM.

There is a second trap in the same function: setting `allowed_fails_policy`
makes the binary health filter a **no-op** —

```python
if self.allowed_fails_policy is not None:
    return healthy_deployments
```

— so the operator must choose *either* threshold-based cooldown (populated by
real requests that already failed or hung) *or* the binary filter. Not both.

By contrast, clearing a selector-less Service's `Endpoints` makes kube-proxy
reject the connection immediately, so `num_retries: 0` + `fallbacks` fires at
once. That behaviour is a property of the Service, not of LiteLLM.

**Not covered, and not configurable around.**

### RD-F4 — The blast radius differs

A LiteLLM-side solution protects LiteLLM's clients. The `Endpoints` reconciler
protects **every** consumer of `mac-ollama.ai.svc.cluster.local` — including
anything talking to Ollama directly, and the availability probes from
PLAN-006, which read the Service and cannot tell a reconciled endpoint from a
static one.

### RD-F5 — Where the address is written down

asgard's LiteLLM config references cluster DNS names, so a moved host is a
one-object change with no LiteLLM restart. The native approach requires the raw
candidate addresses in the LiteLLM ConfigMap, once per model — 34 `api_base`
values on the current list. That reintroduces addresses into service config,
which is the coupling PLAN-system-dependencies-shim-services exists to remove.

### RD-F6 — Corrections to the ops handoff

Two claims in `ai-developer/for-uis-maintainer-ollama-endpoint-manager.md` (home
repo) are wrong and should not be carried forward:

- *"not yet version-controlled"* — it is. `hosts/asgard/ollama-endpoint-manager.yaml`
  and `ollama-backends.yaml` have been in this repo since commit `9c9b0e7`
  ("Version-control the asgard .uis.extend manifests"). The handoff is about
  **productising** it, not about rescuing it.
- The pre-analysis frames the LiteLLM question as *"health checks may cover
  need #1"*. They do (RD-F1/RD-F2), but need #1 was never the hard part.
  Need #2 — fail-fast — is, and RD-F3 shows upstream has explicitly chosen the
  opposite behaviour.

---

## Part 2: What the answer has to satisfy

Derived from the findings, in priority order.

- **R1 — Not an AI/ML component.** Nothing about candidate addresses, probing,
  or fail-fast is specific to Ollama or to LiteLLM. Shipping this beside
  `service-litellm` would make a general dependency-layer capability look like
  a model-serving accessory, and would leave non-LiteLLM consumers unprotected
  (RD-F4). It belongs in the dependency layer.
- **R2 — Declared, not discovered.** PLAN-system-dependencies-shim-services says
  in its Implementation Notes: *"Do not add address auto-discovery; it would
  reintroduce the coupling this removes."* That note is right about discovery
  and this proposal does not violate it — but the wording currently forbids
  this too, and needs amending. The distinction: **the operator still declares
  every address, in the one place the plan designates.** The artifact holds an
  ordered list instead of a single value. Nothing is scanned, sniffed, derived
  from mDNS, or learned at runtime. An address that is not declared is never
  used. What changes is only that a dependency with two *known* homes stops
  requiring an edit when it moves between them.
- **R3 — Optional and absent by default.** A dependency declaring one address
  gets a plain static `Endpoints` and no reconciler, exactly as today. The
  reconciler is what a *multi-candidate* declaration renders, and a stock
  all-in-cluster install renders neither.
- **R4 — It must fix the dev-mode case too.** PLAN-service-litellm-004 defect F7
  is this problem wearing a different hat: the default config hardcodes
  `host.docker.internal`, which works on Rancher Desktop and does not resolve on
  a k3s node. A candidate list — `host.docker.internal`, `host.lima.internal`,
  the node IP — resolves it by probing instead of by environment detection
  (PLAN-004 Phase 1.1 option (b)). One mechanism, both problems. **Design
  consequence**: candidates must be allowed to be *names*, with the reconciler
  resolving to an IP before patching, because an `Endpoints` object takes IPs
  only.
- **R5 — Cheap probes.** One probe per dependency, not per consumer of it
  (RD-F2). The probe is a property of the dependency: path, port, timeout,
  accepted status codes — the same shape PLAN-006 already needs, and the same
  caveat applies (a sealed OpenBao answers 503 and is not healthy).
- **R6 — Fail-fast is the deliverable.** Clearing `Endpoints` when nothing
  answers is not a side effect; it is the property LiteLLM cannot provide
  (RD-F3). Any implementation that keeps a stale address rather than clearing it
  has delivered nothing.

---

## Part 3: Open questions

These need a live spike on Rancher Desktop and were **not** answered here — the
findings above are source-level and documentary, not empirical.

- **Q1** Does `order` behave as documented in the LiteLLM version the unpinned
  chart currently pulls? Two deployments, one `api_base` deliberately dead;
  confirm 100% of traffic goes to `order: 1` while it is up, and that the
  regression in #18444 is genuinely gone. **Blocked on / motivates
  PLAN-service-litellm-002-version-pinning.**
- **Q2** Reproduce the sleep-hang with `docker pause` on a container standing in
  for a sleeping Mac (a paused container completes the handshake and then stalls
  — the same shape). Measure: how long until `background_health_checks` marks it
  down, and what a request does in the window before that.
- **Q3** Confirm RD-F3 empirically: with both addresses of a model group paused,
  does the request get dispatched and hang for `request_timeout`, or does it
  fail fast? The source says dispatched. Verify, because the whole verdict rests
  on it.
- **Q4** Measure what background health checks actually cost against a real
  Ollama host with 8 models — model swap frequency, memory pressure, and
  whether probes start timing out on a *healthy* host (the #5816 failure) even
  with bounded concurrency.
- **Q5** Convergence: the reconciler probes every 60s. `health_check_interval`
  defaults to 300s and is settable. What is the practical floor before the probe
  cost in Q4 becomes unacceptable?
- **Q6** Wake-on-probe. A 60s TCP connect keeps a Mac awake via "Wake for
  network access". This is a property of *any* periodic probe, native or not, so
  it is not a differentiator — but it needs documenting as a knob (interval, or
  scale the reconciler to zero) rather than a surprise.

**Environment note**: the maintainer session that produced this file runs on a
Raspberry Pi with read-only (`monitor-discovery`) access to asgard — enough to
read Services and Endpoints, which is where the drift evidence in Background
came from, and not enough to spike. Q1–Q6 need Rancher Desktop. Per the M1
boundary, ask before starting containers there.

---

## Part 4: Recommendation — SUPERSEDED 2026-08-21

> ⚠️ **This section is retained for its reasoning, not as guidance.** Its
> conclusion — fold the capability into UIS's dependency layer — was overruled.
> See Part 6. What still stands from it: the LiteLLM recipe, and that this is
> not an AI/ML component.

**Do not ship `ollama-endpoint-manager` as a UIS service in the AI & ML area.**
As written it is hardcoded to two `Endpoints` names, port 11434, Ollama's
`/api/version`, and RBAC `resourceNames` naming those two objects. It is a good
implementation of a general idea wearing installation-specific clothes.

**Do fold the capability into the dependency layer**, as an optional rendering
of PLAN-system-dependencies-shim-services' Phase 1 artifact:

```yaml
# dependencies/<id>.yaml — installation-agnostic, ships with the product
name: ollama
port: 11434
probe:
  path: /api/version
  timeout: 3
why: "External model server for LiteLLM"
```

with the installation config supplying one address (static `Endpoints`, no
reconciler, today's behaviour) or an ordered candidate list (reconciler
rendered). Addresses stay in `urbalurba-secrets` / installation config, never in
the shipped artifact — the existing rule, unchanged.

**Keep the manager running on asgard meanwhile.** It is version-controlled,
scoped, and currently the only thing keeping the reference installation's
LiteLLM pointed at two hosts that have both moved.

**Also write the LiteLLM recipe** (RD-F1/RD-F2) into the LiteLLM service docs
regardless of what happens to the reconciler. Two deployments + `order` +
`enable_health_check_routing` is a legitimate pattern for anyone with a small
model list who does not want a reconciler, and UIS should document it honestly
alongside its cost and the fail-fast caveat.

### Proposed plans, to be drafted once Q1–Q6 are answered

1. `PLAN-system-dependencies-shim-services` — **amend** the "Endpoints are not
    reconciled" Implementation Note per R2, before anything else is built.
2. `PLAN-system-dependencies-002-candidate-addresses` — the artifact schema,
    name→IP resolution (R4), and the rendered reconciler.
3. `PLAN-service-litellm-005-roaming-backends-recipe` — the documentation
    recipe, and the RD-F1 version-pinning precondition.

---

## Part 5: DRAFT upstream suggestions — for Terje to review and post

⚠️ **Not posted. Draft text only.** Nothing here is filed upstream by the
maintainer agent. Searched BerriAI/litellm 2026-08-21: no existing issue covers
either suggestion.

Both are worth filing **whatever UIS decides**, because they are real gaps for
any self-hosted backend, not just ours.

### Draft A — a health-check mode that does not run inference

> **Title**: [Feature]: lightweight health-check mode (HTTP probe) for
> self-hosted backends
>
> Every value of `model_info.mode` runs real inference against the model
> (`_run_model_health_check` → `ahealth_check` with `prompt="test from litellm"`).
> For hosted APIs that is cheap. For a self-hosted Ollama server it is not: the
> probe is per *deployment*, so a proxy fronting 17 models issues 17 inference
> requests per `health_check_interval`, and Ollama loads models serially. In
> practice this evicts and reloads models continuously, and the probes
> themselves start timing out on a server that is perfectly healthy — the
> failure reported in #5816 (closed as not planned; bounded concurrency has
> since been added, which limits parallelism but does not make the probe cheap).
>
> Proposal: allow a deployment to declare a cheap liveness probe instead of an
> inference probe, e.g.
>
> ```yaml
> model_info:
>   mode: http
>   health_check_url: /api/version      # relative to api_base
>   health_check_timeout: 3
> ```
>
> A 200 marks the deployment healthy. This tests reachability rather than model
> correctness, which is the right granularity when N deployments share one host
> — and it collapses N probes into one per host.

### Draft B — allow a fully-unhealthy model group to fail fast

> **Title**: [Feature]: opt out of the "bypass health filter when all
> deployments are unhealthy" safety net
>
> `_async_filter_health_check_unhealthy_deployments` returns the unfiltered list
> when every candidate is unhealthy:
>
> ```python
> if not filtered:
>     verbose_router_logger.warning("All deployments marked unhealthy by health checks, bypassing health filter")
>     return healthy_deployments
> ```
>
> For a cloud provider whose health check may be wrong, that is a sensible
> safety net. For a self-hosted backend on a machine that sleeps, it is the
> worst case: a sleeping host completes the TCP handshake and then stalls, so
> the dispatched request does not fail — it hangs until `request_timeout`, and
> `fallbacks` to a working backend elsewhere cannot fire until it does.
> `request_timeout` cannot be lowered to compensate, because a *present but
> busy* backend legitimately takes minutes; "busy must queue, absent must fail"
> are different cases and only one of them is slow.
>
> Proposal: a router setting, defaulting to today's behaviour, e.g.
>
> ```yaml
> router_settings:
>   health_check_routing_bypass_when_all_unhealthy: false   # default: true
> ```
>
> When `false`, a model group with no healthy deployments raises immediately so
> that configured `fallbacks` fire without waiting for a timeout.
>
> Related, and possibly worth a docs note either way: setting
> `allowed_fails_policy` silently makes the binary health filter a no-op
> (`if self.allowed_fails_policy is not None: return healthy_deployments`). That
> the two mechanisms are mutually exclusive is not obvious from the config, and
> it is easy to enable both believing they compose.

---

## Part 6: Decision — not a UIS concern (2026-08-21)

Terje's call, and it holds up better than Part 4 did.

**The reasoning.** A UIS feature needs a second plausible user, not merely a
generalisable mechanism. Part 4 established that nothing about candidate
addresses is Ollama-specific and concluded the capability was therefore general
enough to ship. That skipped a step. "The pattern generalises" and "another
installation would use it" are different claims, and only the second justifies
product surface. Two Macs that sleep and roam between one LAN and one tailnet is
a single-installation topology.

This is also the rule both repos already had written down, applied correctly:

- `INVESTIGATE-system-external-or-in-cluster-services` — what stays
  installation-specific is *"things UIS did not deploy and cannot be expected to
  know about, which is the honest boundary."*
- the home repo's `ai-developer/README.md` — *"If it would be useful to someone
  else who installs UIS → urbalurba. If it only makes sense because we run an
  i5-7400T in Asker → here."*

UIS did not deploy the Macs and cannot be expected to know about them.

**What this closes.**

- No service name, no `uis deploy <name>`, no category. The question of what to
  call it is moot.
- No `endpoint-reconciler` rendered from the dependency artifact.
- The challenge this file raised against
  [PLAN-system-dependencies-shim-services](./PLAN-system-dependencies-shim-services.md)
  is **withdrawn** — it was argued on the strength of a reconciler UIS is not
  going to ship. That plan's "do not add address auto-discovery" note stands as
  written. The distinction between *declared candidate lists* and *discovery* is
  still a real one and is parked in that plan's notes, unresolved, for whoever
  ever needs it.

**What this does not close** — none of it was ever about the manager:

- **Part 1 stands in full.** The LiteLLM parity findings describe LiteLLM, not
  our reconciler. RD-F3 in particular — the router bypasses its own health filter
  when every deployment is unhealthy — is a fact about LiteLLM that any UIS
  installation with two backends inherits.
- **The LiteLLM recipe is still worth writing** (RD-F1/RD-F2): two deployments,
  one `model_name`, `order: 1`/`order: 2`, `enable_health_check_routing`, and an
  honest account of the probe cost and the fail-fast caveat. That is general,
  has obvious second users, and belongs in the LiteLLM service docs.
- **The DRAFT upstream suggestions in Part 5 stand**, and got stronger.
  Independent corroboration: `tashfeenahmed/freellmapi` (19k stars, a mature
  OpenAI-compatible proxy with six routing strategies and automatic failover)
  fails over on **429/5xx only** — status codes. A backend that completes the TCP
  handshake and then goes silent produces no status code, so it has the same
  blind spot as LiteLLM. Two unrelated proxies, one shared gap: this is a
  category-wide limitation, not a LiteLLM oversight, which is a better argument
  for Draft B than "our Macs sleep."
- **The F7 connection to
  [PLAN-service-litellm-004-config-portability](./PLAN-service-litellm-004-config-portability.md)**
  — a probe-a-candidate-list approach would fix `host.docker.internal`
  portably. Noted there for whoever picks that plan up; it does not need this
  file.

**Handed back to ops.** The manifests are already committed at `hosts/asgard/`,
whose README says the authoritative copies live on `ops` and *"if you change it
there, copy it back."* That convention demonstrably did not hold — see the
Background section: both committed addresses are stale, and the live candidate
list could not be read to compare. The open work is not *where* to store it,
which was decided 2026-08-07, but how the round-trip stops depending on someone
remembering — and recovering the running values before they are lost. That is
ops' work, in the home repo, by the boundary rule above.
