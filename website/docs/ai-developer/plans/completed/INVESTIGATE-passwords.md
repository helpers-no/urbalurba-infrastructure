# INVESTIGATE: Password Architecture

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Related Plan**: [PLAN-004-secrets-cleanup](../completed/PLAN-004-secrets-cleanup.md) - Secrets migration cleanup and finalization

**Status:** Completed

**Completed**: 2026-02-27
**Outcome**: All issues fixed in [PLAN-fix-password-architecture](../completed/PLAN-fix-password-architecture.md)

## Problem

The password system had a design mismatch between `default-secrets.env` and the template system:
- 8 of 11 DEFAULT_ variables were orphaned (never applied to templates)
- Hardcoded credentials in templates that should come from defaults
- 4 redundant email variables when only 1 is used
- Validation only checked 3 of 11 variables

## Investigation Findings

### Questions Resolved

1. **Should `default-secrets.env` follow the same inheritance pattern?** — No. It provides per-variable defaults. The template's `${DEFAULT_DATABASE_PASSWORD}` inheritance is the right pattern. The defaults just need to be properly connected via sed.

2. **Do we need separate database password variables?** — No. `DEFAULT_DATABASE_PASSWORD` is the single master. `DEFAULT_POSTGRES_PASSWORD`, `DEFAULT_DATABASE_ROOT_PASSWORD`, and `DEFAULT_MONGODB_ROOT_PASSWORD` were all unused — templates already use `${DEFAULT_DATABASE_PASSWORD}` directly.

3. **Full password flow traced**: `default-secrets.env` → `source` → `sed` into `00-common-values.env.template` → `envsubst` → `00-master-secrets.yml.template` → `kubernetes-secrets.yml` → Kubernetes secrets → Helm/manifests.

4. **Orphaned variables**: 8 of 11 were unused. 3 were redundant database aliases, 1 was a redundant email, 4 had values that never reached templates (sed only handled 3 variables).

5. **REDIS_PASSWORD mismatch**: Template had hardcoded `YourRedisPassword123` while defaults had `LocalDevRedis123`. They were never connected. Fixed by replacing hardcoded value with placeholder that sed replaces.

### Email Consolidation

Four email variables existed but the master template only uses `${DEFAULT_ADMIN_EMAIL}`. Removed: `ADMIN_EMAIL`, `AUTHENTIK_BOOTSTRAP_EMAIL`, `DEFAULT_AUTHENTIK_BOOTSTRAP_EMAIL`.

### pgAdmin Email Validation

pgAdmin crashes on startup if the admin email lacks a proper domain (rejects `localhost`, `.local`). Added email format validation to catch this before secrets are generated.

## Password Restriction

These characters must NOT be used in any password: `!  $  \`  \  "`

Bitnami Helm charts pass passwords through bash during container initialization, which escapes these characters.
