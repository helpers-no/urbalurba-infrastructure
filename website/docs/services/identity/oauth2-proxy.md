---
title: oauth2-proxy
sidebar_label: oauth2-proxy
---

# oauth2-proxy

Login gate using an external identity provider

| | |
|---|---|
| **Category** | Identity |
| **Deploy** | `./uis deploy oauth2-proxy` |
| **Undeploy** | `./uis undeploy oauth2-proxy` |
| **Depends on** | None |
| **Required by** | None |

| **Default namespace** | `oauth2-proxy` |

## What It Does

oauth2-proxy authenticates visitors against an external identity provider (GitHub, Google, or any OIDC issuer) and allows through only the people on a configured list. It runs as a Traefik ForwardAuth gate, holds no user records and no persistent state, so it fits the case where the user directory belongs to someone else. It provides authentication only — everyone admitted is equal, with no groups or per-service permissions.

## Deploy

```bash
# Deploy oauth2-proxy
./uis deploy oauth2-proxy
```

## Verify

```bash
# Quick check
./uis verify oauth2-proxy

# Manual check
kubectl get pods -n oauth2-proxy -l app=oauth2-proxy
```

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about oauth2-proxy settings, secrets, and customization options._

## Undeploy

```bash
./uis undeploy oauth2-proxy
```

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

- [Official oauth2-proxy documentation](https://oauth2-proxy.github.io/oauth2-proxy/)
