# INVESTIGATE backlog — priority view

**Purpose**: triage tool, not a roadmap. Decides *what to investigate next* — not *what to build next*. The 35 INVESTIGATE files in `backlog/` were written at different times for different reasons; this doc separates the ones ready to be done from the ones that should wait, and orders the ready ones by what they unblock.

**Last updated**: 2026-08-11. Re-rank whenever an INVESTIGATE moves to `completed/`, a child PLAN ships, or a new INVESTIGATE lands.

**How to read the tiers**: tier order is the order to *start* the investigation, not the order to *finish*. Tier 1 means "next on deck"; Tier 4 means "don't open this yet — wait for prereqs or product clarity." Tier 0 is "in flight — no fresh investigation work needed but the file still lives here because work isn't fully shipped."

**UIS lifecycle convention**: an INVESTIGATE moves from `backlog/` to `completed/` once every child PLAN has shipped (or the investigation is otherwise closed). Once moved, it disappears from this doc — see [`completed/`](../completed/index.md) for the historical list.

---

## What changed in this refresh (2026-05-07 → 2026-08-11)

The doc had gone three months without a re-rank, against a rule that says re-rank
whenever a plan ships. In that window 12 investigations landed and roughly 9 plans
shipped, so the triage view had drifted badly from the repo:

- **12 investigations were missing entirely**, including the two driving all
  current work — `system-observability` and `service-uptime-kuma`. The doc claimed
  25 files; there were 35.
- **One row pointed at a file that had already shipped**: `cli-undeploy-purge-flag`
  now lives in `completed/`. Row deleted per rule 4.
- **`system-verification-playbooks-usage` is promoted from Tier 2 to Tier 1.** It
  predicted, in March, the exact defect found on 2026-08-11: a verify playbook
  present in the repo and wired into nothing. See its Tier 1 entry.
- **Tier 0 grew from 3 rows to 7** — it was hiding how much is genuinely in flight.

---

## Tier 0 — in flight

INVESTIGATEs that still live in `backlog/` because their work isn't fully shipped yet — either active on a feature branch, or investigation-complete and waiting for a child PLAN to be drafted. No fresh investigation work needed; listed here so the priority view surfaces what's already moving. Items whose child PLANs have all shipped are not listed — they're in [`completed/`](../completed/index.md).

| Investigation | Child plans | State |
|---|---|---|
| [system-observability](INVESTIGATE-system-observability.md) | 6 in `backlog/` (001 log-collection, 002 alert-baseline, 003 service-dashboards, 004 external-targets, 006 service-probes, grafana-deploy-gate-fix) | **The largest thing in flight.** Deployed and delivering on the reference installation; work sits on branch `plan/observability-alert-baseline`, unmerged. 001–004 are each partly open (retention decision, cert expiry, `uis deploy` wiring, phases 2–4). 006 is 0/27. |
| [service-uptime-kuma](INVESTIGATE-service-uptime-kuma.md) | 2 in `active/`, 2 in `backlog/`, 1 shipped | Deployed on **assist** with 19 monitors reconciling. Its own 002 plan records the gap that matters: **nothing notifies** — no job calls the push URLs. Do not close this investigation until that is either done or split out. |
| [service-litellm-install-reliability](INVESTIGATE-service-litellm-install-reliability.md) | 3 in `backlog/` (002 version-pinning, 003 undeploy-purge, 004 config-portability), 1 shipped | 001 schema-verify shipped; the remaining three are drafted and unstarted. |
| [system-platform-provisioning-layer](INVESTIGATE-system-platform-provisioning-layer.md) | 1 in `backlog/` (aks-001b manual-setup), 2 shipped | Status ACTIVE, AKS-focused. Step 1 verified end-to-end 2026-05-11 against a real Azure subscription; `platforms/azure-aks/` is the production path. Next concrete work: Step 2 (start/stop/scale so the cluster doesn't bill 24/7). |
| [cli-stack-profiles](INVESTIGATE-cli-stack-profiles.md) | 1 in `backlog/` (grafana-optional-datasources) | The child plan is blocking: no `--profile` below `full` can install until it ships, and `uis stack install observability --skip-optional` is broken today (CLI-F1). |
| [service-authentik-user-config](INVESTIGATE-service-authentik-user-config.md) | none drafted | Investigation Complete — Ready for PLAN. Unblocks Tier 3 backstage-auth. |
| [system-remote-deployment-targets](INVESTIGATE-system-remote-deployment-targets.md) | none drafted | Investigation Complete. Child PLAN drafting next; do not open as new investigation work. |

## Tier 1 — do next (load-bearing or unblocks active work)

| # | Investigation | Effort | Why this tier |
|---|---|---|---|
| 1 | [secrets-template-defaults-clarity](INVESTIGATE-secrets-template-defaults-clarity.md) | S | Foundational fix to the secrets workflow every service depends on. The current silent-overwrite confusion between `00-common-values.env.template` and `default-secrets.env` produces bug reports from contributors and slows every onboarding. Investigation already half-shipped via the existing template scaffolding; closing it out is a small read-and-decide. |
| 2 | [verification-playbooks-usage](INVESTIGATE-system-verification-playbooks-usage.md) | M | **Promoted from Tier 2 on evidence.** Written 2026-03-12, it states the risk as "verification playbooks present but not wired into active setup or test flows → deployments report success when no real validation happened." On 2026-08-11 exactly that was found twice: `031-test-alloy.yml` was reachable by no command at all, and uptime-kuma's verify was invisible to `test-all`. Both are now fixed, but ad-hoc — this investigation is the systematic version, and it has two free worked examples waiting for it. **Stays Tier 1, not Tier 0, on purpose**: it has two child plans, but they are point fixes to the two services that happened to break, not the investigation's output. The question "which services have verification, and what shape verifies what" is still entirely unanswered. |
| 3 | [uis-deploy-no-playbook-semantics](INVESTIGATE-cli-deploy-no-playbook-semantics.md) | S | Genuine ambiguity in the deploy code today: services with `SCRIPT_PLAYBOOK=""` produce undefined behaviour. Affects every "metadata-only" service. Investigation gap is small; pinning the contract removes a class of latent bugs across all current and future services. |
| 4 | [uis-deploy-auto-regen-secrets](INVESTIGATE-cli-deploy-auto-regen-secrets.md) | M | UX gap that bites tester loops repeatedly: stale `kubernetes-secrets.yml` produces silent failures. Decisions here lock down idempotency for the whole deploy command. Tester-feedback-driven; high payoff per hour. |

## Tier 2 — do after Tier 1 (independent, ready, valuable)

| # | Investigation | Effort | Why this tier |
|---|---|---|---|
| 5 | [in-cluster-port-on-services](INVESTIGATE-docs-services-in-cluster-port.md) | S | Small `services.json` schema addition that downstream consumers (Backstage catalog, docs generator, future MCP integrations) keep working around. Cheap to land; immediate downstream payoff. |
| 6 | [version-pinning](INVESTIGATE-system-version-pinning.md) | M | Cross-cutting consistency review: which services have pinned image tags vs `:latest`. Affects supply-chain hygiene and CI reproducibility. Independent of other tiers; ships value on its own. |
| 7 | [service-version-metadata](INVESTIGATE-system-service-version-metadata.md) | M | Tied to docs/CLI display: how service scripts expose version info. Closes a presentation gap visible on every service page. Pairs naturally with #6 if done together. |
| 8 | [system-backup-and-scheduling](INVESTIGATE-system-backup-and-scheduling.md) | M | **Newly triaged.** Backup + scheduled-job story for the platform. Load-bearing in the same way #2 is: an unverified backup and an unwired verify playbook fail identically — silently, and only when you need them. Ranks below Tier 1 only because no current work is blocked on it. |
| 9 | [system-registry-cache](INVESTIGATE-system-registry-cache.md) | M | **Newly triaged.** Pull-through image cache. Independent, self-contained, and pays off on every cluster rebuild — which the platform does often by design. |
| 10 | [uis-connect-commands](INVESTIGATE-cli-connect-add.md) | M | User-facing convenience: `uis connect <service>` opens an interactive client without requiring host-side tooling. Independent of platform/deployment tiers; shippable as a self-contained slice. |
| 11 | [cli-grammar-harmonization](INVESTIGATE-cli-grammar-harmonization.md) | M | **Newly triaged.** Consistency of the `uis <verb> <noun>` surface. Related in spirit to #2: the verify command exists in two grammatical forms (`uis verify alloy` and `uis alloy verify`), which is precisely how the registration defect stayed hidden. Worth doing before the CLI surface grows further. |
| 12 | [cli-top-level-doc](INVESTIGATE-cli-top-level-doc.md) | S | **Newly triaged.** One coherent top-level CLI reference. Small, and the 2026-08-11 help-text gaps (three services dispatching correctly but undocumented) show the current help is maintained by hand and drifts. |
| 13 | [docs-markdown-update-logic](INVESTIGATE-docs-markdown-update-logic.md) | M | Improves the docs-generation pipeline so metadata-driven sections update without overwriting manual prose. Quality-of-life for contributors maintaining service pages. |
| 14 | [cli-network-export-import](INVESTIGATE-cli-network-export-import.md) | M | **Newly triaged.** Moving network config between installs. Ready but not blocking anything; sits at the bottom of Tier 2 until a concrete consumer pulls on it. |

## Tier 3 — defer until prereqs ship

These have known prerequisites that are still open. Don't open them yet — the prereq's outcome materially changes the investigation's scope.

| # | Investigation | Waits on | Why defer |
|---|---|---|---|
| 15 | [backstage-auth](INVESTIGATE-service-backstage-auth.md) | authentik-user-config (Tier 0, ready for PLAN) | Adding Authentik OIDC to Backstage assumes Authentik's user-config story is settled. Open the auth investigation only after the user-config PLAN has shipped, otherwise the OIDC client config keeps shifting. |
| 16 | [provision-host-tools-and-auth](INVESTIGATE-system-provision-host-tools-and-auth.md) | platform-provisioning-layer (Tier 0, in flight) | Decisions about which CLIs (Azure / AWS / GCP / Terraform) live inside `uis-provision-host` depend on the platforms model that the active feature branch is still settling. Designing tool-install + auth-state before platforms lock in = rework. |
| 17 | [monitor-definitions-with-services](INVESTIGATE-system-monitor-definitions-with-services.md) | observability 003 + 006 (Tier 0) | **Newly triaged.** Shipping monitor/probe definitions alongside each service shares an artifact convention with observability's dashboards (003) and probes (006). Both are open and still deciding that convention; designing a third consumer first guarantees rework. |
| 18 | [migrate-hosts-to-platforms](INVESTIGATE-system-migrate-hosts-to-platforms.md) | platform-provisioning-layer (Tier 0, in flight) | Includes the documentation migration, folded in deliberately — the code and docs sides belong together. Waits on the same platforms model as #16. |
| 19 | [tailscale-cross-cluster-backbone](INVESTIGATE-network-tailscale-cross-cluster-backbone.md) | platform-provisioning-layer; a real second site | **Newly triaged.** Cross-cluster networking is only designable once there is a second cluster that must be reached the hard way. Related to the Oslo+Bodø multi-site intent, which is not yet built. |
| 20 | [dct-argocd-deploy](INVESTIGATE-service-argocd-dct-deploy.md) | argocd as a stable UIS service | The "deploy from inside DCT with one command" flow needs argocd to be the deployment substrate. ArgoCD has a manifest in UIS but isn't an everyday service yet; investigate this once argocd is operationally normal. |
| 21 | [enonic-deployment](INVESTIGATE-service-enonic-deployment.md) | enonic-as-stable-service | Covers both apps (JAR pipeline — chosen-approach decided) and content (still open). Pull-based deployment design assumes Enonic XP is operationally stable in UIS. Merged from the two earlier app + content investigations on 2026-05-15. |
| 22 | [email-smtp-service](INVESTIGATE-service-email-smtp.md) | product clarity (which services need email first?) | Cross-cutting platform service. Worth opening only when the first concrete consumer (Authentik password resets? a notification path?) is actually pulling on it. |

## Tier 4 — ideas, not investigations

These are sketches / parking-lot entries, not concrete research targets. Don't open them as INVESTIGATEs — let the surrounding context resolve, then either promote to a real INVESTIGATE or delete.

| # | Item | What to do |
|---|---|---|
| 23 | [espocrm](INVESTIGATE-service-espocrm.md) | Currently four URLs and zero analysis. Either promote to a real INVESTIGATE (with a goal + comparison against alternatives) or delete. |
| 24 | [dagster](INVESTIGATE-service-dagster.md) | Broad research file, not a concrete platform decision. Wait for the data-orchestration use case (atlas's deployment-pipeline INVESTIGATE on the atlas side waits on UIS for this signal) to materialise into a real consumer; then open as a focused investigation. |
| 25 | [metabase](INVESTIGATE-service-metabase.md) | Similar to #24 — internal BI / data exploration tool selection. Hold until there's a concrete first consumer driving the requirements. |
| 26 | [customer-onboarding-database](INVESTIGATE-docs-customer-onboarding-database.md) | **Newly triaged.** Self-described as "Draft / not yet scheduled." Leave as a sketch until there is a real customer-onboarding flow to design against. |

---

## Ready to move to `completed/`

Every declared child PLAN has shipped. Per rule 4 these should be `git mv`'d and
their rows deleted from this doc — listed rather than moved because moving files
is a git operation.

| Investigation | Child plan that shipped |
|---|---|
| [service-backstage-enhancements](INVESTIGATE-service-backstage-enhancements.md) | `PLAN-004-backstage-api-entities` |
| [templates-first-uis-template](INVESTIGATE-templates-first-uis-template.md) | `PLAN-002-uis-template-command` |

## Housekeeping found during this refresh

- **The parent-link key is not consistent**, so plans go missing from any triage
  that walks it. PLANS.md's template says `**Investigation**:`, but
  `PLAN-system-observability-006-service-probes` legitimately has two parents and
  writes `**Investigations**:` (plural). Two parents is a real case the template
  does not cover — the convention should name both keys rather than the plural
  form being treated as a mistake.
- **`PLAN-service-uptime-kuma-005-ship-the-pipeline` genuinely has no parent
  link** — it declares Prerequisites and Related but never its investigation.
  It is also `## Status: Active` while sitting in `backlog/`, making it the
  seventh plan claiming Active.
- **Six plans carry `## Status: Active`** while PLANS.md says 1–2 at a time, and
  four of those sit in `backlog/` rather than `active/`. The folders no longer
  describe reality — worth a pass before starting anything new.

## Cross-cutting notes

- **Two natural workstreams**: UIS-internal correctness (Tier 1) and developer-experience polish (Tier 2, items #5–#14). They can run in parallel — different files, no merge contention.
- **The verification thread**: #2 (verification-playbooks-usage), #11 (cli-grammar-harmonization) and #12 (cli-top-level-doc) are three views of one problem — the CLI surface and its test wiring are maintained by hand and drift silently. Doing #2 first gives the other two concrete evidence to work from.
- **Backstage cluster**: Backstage core (shipped) → #15 (auth) → enhancements (ready to move to `completed/`). 
- **Platform/host cluster**: Tier 0 platform-provisioning-layer (in flight) → #16 (provision-host tools) → #18 (host migration) → #19 (cross-cluster backbone). Tight chain; resolve in order.
- **Observability cluster**: Tier 0 system-observability is the bottleneck for #17 (monitor definitions) and shares an artifact convention with it. Finish 003/006 before opening #17.
- **External coupling with atlas**: atlas's deployment-pipeline investigation explicitly waits on UIS's dagster signal. Resolving #24 unblocks atlas's deployment-pipeline; deferring it keeps that block in place — fine if no UIS consumer is pulling on dagster yet, but worth flagging when atlas next asks.
- **Idea-vs-investigation ratio**: 4 of 35 are still ideas (Tier 4). Healthy — most of the backlog is concrete work, not brainstorm residue.
- **Investigation-completion debt**: 2 of the 7 Tier-0 entries (remote-deployment-targets, authentik-user-config) are "investigation complete" without a child PLAN drafted. Picking one up as the next PLAN-drafting task closes more uncertainty than starting any Tier-1 investigation.

## How to use this doc

1. Pick the top unstarted item from Tier 1; if all of Tier 1 is in flight or done, move to Tier 2.
2. When starting an INVESTIGATE, leave it in this folder and update its `Status:` line to note the work is in flight.
3. When an INVESTIGATE produces a recommendation and a child PLAN is drafted, update this doc: move the row to Tier 0 and note the PLAN it spawned.
4. When every child PLAN of an INVESTIGATE has shipped, `git mv` the file to `completed/`, fix any cross-references, and **delete** its Tier 0 row from this doc — `completed/index.md` carries it from then on.
5. When a Tier-3 prereq lands, promote its dependents up to Tier 2 in the next refresh.
6. Re-rank quarterly or after every 3 INVESTIGATEs ship — whichever comes first.

### Keeping it current

The May→August drift happened because rules 3 and 4 fire at moments when the
person is thinking about *code*, not about triage. Concrete triggers, so the
update is a step in the work rather than a separate chore:

- **A new `INVESTIGATE-*.md` lands in `backlog/`** → add its row in the same
  commit. An investigation absent from this doc is invisible to triage.
- **A PLAN moves to `completed/`** → check whether its parent investigation has
  any child plans left. If not, move it and delete its row (rule 4).
- **A PLAN is drafted** → move its parent to Tier 0 (rule 3).
- **A new PLAN is written** → give it a `**Investigation**:` header linking its
  parent, or it will not be findable from here.
- **The counts in the header** (`N INVESTIGATE files`) are checkable against
  `ls backlog/INVESTIGATE-*.md | wc -l` — if they disagree, the doc is stale.
