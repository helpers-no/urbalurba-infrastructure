---
title: GitHub Runner
sidebar_label: GitHub Runner
---

# GitHub Runner

In-cluster GitHub Actions self-hosted runner (CI for GitHub-hosted repos)

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy github-runner` |
| **Undeploy** | `./uis undeploy github-runner` |
| **Depends on** | None |
| **Required by** | None |

| **Default namespace** | `github-runner` |

## What It Does

Registers a GitHub Actions self-hosted runner against an operator-supplied repository, executing workflow jobs via a private docker:dind sidecar — the same proven architecture as forgejo-runner, for GitHubs own (incompatible) runner protocol instead of Forgejos. The SAME Deployment runs identically on Rancher Desktop and on a Proxmox k3s cluster.

## Deploy

```bash
# Deploy GitHub Runner
./uis deploy github-runner
```

## Verify

```bash
# Quick check
./uis verify github-runner

# Manual check
kubectl get pods -n github-runner -l app=github-runner
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
Required at deploy time, via `ansible-playbook playbooks/645-setup-github-runner.yml` directly
(not `./uis deploy github-runner` — see the service script's own header for why):

- `github_runner_repo` — target repository, `owner/repo` form.
- `github_runner_pat` — a Personal Access Token with the `Administration` repository permission
  (fine-grained) or classic `repo` scope. Used once, to mint a short-lived registration token;
  never stored in the cluster.

### Running more than one instance on the same cluster

One cluster can run a separate, fully independent runner for each repo that needs one — add
`-e github_runner_instance="<slug>"` (lowercase alphanumeric and hyphens only) to register a
second (or third, ...) instance alongside any already running, without touching it:

```bash
ansible-playbook playbooks/645-setup-github-runner.yml \
  -e target_host="rancher-desktop" -e github_runner_repo="owner/other-repo" \
  -e github_runner_pat="..." -e github_runner_instance="other-repo"
```

Leave `github_runner_instance` unset for the original/default instance — its resource names never
change. Every instance shares the one `github-runner` namespace; the setup playbook refuses to
apply if an instance name is already serving a *different* repo (pass
`-e github_runner_force=true` only if retargeting that exact instance is actually intended).
Removing one instance (`645-remove-github-runner.yml`, same `-e github_runner_instance=...`) never
touches any other instance, and only deletes the namespace itself once none are left in it.

⚠️ Sharing a namespace is not full isolation — every instance's `dind` sidecar is still
`privileged: true`, and two repos' runners sharing this namespace share the same RBAC/
NetworkPolicy boundary that namespace provides, nothing stronger.

## Undeploy

```bash
./uis undeploy github-runner
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official GitHub Runner documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
