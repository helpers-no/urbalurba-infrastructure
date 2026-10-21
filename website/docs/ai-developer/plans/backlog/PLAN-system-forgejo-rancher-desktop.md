# Plan: Forgejo + its Actions runner, in-cluster (Rancher Desktop)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — five real issues found live by imac across three rounds, all fixed; the git host (steps 1-3) is confirmed working; the runner (steps 4-5) awaits round 4

## Bugs found live (imac, urb-agents#1928) — all fixed

**Round 1:**

1. **Secret generation corrupted every fresh install** — `kubectl run --rm -i` appends
   its own pod-deletion notice onto the SAME stdout being captured, with no delimiter.
   Every one of the three app secrets (`SECRET_KEY`/`INTERNAL_TOKEN`/`JWT_SECRET`) came
   out corrupted on every run; the non-empty-output assert didn't catch it because the
   string wasn't empty, just contaminated. Since these are "generated once, never
   regenerated," this would have been permanent from the first deploy forward. See F2
   above for the fix.
2. **HARD BLOCKER: the ConfigMap-mounted app.ini was never actually read.** `GITEA_APP_INI`
   is a real Gitea Docker convention in general, but this specific rootless image's
   s6-overlay boot path execs `gitea web` directly with no flags and no entrypoint
   script that reads it — confirmed from the real startup log
   (`ConfigFile: /data/gitea/conf/app.ini`, not the ConfigMap's path). The server fell
   back to auto-generating its own config at that default path with `INSTALL_LOCK =
   false`, so the install wizard ran instead of the normal first-boot migration, leaving
   the sqlite DB with no tables (`no such table: user`) — the actual thing blocking
   every downstream step (admin account, runner token), not the secrets.

**Round 1's own fix for Bug 2 (a ConfigMap `subPath` mount directly at the live path)
was itself wrong, and round 2 found why:**

3. **HARD BLOCKER, round 2: a ConfigMap mounted at the live path crash-loops regardless
   of `readOnly`.** `gitea web`'s boot sequence unconditionally runs an internal
   `environment-to-ini` step whenever `GITEA__`-prefixed env vars are present (always
   true here — the three secrets), and that step WRITES the merged config back to the
   resolved app.ini path before serving:
   ```
   environment-to-ini.go [I] Settings saved to: "/data/gitea/conf/app.ini"
   environment-to-ini.go [F] ...: open /data/gitea/conf/app.ini: read-only file system
   ```
   A ConfigMap-backed volume is read-only at the **kernel** level no matter what the
   volumeMount's own `readOnly` field says — there is no manifest tweak that makes it
   writable while still being a direct ConfigMap mount. The Proxmox role's own
   bind-mount never hits this because that's a bare systemd unit invoking the forgejo
   binary directly — no s6, no `environment-to-ini` step at all. Fixed (per imac's own
   suggested direction) by not mounting the ConfigMap at the live path at all: an
   initContainer `cp`s it onto the PVC-backed path as a normal, writable file instead —
   the actual effect the round-1 fix was going for, achieved the way Kubernetes
   requires.

See F1 above for the corrected mechanism (initContainer, not a ConfigMap mount, at the
live path) and F2 for the secret-capture fix.

**Round 2 re-test confirmed the git host (steps 1-3) fully working**: fresh install
migrates correctly (`INSTALL_LOCK=true` honored, real schema, no "no such table"
errors), all three secrets come out clean, admin account creation and runner token
minting both succeed. Round 3 moved on to the runner and found two more real issues:

4. **Documentation bug, not a code bug**: `uis deploy forgejo-runner -- -e
   forgejo_runner_token=...` (this service's own header comment) doesn't exist —
   `uis deploy` has no extra-vars passthrough mechanism at all; an unrecognized flag
   after the service name is silently dropped rather than refused, and a bare `uis
   deploy` (what's left after that) deploys **every** enabled service — a real footgun
   imac hit by hand while testing the (nonexistent) syntax. Fixed the documentation to
   show the actual working form (`ansible-playbook ... -e forgejo_runner_token=...`
   directly); the missing passthrough itself is a genuine `uis deploy` CLI gap across
   every service, not specific to this one, and is better tracked as its own issue than
   folded into this plan.
5. **HARD BLOCKER: the runner container can't reach the dind sidecar's socket — GID
   mismatch.** `fsGroup: 1000` only governs ownership of volume *contents* at mount
   time; it does nothing for a socket `dockerd` creates itself afterward with an
   explicit `chown root:docker`. The dind sidecar's socket is group `docker`
   (gid **2375** in `docker:27-dind`'s own `/etc/group`, measured live); the `runner`
   container's image runs as uid/gid 1000:1000 with no supplementary groups — 1000 and
   2375 never meet. The Kubernetes equivalent of the proven Proxmox role's own `docker
   run --group-add <the socket's real gid, read via stat>` is `supplementalGroups` at
   the Pod level — added here, same property (join the socket's actual group),
   expressed where Kubernetes expects it. ⚠️ 2375 is hardcoded, not discovered at
   template-render time the way the proven role's own `stat` task can (no live cluster
   exists in this environment to stat against) — flagged for re-verification if the
   pinned `docker:27-dind` tag changes.

Also fixed from round-3 evidence: the git host's own deploy summary now shows `su-exec
git forgejo admin user create ...` (confirmed required live — `kubectl exec` alone
runs as this container's own default user, not `git`), not the bare command.

Git host steps (1-3) are confirmed working and do not need re-testing again. Runner
re-verification (`uis deploy forgejo-runner` actually coming up and registering; a real
Actions build+push) is pending round 4 now that the GID fix is in.

**Goal**: Give Rancher Desktop (the laptop/dev UIS target) a working Forgejo git host +
Actions runner, installed the same way as every other UIS service (`uis deploy forgejo`,
`uis deploy forgejo-runner`) — reusing the exact settings already proven on the production
Proxmox install (ops's own IaC), not independently invented ones, so there is no drift in
*functionality* between what a developer tests locally and what a lab owner runs in
production. Requested directly by Terje (2026-10-21), outside the bus, clarified across
several messages — see "What this plan is, precisely" below for the exact framing that
settled it.

**Related**: `PLAN-system-forgejo-core-service.md` (the Proxmox production install — stays
exactly as built, not replaced by this plan), `INVESTIGATE-system-forgejo-runner.md` (the
Proxmox runner — still not built, separate follow-up, NOT this plan), `urb-agents#1910`
(the original CI decision), `urb-agents#1926`/`#1927` (ops's proven reference IaC,
`terchris/home` @ `539c030` — the source this plan translates from)

**Created**: 2026-10-21

---

## What this plan is, precisely (three clarifications it took to land here)

This went through three framings before landing on the right one — worth recording so the
next person doesn't have to re-derive it:

1. First framing: "build Forgejo + runner for Rancher Desktop" — led to an
   independently-researched design (a community Helm chart, SQLite vs bundled Postgres-HA,
   a brand-new digest pin). **Corrected**: "do not invent the forgejo install — it should
   be the same/close to what ops has created." The community Helm chart's own defaults
   were never ops's install; abandoned.
2. Second framing, after reading ops's actual proven IaC (`roles/forgejo`,
   `roles/forgejo-runner`, `roles/epinio-runner`): "the IaC should be the same on both
   targets, no drift" — read, incorrectly, as "retire the Proxmox LXC guest and replace it
   with one unified Kubernetes-only implementation for both targets."
3. **The actual, final framing**: the Proxmox production install (the LXC guest, built in
   `PLAN-system-forgejo-core-service.md`, and its still-unbuilt dedicated-VM runner) stays
   exactly as ops built it — that install IS "what ops has created," referenced
   approvingly, not something to replace. This plan's job is narrower and clearer: make
   Forgejo installable on Rancher Desktop **the same way every other UIS service already
   is** (`uis deploy <service>`), reusing ops's proven *settings* (image version, app.ini
   content, registration flow, the "three secrets generated once" rule) so the two
   installs behave the same, even though the underlying provisioning mechanism
   necessarily differs — a Kubernetes Deployment here, because Rancher Desktop has no
   host-level LXC/VM guest layer to install into at all.

**"No drift" means no drift in behavior** (same Forgejo version, same config, same
registry semantics, same runner registration/execution contract) — not literally one
shared file tree, which Rancher Desktop's complete absence of a host-guest layer makes
impossible regardless of intent.

---

## Part 1: Findings this plan is grounded in

All of F1-F7 below are read directly from ops's proven, live-tested PoC reference
(`terchris/home` @ `539c030`, cloned and read in full — not reconstructed from search
results), cross-checked against this repository's own already-merged
`platforms/proxmox/ansible/roles/forgejo/` (built from the same source, 2026-10-20,
confirmed to still match exactly).

### F1 — Forgejo's own config, reused verbatim where it transfers

`roles/forgejo/templates/app.ini.j2`'s settings (`DB_TYPE = sqlite3`, `INSTALL_LOCK =
true`, `[packages] ENABLED = true`, no admin bootstrap) are reused as-is in this plan's
ConfigMap. The image is the **same pinned digest** as the Proxmox role
(`codeberg.org/forgejo/forgejo@sha256:a3e33d03e771d3e58b27de5573c3a25dc4f670583a6724c1878a6d0bbecf3556`,
`forgejo_version: 16.0.4`) — one version, independently verified once, running
identically on both targets. SSH is the one setting NOT carried over (`DISABLE_SSH =
true` here, vs. the Proxmox role's real git-ssh support) — this phase serves HTTP
clone + the registry only; Traefik's own ingress model in this repository is HTTP(S)-only
by convention, and adding TCP routing for git-ssh is a separate, larger piece of work not
needed for the runner to function. Flagged as a deliberate scope line, not a silent gap.

**How the ConfigMap actually reaches the server — corrected twice, after two live bugs
(see "Bugs found live" below).** Attempt 1 set `GITEA_APP_INI` as an env var, assuming
the general Gitea Docker convention — never consulted by this image's actual s6-overlay
boot path. Attempt 2 bind-mounted the ConfigMap directly at the server's hardcoded
config path (`/data/gitea/conf/app.ini`, via `subPath`), intending to mirror the Proxmox
role's own bind-mount — but a ConfigMap-backed mount is read-only at the kernel level no
matter what, and `gitea web`'s boot sequence writes BACK to that exact path whenever
`GITEA__`-prefixed env vars are present (always true here), so it crash-looped instead.
**What actually works**: an initContainer `cp`s the ConfigMap onto the PVC as a normal,
writable file at that path before the main container starts — the real effect intended
all along, achieved the way Kubernetes requires rather than via a mount flag.

### F2 — The three app secrets: same generator, same "never regenerate" rule

`roles/forgejo/tasks/main.yml` asserts `forgejo_secret_key`/`forgejo_internal_token`/
`forgejo_jwt_secret` are supplied, never defaulted, generated once via `forgejo generate
secret <NAME>` (the image's own tool — `JWT_SECRET` specifically has a documented format
requirement, a base64-encoded 32-byte value, that a hand-rolled `openssl rand -hex` would
not satisfy). This plan's setup playbook (`635-setup-forgejo.yml`) runs that exact
generator, reads any already-set values from the live `forgejo-app-secrets` Secret first,
and only generates what's missing — the same "supplied once, stable forever" contract,
implemented with Kubernetes idioms (a Secret + an idempotency check) instead of a shell
`assert` the operator satisfies by hand. The image reads these three via standard
Gitea/Forgejo environment-variable overrides (`GITEA__security__SECRET_KEY` etc.,
confirmed via `forgejo.org`'s own docs AND confirmed live by imac — this mechanism does
work, unlike F1's `GITEA_APP_INI`) rather than baking them into the ConfigMap.

**How the generator's output gets captured — corrected after a live bug (see "Bugs found
live" below).** The first version ran `kubectl run --rm -i ... -- forgejo generate secret
X` and captured its stdout directly. `--rm -i` appends its own pod-deletion notice onto
that SAME stream with no delimiter, corrupting every one of the three secrets on every
fresh install. Fixed by never combining run + attach + cleanup in one captured command:
launch (no `--rm`, no `-i`), wait for the pod to actually finish, read its logs as an
independent step, delete it as another independent, best-effort step.

⚠️ `kubectl run --rm -i` is a documented gotcha in this repository
(`INVESTIGATE-system-verification-playbooks-usage.md`): it can return rc=0 with empty
stdout if the container outlives the attach. Each generation task asserts non-empty
output before trusting it — not optional, the same lesson that investigation already
paid for once.

### F3 — Health check endpoint, reused exactly

`/api/healthz`, not a guessed path — the same endpoint `roles/forgejo/tasks/main.yml`
verifies against on Proxmox.

### F4 — The runner: host-socket-mount is the proven, chosen approach — NOT DinD, NOT a Kubernetes-native plugin

`roles/forgejo-runner/defaults/main.yml`'s own header is explicit: "HOST DOCKER SOCKET,
NOT DOCKER-IN-DOCKER — the simpler of the two options... Less isolation than DinD, but no
privileged container... acceptable for a single-tenant PoC VM that nothing else runs on."
This was checked against both alternatives explored during this plan's own research:

- **Docker-in-Docker** was explicitly the option the proven reference chose AGAINST on the
  VM, for the same privileged-container reason ops raised again on `urb-agents#1926`.
- **A Kubernetes-native execution mode** does not exist as a mature, built-in
  forgejo-runner feature — confirmed by web research during this plan's drafting. What
  exists is a brand-new (v13.1.0, ~2026-09) *plugin mechanism* allowing custom execution
  engines, and exactly one Kubernetes-executing plugin built on it
  (`sjones512/forgejo-runner-kubernetes`), which describes itself as experimental/
  proof-of-concept: one container image per label only, no services, no multi-image jobs,
  specific job-image tooling requirements. Not adopted here — too immature for a first
  working pass.

**Given both alternatives were set aside by the proven reference itself (for DinD) or by
this plan's own research (for the k8s-native plugin), this plan uses a `docker:dind`
sidecar** — private to the runner's own Pod, nothing else reaches it — as the closest
Kubernetes-native equivalent of "a dedicated Docker daemon nothing else touches," which is
the actual property the Proxmox role's own reasoning cared about, not "a VM" specifically.
Rancher Desktop has no spare dedicated host to mount a *real* socket from; a sidecar
recreates the same isolation property a different way.

### F5 — Registration: the exact proven command, operator-supplied token

`roles/forgejo-runner/tasks/main.yml`'s `register` step (`forgejo-runner register
--no-interactive --instance <url> --token <token> --name <name> --labels <labels>`) is
reused verbatim in this plan's init container, including the deprecation note (the newer
declarative `server.connections`/`token_url: file:...` form was tried first on the proven
reference and failed live with "unauthenticated: unregistered runner," no further
diagnostic signal — not reopened here either). The token is operator-supplied, never
auto-minted by this plan's playbook, same rule the Proxmox role enforces — not the
earlier draft's idea of having the playbook `kubectl exec` into Forgejo itself to mint
one automatically. Minting it still needs a Forgejo admin account to exist first
(`forgejo-cli actions generate-runner-token`, run as the `git` user — "the binary refuses
to run as root," per the proven reference) — same manual-bootstrap precedent as the git
host's own admin account.

### F6 — Config generation: the tool's own generator, one field patched

`forgejo-runner generate-config`, not a hand-written config.yaml — same reasoning as the
proven reference ("the schema is large and version-specific enough that a hand-written
file risks silent drift"). Exactly one field is patched afterward (`docker_host:
"automount"`), the same minimal-patch discipline.

### F7 — The real registry-push gotchas, for whoever writes workflow files against this runner (not this plan's own code)

Three bugs the proven reference found live and documented in
`forgejo-actions-reference/build.yml`'s own comments: the job image's packaged `docker`
CLI is API-incompatible with a modern Docker Engine (install the static upstream binary
instead); the Docker daemon the job talks to needs `insecure-registries` configured for
Forgejo's plain-HTTP registry (this plan's dind sidecar gets this via a `--insecure-
registry` flag, the in-cluster equivalent of the proven reference's `/etc/docker/
daemon.json` task); and the registry enforces `write:package` as a token scope separate
from repo/admin scopes. These are workflow-author-facing, not infrastructure-code
decisions — documented for whoever writes the first real `.forgejo/workflows/*.yml`
against this runner, not implemented as code here.

---

## Part 2: What was actually built

- `manifests/635-forgejo.yaml.j2` — PVC, ConfigMap (app.ini, F1), Service, Deployment
  (`Recreate` strategy — sqlite has no concurrent-writer story)
- `manifests/635-forgejo-ingressroute.yaml.j2` — plain HTTP at `forgejo.localhost`
- `ansible/playbooks/635-setup-forgejo.yml` / `635-remove-forgejo.yml`
- `provision-host/uis/services/management/service-forgejo.sh`
- `manifests/640-forgejo-runner.yaml.j2` — PVC, Deployment (init container: generate
  config + register, F5/F6; `runner` container: the daemon; `dind` container: the private
  sidecar, F4/F7)
- `ansible/playbooks/640-setup-forgejo-runner.yml` / `640-remove-forgejo-runner.yml`
- `provision-host/uis/services/management/service-forgejo-runner.sh`,
  `SCRIPT_REQUIRES="forgejo"`

### What this plan does NOT resolve

Both carried over from `INVESTIGATE-system-forgejo-runner.md`'s own open questions,
answered here only for THIS target's risk profile (a single-developer local cluster), not
re-litigated for Proxmox's:

1. **Privileged DinD sidecar** (F4) — judged acceptable here on the same reasoning the
   proven reference applied to its own host-socket choice (nothing else uses this
   daemon), not a decision Terje needs to make for a laptop dev environment the way he
   did for shared Proxmox infrastructure.
2. **Network isolation** — a separate `forgejo-runner` namespace from `forgejo` (no
   cross-namespace RBAC grants), not a NetworkPolicy (UIS has none anywhere yet). Real but
   modest, not claimed as complete.

### Still outstanding — NOT this plan

The Proxmox-side Actions runner (`INVESTIGATE-system-forgejo-runner.md`) is still
unbuilt — only the git host (`PLAN-system-forgejo-core-service.md`) exists on Proxmox so
far. Building it is a separate piece of work, translating `roles/forgejo-runner` +
`roles/epinio-runner` (the dedicated-VM firewall precedent) into this repository's
`CORE_SERVICES`/`vm-ensure.yml` mechanism — tracked on that INVESTIGATE doc, not folded
into this one.

### Validation

Same acceptance bar as every other service in this repository: a real Forgejo Actions
workflow file in a real repository on this install runs to completion on this runner —
proven live by imac, not claimed here. Nothing in this plan has run against a live
cluster; this environment has none.

---

## Honest limits of what's in this document

F1-F7 are from ops's actual committed code, read in full from a clone of `terchris/home` @
`539c030` — not from memory, search results, or reconstruction. The one piece NOT
independently re-verified this session: the `docker:27-dind` sidecar image tag (a
reasonably recent, well-known stable tag, not pinned by digest the way the Proxmox role's
own Forgejo image is) and the chart... there is no chart; this plan writes plain
manifests, not a Helm chart, specifically because the earlier Helm-chart framing was the
thing corrected away from. Nothing here has run against a live Rancher Desktop cluster,
which does not exist in this working environment — `imac` is expected to run this for real
before it's considered done.
