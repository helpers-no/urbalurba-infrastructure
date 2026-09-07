# INVESTIGATE: Authentik Automatic Deployment

**Status:** Completed
**Created:** 2026-01-28
**Completed:** 2026-01-31
**Implemented in:** [PLAN-007](PLAN-007-authentik-auto-secrets.md)

---

## Problem Statement

Authentik deployment required a manual step before the playbook could run:
```bash
kubectl apply -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
```

Without this, the playbook failed because:
1. The `authentik` namespace didn't exist
2. The `urbalurba-secrets` secret didn't exist in the namespace
3. The database utility couldn't read the password
4. Helm deployment failed (pods crash)

### Root Cause

The utility playbook read the password from the `authentik` namespace, which didn't exist yet:

```yaml
# u09-authentik-create-postgres.yml
- name: 4. Get urbalurba-secrets from authentik namespace
  kubernetes.core.k8s_info:
    name: urbalurba-secrets
    namespace: authentik          # ← Namespace doesn't exist yet
```

The generated `kubernetes-secrets.yml` already contained both the namespace definition and the secrets — it just needed to be applied before the playbook checked for them.

### Options Considered

| Option | Approach | Verdict |
|--------|----------|---------|
| **A** | Apply secrets file early in playbook | ✅ Chosen — cleanest, single source of truth |
| **B** | Read password from default namespace | Rejected — still needs namespace creation |
| **C** | Hybrid (create namespace + copy secrets) | Rejected — duplicates logic |

---

## What Was Done

PLAN-007 implemented Option A and expanded to cover additional issues found during testing:

- ✅ Added tasks 1.5 and 1.6 to apply secrets automatically at playbook start
- ✅ Fixed Authentik redirect URL (workaround for Authentik bug #5922)
- ✅ Fixed 9 additional deployment issues (database auth, password escaping, Helm pinning, fail-fast, chdir bug, etc.)
- ✅ Created E2E auth test playbook (`070-test-authentik-auth.yml`) with 5 critical tests
- ✅ Fixed Ingress conflict security issue (task 46.5 removes standard whoami Ingress)
- ✅ Full deployment verified from scratch: 81 ok, 0 failed

See [PLAN-007](PLAN-007-authentik-auto-secrets.md) for full details including all 13 issues encountered and resolved.

---

## Related

- [INVESTIGATE: Authentik User Config Migration](../backlog/INVESTIGATE-service-authentik-user-config.md) — Goal 2 from the original investigation (not started)
