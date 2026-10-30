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
A GitHub Personal Access Token must be configured first — the `GITHUB_ACCESS_TOKEN` secret
(`uis secrets edit`), the same one `uis argocd register` uses for private-repo access. It needs the
`Administration` repository permission (fine-grained) or classic `repo` scope. Used once per
registration, to mint a short-lived registration token via GitHub's own API; the PAT itself is
never stored in the cluster.

Register a runner instance against a target repository:

```bash
./uis github-runner register bifrost terchris/bifrost
```

### Running more than one instance on the same cluster

One cluster can run a separate, fully independent runner for each repo that needs one — pick a
new `<instance>` slug (lowercase alphanumeric and hyphens only) to register a second (or third,
...) instance alongside any already running, without touching it:

```bash
./uis github-runner register other-repo owner/other-repo
./uis github-runner list      # every instance + the repo it serves
./uis github-runner remove other-repo
```

Every instance shares the one `github-runner` namespace; `register` refuses to apply if that
instance name is already serving a *different* repo (`--force` to deliberately retarget it).
`remove` only removes the named instance — never any other — and only deletes the namespace itself
once none are left in it.

⚠️ Sharing a namespace is not full isolation — every instance's `dind` sidecar is still
`privileged: true`, and two repos' runners sharing this namespace share the same RBAC/
NetworkPolicy boundary that namespace provides, nothing stronger.

The original/default instance (urb-agents' own, predating this) isn't managed through these
subcommands — see `ansible/playbooks/645-setup-github-runner.yml`'s own header if it ever needs to
be redeployed directly.

## Undeploy

```bash
./uis undeploy github-runner
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official GitHub Runner documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
