---
title: Management
sidebar_label: Management
description: Admin tools, developer portal, and GitOps with Backstage, ArgoCD, pgAdmin, and RedisInsight
---

# Management

Admin tools, GitOps, and utility services for managing the UIS platform.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
| [Backstage](./backstage.md) | Developer portal and service catalog | `./uis deploy backstage` |
| [ArgoCD](./argocd.md) | GitOps continuous delivery | `./uis deploy argocd` |
| [pgAdmin](./pgadmin.md) | PostgreSQL web admin | `./uis deploy pgadmin` |
| [RedisInsight](./redisinsight.md) | Redis web admin | `./uis deploy redisinsight` |
| [Nginx](./nginx.md) | Catch-all web server and default backend | `./uis deploy nginx` |
| [Whoami](./whoami.md) | HTTP request test service | `./uis deploy whoami` |
| [External Secrets](./external-secrets.md) | Syncs Secrets from an external store | `./uis deploy external-secrets` |
| [OpenBao](./bao.md) | Secrets management (KV v2, kubernetes auth) | `./uis deploy bao` |

## Overview

- **Backstage** provides a developer portal with service catalog, API documentation, and Kubernetes visibility
- **ArgoCD** automates deployments from Git repositories
- **pgAdmin** and **RedisInsight** provide web interfaces for their respective databases
- **Nginx** serves as the default backend — any request that doesn't match a service gets the Nginx landing page
- **Whoami** is a diagnostic tool for testing ingress and authentication
- **External Secrets** reads `ExternalSecret` resources and syncs them from an external secret store (e.g. OpenBao) into ordinary Kubernetes Secrets
- **OpenBao** is a real in-cluster secrets store (KV v2, `kubernetes` auth), the same interface production's own OpenBao answers
