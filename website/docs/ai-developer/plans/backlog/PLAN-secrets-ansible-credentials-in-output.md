---
title: PLAN — credentials printed when an Ansible task fails
sidebar_label: PLAN — credentials in Ansible output
---

# Plan: stop failed Ansible tasks printing the credentials in their command

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — one task fixed (1.6.179), the rest measured and not yet touched

🔵 Filed 2026-10-01 from `urb-agents#1743`, where imac, testing a clean-cluster PostgreSQL deploy, found the superuser password in the output of a *failed* `helm install` and wrote: *"worth a sweep for other tasks with the same shape, not just this one."*

## The defect

Ansible's `command` and `shell` modules, on failure, print the whole `cmd`. Any task that puts a credential in its command line prints that credential when it fails.

🔴 **It only shows on failure**, which is why it survived: a deploy that works first time never shows it, and a failed one is exactly the output an agent transcript, a CI log or a pasted bug report keeps. imac measured it on 2026-09-30: a DNS timeout fetching the chart, one minute after a VM rebuild, printed `--set auth.postgresPassword=<the real value>`, confirmed by direct comparison against `urbalurba-secrets` and never printed elsewhere.

⚠️ It is also visible in the host's process list while the task runs, because the value travels as an argument. `no_log` does not fix that part.

## What is measured

A scan of every playbook under `ansible/playbooks` for tasks that run a command containing a credential and carry no `no_log: true`. Run 2026-10-01, before the 040 fix:

| | |
|---|---|
| tasks flagged | **83**, across **22** playbooks |
| after fixing `040-database-postgresql.yml` task 7 | **82** |
| `PGPASSWORD=` in the command | 39 |
| `{{ … password / secret / token / api_key … }}` interpolated | 40 |
| `--set …password…=` on a Helm command | 3 |

Largest: `u02-verify-postgres` (15), `u07-setup-unity-catalog-database` (9), `u07-verify-qdrant` (9) and `-tasks` (8), `u08-verify-mysql` (6), `650-setup-backstage` (5), `050-setup-redis` (4), `641-adm-pgadmin` (4).

⚠️ **This is a heuristic scan, not an audit.** It matches patterns in the task text. I sampled one row in seven and every sampled row was a real credential-carrying command (a Redis Helm install, `psql` calls, API-key `curl`s), but **I did not review all 82 individually**, so some `{{ …token… }}` matches may carry nothing secret, and a credential passed some way the patterns do not match is invisible to it.

🔴 **The scan also only looked inside `command`/`shell`/`raw` tasks, and that is too narrow - found while writing the equivalent check for the new Garage service.** Ansible can echo any module's arguments on failure, not only a command module's argv: a `kubernetes.core.k8s` task whose `definition:` carries a secret leaks it the same way. Mutation-testing the Garage version of this check against its own `no_log` proved the narrower pattern blind to it - removing `no_log` from a `k8s` task changed nothing the old pattern saw. **So 82 is a floor, not the count** - a second pass scanning every module, not just the three command-shaped ones, is needed before this plan's numbers are trusted. None of the fixes already shipped (1.6.179's tasks 7/8d) are affected; they are command tasks and were checked correctly.

## 🔴 Why this is not a one-line edit

`no_log: true` on a failing task replaces the leak with *"the output has been hidden because of no_log"* and **no cause**. That is the defect this repository spends most of its time on — a command that fails and says nothing useful — and `070-verify-authentik` task 16 cost two releases for exactly that reason.

So each task needs the whole pattern, which `040-database-postgresql.yml` now has:

```yaml
- name: "N. The command"
  ansible.builtin.command: …
  no_log: true
  failed_when: false
  register: result

- name: "Na. Fail if it did not succeed"
  ansible.builtin.fail:
    msg: |
      … failed (rc={{ result.rc }}).
      {{ (result.stderr | default('')) | replace(the_secret, '********') | trim }}
  when:
    - result.rc is defined
    - result.rc != 0
```

Three details that were each wrong in a first draft:

- `rc is defined`, because a task skipped by `when:` registers no `rc`
- **redact the secret from the stderr being shown** rather than trusting the tool not to echo it
- `no_log` hides the task result **and its `environment:`**, so check that `KUBECONFIG` was not dropped along the way

## Work

- [x] 1.1 `040-database-postgresql.yml` — task 7 (the base install imac leaked from) and task 8d, with `test-postgres-deploy-does-not-log-the-password.sh` (7 assertions, 6 mutations caught)
- [ ] 1.2 🔴 **Deploy and setup playbooks first** — these run on every `uis deploy`, so a failure there is the likely one: `050-setup-redis`, `650-setup-backstage`, `340-setup-openmetadata`, `620-setup-nextcloud`, `641-adm-pgadmin`, `210-setup-litellm`, `320-setup-unity-catalog`, `350-setup-jupyterhub`, `080-setup-rabbitmq`, `070-setup-authentik`
- [ ] 1.3 Verify and test playbooks second — `u02`, `u07`, `u08`, `*-test-*` — run on demand, but they do print the same credentials
- [ ] 1.4 A **ratchet** test: the current findings become an allowlist that may only shrink, so a new credential-carrying command without `no_log` fails CI. Same shape as `test-forwarded-env.sh`'s exemption list, including *"no exemption is stale"*
- [ ] 1.5 For the three `--set` Helm installs and anything else that can take a values file: pass the secret on **stdin** (`-f -`) instead of argv, which also closes the process-list exposure that `no_log` cannot

## Not decided here

- Whether the process-list exposure of `PGPASSWORD=` inside `kubectl exec` (host *and* pod) is worth closing, or accepted as the cost of local development. It is real, and it is a different fix from `no_log`.
- `DEFAULT_DATABASE_PASSWORD` is a shared default that seeds the PostgreSQL superuser, MinIO's root and four other namespaces' credentials. Printing it is worse than printing a per-app secret, but **rotating or scoping it is a separate, larger decision** and is already with Terje.
