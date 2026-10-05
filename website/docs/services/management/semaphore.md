---
title: SemaphoreUI
sidebar_label: SemaphoreUI
---

# SemaphoreUI

Web UI and API for running Ansible, Terraform, OpenTofu and PowerShell against
your own hosts.

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy semaphore` |
| **Undeploy** | `./uis undeploy semaphore` |
| **Depends on** | None |
| **Required by** | None |
| **Image** | `semaphoreui/semaphore:v2.19.12` |
| **Default namespace** | `semaphore` |
| **Default URL** | `http://semaphore.localhost` |

## What It Does

A **project** is the unit everything else belongs to: a git repository, an
inventory, stored access keys (SSH keys, vault passwords, cloud credentials),
and the playbook **templates** that actually get run. SemaphoreUI executes a
template against its project's repository and inventory, in-cluster, and keeps
a history of every run.

## A clean install has nothing configured

`./uis deploy semaphore` ships **zero** projects, repositories, inventories,
templates or access keys — the same empty-by-default convention as
`dagster-code-locations.yaml`. You get one working admin login and an empty
dashboard; wiring in your own automation (a repository, an inventory, a first
template) is deliberately a manual step done from the UI or its API, not
something a clean install does for you.

## Running in-cluster is not a limitation

Anything a Semaphore playbook reaches over SSH or HTTP — a VM to patch, a
watchdog to notify, an API to call — it reaches identically whether Semaphore
itself runs in a pod or on a dedicated machine. The one job no in-cluster tool
can do is recover the specific cluster its own pod depends on; nothing else
about running Semaphore in-cluster limits what its playbooks can target.

## Deploy

```bash
./uis deploy semaphore
```

No dependencies. Uses SQLite on a `PersistentVolumeClaim` rather than the
shared Postgres — one fewer moving part, and the whole service state is one
file that travels with it if a later install retargets where it runs.

## Verify

```bash
# Quick check
./uis verify semaphore

# Manual check
kubectl get pods -n semaphore

# Health endpoint
curl -s http://semaphore.localhost/api/ping
# Expected: pong
```

Access the dashboard at [http://semaphore.localhost](http://semaphore.localhost),
and log in as `admin` with the shared `DEFAULT_ADMIN_PASSWORD`.

## Admin credentials

It shares the platform admin password rather than defining its own, so there
is one credential to rotate — the same pattern Grafana, ArgoCD and Uptime Kuma
already use.

| Key in `urbalurba-secrets` | |
|---|---|
| `semaphore-admin-user` | `admin` |
| `semaphore-admin-email` | inherits `${DEFAULT_ADMIN_EMAIL}` |
| `semaphore-admin-password` | inherits `${DEFAULT_ADMIN_PASSWORD}` |
| `semaphore-cookie-hash` / `semaphore-cookie-encryption` | sign and encrypt session cookies |
| `semaphore-access-key-encryption` | encrypts every stored credential at rest in Semaphore's own database |

The three internal secrets ship with a fixed development default (see
`provision-host/uis/templates/default-secrets.env`) and are injected as
environment variables rather than written into `config.json` — the same
convention Authentik's and OpenWebUI's secret keys already follow. **Generate
your own for production**: `openssl rand -base64 32`, one value per variable,
set in your own `.uis.secrets/` copy.

:::warning Issued API tokens are stored as the bearer value itself, not a hash
Anyone who can read the database file can use every token directly. This is
upstream's own design, not a UIS defect — worth knowing before you hand a
token to anything you do not fully trust.
:::

## Adding your first project

1. Log in and create a **project** from the UI.
2. Add a **repository** (a git URL) and an **inventory** (the hosts a
   template will run against).
3. Add an **access key** for whatever the repository or inventory needs
   (an SSH key, a vault password).
4. Add a **template**, pointing it at a playbook in the repository.

Or do all of this non-interactively via the CLI (`kubectl exec` into the pod)
or the REST API — see the [official SemaphoreUI documentation](https://docs.semaphoreui.com/).

## Undeploy

```bash
./uis undeploy semaphore            # keeps every project, repository and history
./uis undeploy semaphore --purge    # deletes all of it
```

Keeping the volume means a redeploy lands on existing state; the setup
playbook reconciles the admin password to match `urbalurba-secrets` on every
run, so a changed secret never locks you out after a redeploy.

## Key Files

| File | Purpose |
|------|---------|
| `manifests/630-semaphore-statefulset.yaml` | ConfigMap, PVC, StatefulSet, Service |
| `manifests/630-semaphore-ingressroute.yaml` | Traefik routing (internal only) |
| `ansible/playbooks/630-setup-semaphore.yml` | Deployment playbook |
| `ansible/playbooks/630-remove-semaphore.yml` | Removal playbook |

## Troubleshooting

**Pod won't start:**
```bash
kubectl describe pod -n semaphore -l app=semaphore
kubectl logs -n semaphore -l app=semaphore
```

**Admin login fails after a redeploy:**
The setup playbook reconciles the password on every run; if it still fails,
check `urbalurba-secrets` in the `semaphore` namespace has
`semaphore-admin-user` / `semaphore-admin-password` set, then re-run
`./uis deploy semaphore`.

## Learn More

- [Official SemaphoreUI documentation](https://docs.semaphoreui.com/)
