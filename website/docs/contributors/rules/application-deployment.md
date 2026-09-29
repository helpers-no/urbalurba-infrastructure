# Rules for Deploying Applications

How an **application** gets onto UIS. For how a **platform service** gets packaged,
see [Rules for UIS Deployment System](./kubernetes-deployment.md) — that is a
different thing with a different lifecycle, and conflating them is the mistake
this document exists to prevent.

**Decided**: 2026-09-07 by Terje, with the UIS maintainer. Supersedes nothing; this
is the first time the question has been answered in writing.

---

## The rule

> **`uis` provisions. ArgoCD deploys. The seam is `uis configure`, which writes a
> Kubernetes Secret that the application's own manifest reads.**

Both mechanisms are permanent. This is **not** a transition where one replaces the
other later.

| Owner | Owns | Why it cannot be the other one |
|---|---|---|
| **`uis`** | databases, roles, secrets, and **platform-service configuration** — a Dagster code location, a PostgREST instance | None of these is a Kubernetes manifest in the application's repository. A code location is a Helm values overlay; a PostgREST instance is a generated password. **ArgoCD has no object to reconcile** |
| **ArgoCD** | the **workload** — `Deployment`, `Service`, `Ingress`, in the application's own repo under `manifests/` | Reconciling a running workload against git is exactly what it is for, and `uis argocd register` already does it |

### The test for any application

> **Does it bring its own workload, or does it configure platform services to run
> its code?**

- **Brings its own workload** → ArgoCD. `uis argocd register <name> <repo-url>`.
- **Configures platform services** → `uis`. A template declaration; see
  [INVESTIGATE-templates-multi-surface-application](../../ai-developer/plans/backlog/INVESTIGATE-templates-multi-surface-application.md).

⚠️ **The answer is per-object, not per-application.** One application can legitimately
need both, and the first real one does.

---

## Worked example: Atlas uses both, and that is correct

Atlas is a data platform: an ingest pipeline plus a read-only API plus a frontend.

| Part | Path | Mechanism |
|---|---|---|
| database + migrations | `uis` | `uis configure postgresql --app atlas --init-file -` |
| secret in the `dagster` namespace | `uis` | same call, `--namespace dagster --secret-name-prefix atlas-database` |
| ingest pipeline | `uis` | a Dagster **code location** — `.uis.extend/dagster-code-locations.yaml` + `uis deploy dagster` |
| read-only API | `uis` | `uis configure postgrest --app atlas` + `uis deploy postgrest --app atlas` |
| **frontend** | **ArgoCD** | `uis argocd register atlas-frontend <repo>` |

The pipeline has **no workload of its own** — Atlas ships an image and Dagster
launches it. There is nothing for ArgoCD to deploy. The frontend is an ordinary
`Deployment`, so `uis` should not be involved.

This follows directly from the requirement Atlas was given: *"atlas must use the
dagster and postgres services that are in UIS."* An application told to use platform
services is, by definition, on the `uis` path for those parts.

---

## What ArgoCD already gives you, and what it does not

`uis argocd register` creates an `Application` (`argocd-register-app.yml:285-311`):

```yaml
source:      { repoURL: <repo>.git, targetRevision: HEAD, path: manifests }
syncPolicy:
  automated: { prune: true, selfHeal: true }
  syncOptions: [ CreateNamespace=true ]
```

✅ **Drift detection and self-heal are on by default.** A hand-edited cluster object
is reverted to what git says. You do not have to ask for this.

❌ **No image-tag following.** There is no `argocd-image-updater` in this repository.
`targetRevision: HEAD` follows a **git** ref, not a registry tag — so a new image
means a commit to the application's repo, not an automatic rollout.

❌ **No application secrets.** The register path creates a GitHub credentials secret
for private repos and nothing else. An application's own secrets come from
`uis configure` — see the limit below.

---

## The order: configure first, then register

An application that needs **both** a platform service and its own workload takes two commands, and **they have an order**:

```bash
uis configure postgresql --app console --namespace console --secret-name-prefix console
uis argocd register console https://github.com/helpers-no/urb-agents-console
```

**Database first.** `configure` creates the namespace and writes the Secret; `register` then hands that namespace to ArgoCD, and the workload starts with its credential already present.

🔴 **Before 1.6.174 this order refused itself.** `configure --namespace x` creates namespace `x` — it must, because that is where the pod reads `DATABASE_URL` from — and `register` then failed with *"Name 'x' is already in use as a Kubernetes namespace."* Step 1 created the thing that made step 2 refuse.

The only order that worked was the reverse, and it works by *recovering from a broken state*: register first, the pod cannot start because its Secret does not exist, and Kubernetes retries until `configure` creates it. That succeeds, but it puts a `CreateContainerConfigError` in front of every operator as a normal step.

**What changed:** `register` now asks what is *in* the namespace rather than whether it exists.

| namespace state | before | now |
|---|---|---|
| does not exist | ✅ register | ✅ register |
| exists, no workloads (what `configure` leaves) | 🔴 refused | ✅ adopted, and says so |
| exists, holds workloads | ✅ refused | ✅ refused, **naming them** |
| ArgoCD `Application` of that name already exists | 🔴 **not checked at all** | ✅ refused |

⚠️ That last row was a real hole, not a side effect: the old guard looked only at namespaces, so an orphaned `Application` whose namespace had been deleted registered straight over itself.

The register playbook never needed the guard — task 10 creates the namespace with `state: present`, which is idempotent.

🔵 **Adoption does not put the Secret at risk.** `syncPolicy.automated.prune` removes resources ArgoCD *tracks* — ones that were in git and are gone. A Secret created out of band by `configure` carries no tracking metadata, so it is not a prune candidate. ⚠️ Stated from ArgoCD's documented prune semantics, not from a run on this cluster; the deploy test is what confirms it.

---

## 🔴 The limit, stated plainly

**A cluster rebuilt from git alone would come up with no application secrets.**

`uis configure` mints a password that UIS deliberately does not store
(`configure-postgresql.sh:237` — *"UIS does not store this"*). That step is
imperative and lives outside any repository. So the GitOps story is **partial by
construction**, and nobody should be promised otherwise.

Closing this is the point of per-workload named secrets — item 1 of
[ANALYSIS-nais-uis](../../ai-developer/plans/backlog/ANALYSIS-nais-uis.md) §4. Until
it lands, "it is all in git" is false for anything with a credential.

---

## Why UIS is not growing an `Application` type

NAIS answers this question a third way that neither mechanism above matches: the
developer declares provisioning **and** workload in one manifest, and an operator
(naiserator) reconciles both. That collapses the seam entirely, and it is the reason
NAIS can rebuild from a declaration.

It is deferred, and the reasoning is not new — `ANALYSIS-nais-uis` §4 ranks a UIS
`Application` manifest **last of thirteen**, at **L** effort, behind items 1, 3 and 5,
with the note that *"NAIS built `nais.yaml` on top of capabilities it already ran;
UIS would be building the declaration first."*

⚠️ **And it would not have solved the first real application.** NAIS has two workload
kinds, `Application` and `Naisjob`, and **both run the application's own pods**. There
is no NAIS concept for *"hand my image to a shared orchestrator that launches it."*
Atlas's shape exists because UIS made Dagster a shared platform service with tenants —
a UIS invention with no NAIS analogue. So an `Application` type modelled on NAIS would
not cover Atlas-shaped applications, and the template mechanism is needed either way.

---

## Sequence

Decided 2026-09-07. Items 1 and 2 are independent and both proceed now.

| | Work | Effort | State |
|---|---|---|---|
| 1 | Atlas via templates — ordering (`PLAN-templates-000`), then the missing `config:` fields | M | in flight |
| 2 | Atlas frontend via `uis argocd register` | free | ready, nothing blocks it |
| 3 | **Retract `SCRIPT_CONFIGURABLE` where no handler exists** — see below | S | filed |
| 4 | Per-workload named secrets (`ANALYSIS-nais-uis` §4 item 1) — closes the seam above; the real prerequisite for both external developers **and** whole-lifecycle GitOps | M | not started — **two consumers now, see below** |
| 5 | *Then* reconsider a UIS `Application` type | L | deferred |

### The fork this exposes: should `argocd register` provision, or should these apps be templates?

`urb-agents#1692` proposes that `uis argocd register` read a `requires:` block from the repository and run the provisioning before it registers. The pain behind it is concrete: the developer must *know* the `uis configure` invocation, get someone with cluster access to run it, and pass four flags correctly — which for one application took a bus task to another agent with the command written out.

🔵 **The proposal is close to something UIS already has.** `uis template install` reads a declaration, provisions `postgresql` with a `config:` block including `init:`, writes a named per-app Secret, records the result in `.uis.extend/applications.yaml`, and refuses unmet dependencies. **The request is, in effect, for the ArgoCD path to gain what the template path already does.**

So the decision is not "should UIS have a provisioning declaration" — it has one. It is:

| | |
|---|---|
| **A** | the ArgoCD path gains provisioning, and two paths each read their own declaration |
| **B** | applications that need provisioning become templates, and the ArgoCD path stays deploy-only |

⚠️ **A is smaller to build and doubles the number of declaration formats. B adds nothing and asks an application author to adopt a heavier mechanism.** Neither is obviously right, and it is a maintainer decision rather than a technical one.

### 🔴 Whichever is chosen, `requires:` is the wrong keyword for it

`requires:` already means **two different things** in this repository:

| where | shape | means |
|---|---|---|
| `service.schema.json` | `requires: [<service-id>]` | hard dependencies between **platform services** |
| `template-info.yaml` | `requires: [{application, provides}]` | this tenant needs **another installed application**, checked against `.uis.extend/applications.yaml`, and **refused** if absent |

A third shape — `requires: [{service, config}]`, meaning *provision this for me* — would make one keyword mean three things across three files. **Use a distinct key** (`provisions:`, or reuse the template path's `config:` block verbatim) so a reader can tell which question a declaration is answering.

⚠️ And there is a precedent worth heeding: the **`requires` defect in 1.6.24** was UIS *reading a field no registry entry ever carried*. A declaration that nothing writes and nothing enforces looks supported and is not — the same failure as `SCRIPT_CONFIGURABLE="true"` on services with no handler.

### What is already true, and would not need building

- ✅ `uis configure postgresql --namespace --secret-name-prefix` **already writes a per-app Secret** carrying `DATABASE_URL`. The per-app named secret the proposal assumes exists today for this service, so **the database case is not blocked on item 4.**
- ✅ **Re-running is already safe**, and deliberately so: with `--namespace` the password is read back from the existing Secret rather than rotated. That behaviour exists because rotation once left a running application holding the old credential and an install that exited 0 (`urb-agents#492`).
- 🔴 ⚠️ **Item 3 is still open.** Eight services declare `SCRIPT_CONFIGURABLE="true"` and two have handlers. Anything that reads that flag to decide what it can provision would inherit the advertisement. **Item 3 is a prerequisite for a provisioning declaration, not a tidy-up beside it.**

### The gap the proposal does not close, and should say so

A Secret written or updated by `configure` **does not restart the pod consuming it** — `secretKeyRef` binds at container start. The application whose registration prompted this needed a pod restart afterwards. So "register provisions" must either roll the workload or report that it did not; otherwise it succeeds while the application keeps the credential it started with.

### Item 4 now has a second consumer, and it is the one the row was written for

`urb-agents-console` (2026-09-28, `urb-agents#1677`) is the first application to **both** deploy its own workload via `uis argocd register` **and** depend on a platform service. It needs one *generated* credential (a database) and two *given* secrets, in a **public** repository.

🔵 **What it adds is not urgency — it is evidence.** Item 4's justification was a prediction about external developers. This is the first case where the seam actually costs **someone else's hands**: the app's author has no cluster access, so a third party must run `uis configure` before the application can start. Atlas did not show this, because Atlas belongs to the same people who run the cluster.

⚠️ **It does not reorder anything.** Item 4 was already the gate and already ahead of item 5; a second consumer confirms that rather than revising it.

### What item 4 does and does not close

| | after item 4 |
|---|---|
| blast radius | ✅ one app's own keys instead of every namespace's shared Secret |
| adding a key | ✅ one place, not a three-file edit (SEC-F5) |
| a developer self-serving a database | 🔴 **still no** — a generated credential is still minted imperatively |
| rebuild from git alone | 🔴 **still partial** — but the missing piece becomes one *named* Secret instead of a silently empty value |

🔵 That last row is the honest win and it is easy to oversell. Item 4 does not make the GitOps story whole. It makes what is missing **diagnosable**, which is the same shape as every other fix in this product: a refusal that names the absent thing beats a success that does not mention it.

### On a vault, and why a concrete consumer does not summon one

[INVESTIGATE-secrets-dev-to-production](../../ai-developer/plans/backlog/INVESTIGATE-secrets-dev-to-production.md) **Part 4** is titled *"Why this comes before the vault question"*, and its argument is not that a vault waits for demand:

> *"a vault does not stop an unset key rendering empty, does not make an allowlist self-updating, and does not put validation on the deploy path. Fixing this first makes the vault question smaller."*

So a new consumer does not move the vault forward — **item 4 is upstream of it either way**, and doing item 4 first shrinks what a vault would have to answer.

### 🔴 Encrypted secrets in git trade away Principle 0

Sealed Secrets and SOPS are the obvious answers for *given* secrets in a public repository, and they are cryptographically sound there. **The objection is not secrecy, it is portability:** both bind a secret to a specific key holder, so the same git tree **cannot come up on a developer's laptop**.

⚠️ That is [Principle 0](./kubernetes-deployment.md) — *every service runs on a developer's laptop* — which `ANALYSIS-nais-uis` names as one of three things UIS does **better** than NAIS. Committing encrypted secrets buys reproducibility on one cluster by giving up reproducibility everywhere else.

**So the recommendation is to separate the two questions.** Item 4 lets an application *name* the Secret it expects — `envFrom: [secret: <name>]`, plain Kubernetes, no platform code. **Where that Secret comes from stays swappable**: created by hand today, by Sealed Secrets, SOPS or External Secrets later, with no change to the application's declaration. Deciding the delivery mechanism now would bind the cheap half to the expensive one.

**Item 4 is the gate, and it is not the one people assume.** "We need GitOps before we
onboard developers" is the wrong dependency: ArgoCD already works. What a developer
cannot get today is a database with a credential in a declaration — and that is item 4.

### Item 3 — advertise only what exists

Eight services declare `SCRIPT_CONFIGURABLE="true"`; **two have handlers**:

```
declared : elasticsearch mysql mongodb qdrant postgresql redis authentik postgrest
handlers : postgresql postgrest
the rest : "Handler not yet implemented."   (configure.sh:234)
```

The two that work are exactly the two the first application needs — so the provisioning
half of this rule works for Atlas and would fail for application #2.

**Decision: retract the six, build none for now.** Two honest handlers beat eight of
which six lie, and a stub advertised as a capability is the same defect that cost the
first tenant two of its four install steps. Retracted is not cancelled: re-declaring is
a one-line change the day a handler exists.

#### What retracting actually does, measured

Asked before deciding (`urb-agents#1710`). **The flag and the handler are independent**, and only the flag is being withdrawn:

| | `uis configure redis --app x` says |
|---|---|
| today | passes the gate, then `No configure handler for 'redis'. Handler not yet implemented.` |
| retracted | `Service 'redis' is not configurable.` — plus the list of services that are |

🔵 **So retracting turns one refusal into an earlier and more accurate one.** It cannot break an install, because the work is done by a handler *file* (`lib/configure-<service>.sh`) that does not exist either way. Exactly two things read the flag: the gate in `configure.sh`, and the docs generator.

#### 🔴 authentik is the expensive one, and not for the reason it looks

The blueprint *content* is already solved and proven: `073-authentik-2-openwebui-blueprint.yaml.j2` is a **templated per-app OIDC blueprint** — provider, `client_id`/`client_secret`, `redirect_uris`, application, group mappings — and `service-protection-blueprint` is already generated dynamically. A handler would emit the same shape.

⚠️ **The delivery is the obstacle.** Every blueprint needs **three** static entries in `075-authentik-config.yaml.j2` — `blueprints.configMaps[]`, `server.volumes[]` and `server.volumeMounts[]` — a *product* config file operators are told not to edit, and authentik reads the list **at startup**.

The repository already documents this, in the header of the slot file itself:

> *"Authentik requires ALL blueprint ConfigMaps to be listed in the Helm chart when it starts… THE PROBLEM: We can't predict what applications developers will add later! THE SOLUTION: Pre-allocated empty slots."*

🔴 **And exactly one slot exists.** Its own example shows a `slot-2`; there is no slot 2. So one application can be configured without touching product config, and the second needs a values edit and an authentik restart. **A handler is not writing a blueprint — it is making the mount dynamic**, which is a change to how authentik is deployed, not a script beside it.

⚠️ Second cost: `client_id` and `client_secret` come from **`urbalurba-secrets`** (`OPENWEBUI_OAUTH_CLIENT_ID`, `..._SECRET`), so each new app adds keys to the shared file — SEC-F5, and precisely what item 4 exists to fix. **An authentik handler built before item 4 would add per-app keys to a Secret replicated across every namespace.**

#### redis is the better second handler, with one catch

Structurally it is the closest analogue to postgres: connect as admin, create a principal, write a per-app Secret — `ACL SETUSER` in place of `CREATE ROLE`, `REDIS_URL` in place of `DATABASE_URL`. Four consumers share one password today (authentik, openwebui, argocd, nextcloud), so per-app ACL users would be a real isolation gain rather than a rename.

🔴 **The catch has no postgres equivalent: a redis ACL created at runtime lives in memory.** Postgres roles are in the database and survive a restart; redis ACLs are lost unless an `aclfile` is configured. `050-redis-config.yaml` sets `commonConfiguration` (AOF only) and **no `aclfile`** — so a handler written today would provision a user that vanishes on the next pod restart, reporting success.

✅ That is fixable — `aclfile` in `commonConfiguration` plus a writable mount — but it is **a change to how redis is deployed before the handler is worth writing**, the same shape as authentik's mount problem. Both say the same thing: **the handler is the small part.**


