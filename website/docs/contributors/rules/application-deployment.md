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
| 4 | Per-workload named secrets (`ANALYSIS-nais-uis` §4 item 1) — closes the seam above; the real prerequisite for both external developers **and** whole-lifecycle GitOps | M | not started |
| 5 | *Then* reconsider a UIS `Application` type | L | deferred |

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
