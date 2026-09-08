# INVESTIGATE: Tailscale Cluster-Wide Tunnel Connectivity Timeout

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Diagnose and fix the cluster-wide Tailscale tunnel connectivity timeout (`k8s.dog-pence.ts.net`).

**Last Updated**: 2026-02-23

**Completed**: 2026-02-23 — Root cause identified: Let's Encrypt ACME rate limiting (not a code/config bug).

**Priority**: Medium — per-service Funnel works perfectly, but the cluster-wide tunnel (used for centralized access via Traefik) does not.

**Parent**: Observed during PLAN-009 and PLAN-010 testing.

---

## Problem Description

The cluster-wide Tailscale tunnel (`k8s.dog-pence.ts.net`) consistently times out during the deploy connectivity test. The TLS handshake fails after 12 retries. Tailscale proxy pod logs show `Drop: TCP ... no rules matched`.

Meanwhile, per-service Tailscale Funnel works perfectly — `whoami.dog-pence.ts.net` is accessible via HTTPS from the public internet (HTTP 200).

This has been observed across all PLAN-009 and PLAN-010 test rounds (at least 12 rounds total). Initially it was suspected to be caused by stale devices, but after PLAN-010 cleaned up all stale devices (from 17 down to 5), the issue persists.

## Root Cause: Let's Encrypt ACME Rate Limiting

**Not a code or configuration bug.** The cluster tunnel configuration is correct.

The `k8s.dog-pence.ts.net` hostname was deployed/undeployed 12+ times across all test rounds. Each deployment requests a new TLS certificate from Let's Encrypt. The rate limit is **5 certificates per exact hostname per 168 hours (7 days)**. We exhausted this limit.

### Evidence from proxy pod logs

```
cert("k8s.dog-pence.ts.net"): getCertPEM: 429 urn:ietf:params:acme:error:rateLimited:
too many certificates (5) already issued for this exact set of identifiers in the
last 168h0m0s, retry after 2026-02-23 23:03:40 UTC
```

### What was verified working

| Check | Result |
|-------|--------|
| Proxy configuration | Correctly forwarding to `http://10.43.110.32:80/` (Traefik ClusterIP) |
| Cross-namespace connectivity | HTTP 200 from `tailscale` namespace → `traefik.kube-system.svc.cluster.local:80` |
| Operator RBAC | `tailscale-operator` ClusterRole exists with appropriate permissions |
| Ingress resource | Correctly configured with `funnel: "true"`, `hostname: k8s`, `tags: tag:k8s-operator` |

### Why whoami works but k8s doesn't

The `whoami.dog-pence.ts.net` hostname was only created once or twice recently — well within the rate limit. The `k8s.dog-pence.ts.net` hostname was created 12+ times across all test rounds.

### Why "Drop: TCP ... no rules matched" was misleading

Those messages appear on non-HTTPS ports. The actual HTTPS connections reach the proxy but fail at TLS handshake because there's no valid certificate. Without a cert, the connection drops.

## Resolution

This is a testing artifact, not a production issue. In normal usage, the cluster tunnel would be deployed once and left running. The fix is simply to wait for the rate limit to reset (after 2026-02-23 23:03:40 UTC) or use a different hostname.

### Recommendations for future testing

1. **Don't repeatedly deploy/undeploy the cluster tunnel** during test rounds — the rate limit is strict
2. **Use a different hostname** for each test if you need to redeploy (e.g., `k8s-test1`, `k8s-test2`)
3. **The deploy connectivity test should handle this gracefully** — consider adding rate limit detection to the deploy playbook error messages (future improvement, not blocking)

## Original Investigation Areas — All Ruled Out

1. ~~ACL/Funnel configuration~~ — Not the issue. Funnel works for other hostnames.
2. ~~Namespace differences~~ — Not the issue. Cross-namespace connectivity confirmed (HTTP 200).
3. ~~Traefik routing~~ — Not the issue. Proxy correctly configured to forward to Traefik.
4. ~~Stale state in Tailscale control plane~~ — Not the issue. Device cleanup was done.
5. ~~Tailscale operator version~~ — Not the issue. Operator and proxy work correctly.
6. ~~Firewall rules~~ — The `no rules matched` messages were on non-HTTPS ports, not the root cause.

## Data Collected

- [x] Full Tailscale proxy pod logs for the cluster ingress — **showed ACME 429 error**
- [x] `kubectl get ingress traefik-ingress -n kube-system -o yaml` — correctly configured
- [x] `kubectl get svc -n kube-system traefik -o yaml` — port 80 correct
- [x] `kubectl get pods -n tailscale` — 3 pods running (operator, ts-traefik-ingress, ts-whoami-tailscale)
- [x] Cross-namespace connectivity test — HTTP 200
- [x] Operator ClusterRole — exists with appropriate permissions
