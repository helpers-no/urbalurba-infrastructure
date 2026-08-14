# Investigate: OpenBao — deployable on a laptop, and the same interface in production

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-08-14

## Status: Backlog

---

## Background

OpenBao holds this installation's platform secrets, including the vault recovery
keys. It is the **only** Odin component with neither a UIS service definition nor
an investigation of its own — built entirely by hand, so a rebuild reconstructs it
from memory.

[Principle 0](../../../contributors/rules/kubernetes-deployment.md) requires that
every service be deployable on Rancher Desktop with `uis deploy <id>` and nothing
else. OpenBao is currently deployable nowhere.

The obvious move is to reuse the proxy convention that shipped for PostgreSQL and
MinIO ([PLAN-system-external-services-001](../completed/PLAN-system-external-services-001-proxy-convention.md)).
**Measuring the actual setup shows that convention does not fit**, for three
independent reasons.

---

## Part 1: Findings (measured 2026-08-14)

### BAO-F1 — Nothing in the cluster talks to OpenBao except ESO

The reference installation runs External Secrets Operator, with a single
`ClusterSecretStore` named `openbao`:

```
server   https://192.168.68.77:8200
path     platform          (KV v2)
auth     kubernetes, role "eso", SA external-secrets/external-secrets
caBundle pinned (the private CA below)
```

Applications never speak to OpenBao. They read **ordinary Kubernetes Secrets**,
which ESO materialises from `ExternalSecret` resources — one in use today,
`default/cloudflare-from-vault`, Ready.

**So the interface that must be identical across topologies is not a Service
address. It is the `ClusterSecretStore` named `openbao` and the `ExternalSecret`
API.** That is a materially different contract from `PGHOST=postgresql.default`,
and it is a *better* one: an in-cluster OpenBao in dev needs only to be reachable
by ESO under the same store name, and every `ExternalSecret` keeps working
untouched.

### BAO-F2 — The proxy pattern breaks on TLS, by construction

Unlike PostgreSQL and MinIO, OpenBao does not speak plain TCP. It terminates TLS
with a private CA:

```
subject  CN = bao
SANs     IP 192.168.68.77, IP 127.0.0.1, DNS bao, DNS bao.local
```

**No SAN covers any in-cluster name.** A socat proxy presented as
`openbao.<ns>.svc.cluster.local` would serve a certificate that does not match the
name the client dialled, so verification fails. The options are all bad in
different ways — disable verification (defeats the point for a secret store),
re-issue the cert with in-cluster SANs (couples the external component to cluster
naming), or terminate and re-originate TLS at the proxy (the proxy sees plaintext
secrets).

ESO today sidesteps this entirely by dialling `https://192.168.68.77:8200`
**directly**, with the CA pinned. There is no OpenBao proxy on the reference
installation, and that is the correct call.

### BAO-F3 — The auth path runs INTO the cluster, not out of it

`kubernetes` auth means OpenBao validates ServiceAccount tokens by calling the
cluster's `TokenReview` API. `.uis.extend/bao-reviewer.yaml` exists to enable
exactly that: a `bao-auth-reviewer` ServiceAccount in `external-secrets`, bound to
`system:auth-delegator`, with a long-lived token handed to OpenBao.

So the dependency is **bidirectional**: the cluster reaches OpenBao for secrets,
and OpenBao reaches the cluster to authenticate the caller. A proxy addresses only
the first direction and would leave the second untouched — and on a laptop, an
external OpenBao would need a route back into Rancher Desktop's API server, which
is not generally reachable.

This is the strongest argument for **running OpenBao in-cluster in dev** rather
than proxying to something external.

### BAO-F4 — Production auto-unseals from a static key on local disk

```
storage  raft, /var/lib/openbao/data, node_id "bao"
seal     static, key file /etc/openbao/seal/unseal-2026-08.key (0400, 32 bytes)
```

A static seal is what makes it survive reboots without human intervention. The
key ID is dated (`2026-08`), implying an intended rotation cadence that nothing
currently enforces.

For dev this is *good news*: a laptop instance can generate its own throwaway
static key at deploy time and come up unsealed with no wizard, no manual step, and
no shared secret with production.

---

## Part 2: What "OpenBao on a laptop" has to mean

1. **`uis deploy openbao` yields a working, unsealed OpenBao in-cluster**, with no
   manual unseal and no browser step.
2. **The same `ClusterSecretStore` name (`openbao`)**, so every `ExternalSecret`
   resolves identically in dev and production. This is the interface — not an
   address.
3. **Dev secrets are not production secrets, and that is correct.** A laptop
   instance is empty; the platform must seed whatever a developer needs to run the
   stack. What seeds it, and from where, is Q2 below.
4. **Production keeps what it has.** OpenBao stays on CT 108 for the reasons in
   BAO-F2 and F4; this work must not migrate it into the cluster.
5. **Never require the developer to hold production secrets** to run a local
   stack. If local development needs the real Cloudflare token, the design is
   wrong.

---

## Part 2b: The developer's case — three options

**Scope.** Only one scenario is in scope: a developer, or a service they are
working on, **needs secrets** — OpenBao is a dependency, not the thing being
developed. Developing *on* OpenBao itself is explicitly out of scope.

That reframes the problem, because **dev already works without OpenBao today**:
`urbalurba-secrets` holds 53 keys as an ordinary Kubernetes Secret and
applications read it directly. So the question is not "how do we run OpenBao on a
laptop" but **"what does a laptop need so that a service depending on secrets
behaves the same way it will in production."**

The relevant split: **a developer writes `ExternalSecret`s; the platform writes
the `ClusterSecretStore`.** ESO ships 43 providers, including `vault`,
`kubernetes` and `fake` — verified on the reference installation — so the store
can be satisfied more than one way.

### Option A — no OpenBao in dev (status quo)

| Pro | Con |
|---|---|
| Nothing to run; already works | **Dev and prod manifests differ** — the artifact a developer writes is never tested |
| Zero startup cost and memory | A wrong `ExternalSecret` is discovered *in production* |
| No unseal, no seeding | Fails Principle 0: the service is deployable nowhere |

### Option B — OpenBao + ESO in-cluster, full fidelity

| Pro | Con |
|---|---|
| Identical manifests **and** identical mechanics | Two more components on every laptop |
| Exercises KV v2 paths, `kubernetes` auth, TLS/CA | Unseal + seeding needed on every fresh cluster |
| Satisfies Principle 0 in the strongest sense | **Blast radius**: a failed unseal blocks *every* developer, including those who never touch secrets |

### Option C — ESO in dev with the `kubernetes` provider, same store name

`ClusterSecretStore openbao` exists locally, but its provider reads from
`urbalurba-secrets` rather than a vault.

| Pro | Con |
|---|---|
| **The developer's artifact — the `ExternalSecret` — is byte-identical dev↔prod** | The `vault` provider path (KV v2, auth, TLS) is not exercised locally |
| No OpenBao to run, unseal or seed — one component, not two | Two store configurations to keep in step |
| Dev credentials stay in `urbalurba-secrets`: one source of truth, already present | Could give false confidence if the difference is forgotten |
| Only the **provider block** differs, which is exactly where per-installation difference belongs | |

### Recommendation: C, with B available later

C exercises the developer's artifact completely and leaves only the platform's
single object — the store — untested locally. That object is tested once, on the
reference installation, rather than per service.

It is also the same principle the proxy convention settled on: **ship the shape,
let the installation supply the provider.** Here the shape is the `ExternalSecret`
plus the store *name*; the provider block is topology.

B remains worth doing for anyone who needs real vault semantics, but making it
mandatory means a broken unseal on a laptop blocks people who only wanted to run a
web application.

**Consequence: this makes ESO — not OpenBao — the component that must become a UIS
service first.** Under C, OpenBao may never need to run on a laptop at all, which
answers Q5 and narrows Q1–Q3 to "only if B is chosen".

---

## Part 3: Open questions

- **Q1 — Which storage in dev?** *(only if Option B)* `raft` matches production but persists via a PVC
  that survives `uis undeploy`. `inmem` is genuinely disposable but loses
  everything on pod restart, which will surprise people mid-session. Leaning raft
  on a PVC, with `--purge` removing it.
- **Q2 — What seeds a laptop instance?** *(only if Option B; under C the answer is `urbalurba-secrets`, unchanged)* Nothing useful happens with an empty
  vault. Options: seed from `urbalurba-secrets` (the platform's existing
  local-dev credential set, already full of `LocalDev...` placeholders), or ship
  a `.uis.extend/vault-seed.yaml`. The first keeps one source of truth for dev
  credentials; the second adds a second place to look.
- **Q3 — Does dev use `kubernetes` auth too, or a root token?** *(only if Option B)* Matching
  production's auth method is more faithful and exercises the same code path, but
  it needs the auth mount plus a role configured at deploy time. A dev root token
  is simpler and less faithful.
- **Q4 — What owns `bao-reviewer.yaml` and `eso-store.yaml`?** Both are hand-built
  on the reference installation. They are the *external* half of the contract, so
  they likely belong to whichever plan makes the external topology declarative —
  not to the in-cluster dev deployment.
- **Q5 — Is ESO itself a UIS service?** **Answered by Part 2b: yes, and it is the prerequisite.** It is installed on the reference
  installation but, like OpenBao, has no service definition. A laptop needs ESO
  before `ClusterSecretStore` means anything, so this may be a prerequisite plan
  rather than part of this one.
- **Q6 — Rotation.** The seal key is stamped `2026-08` with nothing enforcing
  rotation. Out of scope here, but it should not stay invisible.

---

## Part 4: Relationship to the external-services convention

[PLAN-system-external-services-001](../completed/PLAN-system-external-services-001-proxy-convention.md)
shipped a transparent proxy so a service can be external in production and
in-cluster in dev behind one address. **OpenBao is the case that shows the
convention has a boundary**, and finding that boundary is useful rather than
disappointing:

| | postgresql / minio | openbao |
|---|---|---|
| protocol | plain TCP | TLS, private CA |
| consumers | many apps, direct | one (ESO); apps read k8s Secrets |
| identical interface | the Service address | the `ClusterSecretStore` name |
| auth direction | outbound only | **bidirectional** (TokenReview) |
| fits the proxy? | yes | **no** |

The proxy convention is for services whose contract is *an address*. OpenBao's
contract is *an API object*, and the parity it needs comes from naming that object
identically — which is cheaper and safer than proxying.

---

## Part 5: Proposed plans (draft after the questions above are answered)

1. **ESO as a UIS service** *(if Q5 says prerequisite)* — a laptop needs it before
   any of this means anything.
2. **OpenBao in-cluster for dev** — deploy, auto-unseal from a generated static
   key, expose `ClusterSecretStore openbao`, seed from the platform's existing dev
   credentials. The only plan that satisfies Principle 0 for this service.
3. **Make the production topology declarative** — `bao-reviewer.yaml` and
   `eso-store.yaml` stop being hand-built files on one machine. Includes deciding
   whether the external store is declared through
   `.uis.extend/external-services.yaml` or a mechanism of its own, given BAO-F1
   says its contract is not an address.
