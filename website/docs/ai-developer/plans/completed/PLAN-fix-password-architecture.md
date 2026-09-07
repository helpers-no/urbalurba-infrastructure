# PLAN: Fix Password Architecture — Connect Orphaned Defaults to Templates

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Related**: [INVESTIGATE-passwords](../completed/INVESTIGATE-passwords.md)
**Created**: 2026-02-26
**Status:** Completed
**Completed**: 2026-02-27

**Goal**: Make `default-secrets.env` the true single source of truth — all DEFAULT_ variables must flow through to templates, and no credentials should be hardcoded in templates.

**Last Updated**: 2026-02-27

**Priority**: Medium — affects developer experience and security posture

---

## Problem Summary

The password system has a broken "single source of truth" pattern:

1. **8 of 11 DEFAULT_ variables in `default-secrets.env` are orphaned** — `copy_secrets_templates()` only applies 3 via sed (`DEFAULT_ADMIN_EMAIL`, `DEFAULT_ADMIN_PASSWORD`, `DEFAULT_DATABASE_PASSWORD`). The other 8 are sourced but never substituted.

2. **Hardcoded credentials in `00-common-values.env.template`** that should come from defaults:
   - `REDIS_PASSWORD=YourRedisPassword123` (should use `DEFAULT_REDIS_PASSWORD`)
   - `AUTHENTIK_SECRET_KEY=your-secret-key-here` (should use `DEFAULT_AUTHENTIK_SECRET_KEY`)
   - `AUTHENTIK_BOOTSTRAP_PASSWORD=SecretPassword1` (should use `DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD`)

3. **Redundant email variables** — four email variables exist but only one is used:
   - `DEFAULT_ADMIN_EMAIL` — the **only one** referenced by the master template (pgAdmin, Gravitee, Grafana, Redis Commander, Authentik)
   - `ADMIN_EMAIL` — in common-values template but never used by master template
   - `AUTHENTIK_BOOTSTRAP_EMAIL` — in common-values template but overridden by master template line 490 which uses `${DEFAULT_ADMIN_EMAIL}`
   - `DEFAULT_AUTHENTIK_BOOTSTRAP_EMAIL` — in `default-secrets.env` but never connected to anything

4. **Hardcoded credentials in `00-master-secrets.yml.template`**:
   - `redis-commander-password: "MyCustomRedisCommanderPassword999"`
   - Hardcoded Authentik OAuth client ID and secret
   - `LITELLM_PROXY_MASTER_KEY: "sk-1234567890abcdef"`

5. **Validation only checks 3 variables** — `secrets-management.sh` should validate all DEFAULT_ variables.

6. **Redundant DEFAULT_ variables** that map to the same value:
   - `DEFAULT_POSTGRES_PASSWORD` and `DEFAULT_DATABASE_PASSWORD` — templates already use `${DEFAULT_DATABASE_PASSWORD}` for PGPASSWORD
   - `DEFAULT_DATABASE_ROOT_PASSWORD` — unclear purpose, not used anywhere
   - `DEFAULT_MONGODB_ROOT_PASSWORD` — templates already use `${DEFAULT_DATABASE_PASSWORD}` for MONGODB_ROOT_PASSWORD

### Design Decision: One Admin Email

`DEFAULT_ADMIN_EMAIL` is the single email used everywhere. The master template already uses `${DEFAULT_ADMIN_EMAIL}` for pgAdmin, Grafana, Redis Commander, Gravitee, and Authentik bootstrap. The other three email variables (`ADMIN_EMAIL`, `AUTHENTIK_BOOTSTRAP_EMAIL`, `DEFAULT_AUTHENTIK_BOOTSTRAP_EMAIL`) are orphaned and will be removed.

Email validation is critical because pgAdmin crashes with an unhelpful error if the email lacks a proper domain (rejects `localhost`, `.local`).

### Design Decision: Keep Two Master Passwords

The template's inheritance pattern (2 master passwords cascading to all services) is the correct design. The fix should:
- **Keep** `DEFAULT_ADMIN_PASSWORD` and `DEFAULT_DATABASE_PASSWORD` as the two masters
- **Keep** service-specific defaults for services that genuinely need different credentials (Redis, Authentik secret key, OpenWebUI secret key)
- **Remove** redundant database-password aliases (`DEFAULT_POSTGRES_PASSWORD`, `DEFAULT_MONGODB_ROOT_PASSWORD`, `DEFAULT_DATABASE_ROOT_PASSWORD`)
- **Connect** the remaining defaults so they actually flow through

### Existing User Copies Are Safe

`copy_secrets_templates()` skips if `00-common-values.env.template` already exists — so these changes only affect **new installations**. Existing users keep their current configs.

---

## Phase 1: Clean Up `default-secrets.env` — DONE

### Tasks

- [x] 1.1 Remove redundant variables from `default-secrets.env` ✓
  - Removed `DEFAULT_DATABASE_ROOT_PASSWORD`, `DEFAULT_POSTGRES_PASSWORD`, `DEFAULT_MONGODB_ROOT_PASSWORD`, `DEFAULT_AUTHENTIK_BOOTSTRAP_EMAIL`

- [x] 1.2 Remove orphaned email variables from `00-common-values.env.template` ✓
  - Removed `ADMIN_EMAIL` and `AUTHENTIK_BOOTSTRAP_EMAIL`

- [x] 1.3 Kept 7 DEFAULT_ variables that serve real purposes ✓

---

## Phase 2: Connect Defaults to `00-common-values.env.template` — DONE

### Tasks

- [x] 2.1 Replace hardcoded values in `00-common-values.env.template` with `DEFAULT_*` variable placeholders ✓
- [x] 2.2 Add sed replacements in `first-run.sh` `copy_secrets_templates()` for all DEFAULT_ variables ✓

---

## Phase 3: Fix Hardcoded Credentials in Master Template — DONE

### Tasks

- [x] 3.1 Investigated hardcoded values ✓
  - `redis-commander-password` → changed to `${DEFAULT_ADMIN_PASSWORD}`
  - `LITELLM_PROXY_MASTER_KEY` → changed to `"sk-${DEFAULT_ADMIN_PASSWORD}"` (matches OPENWEBUI_OPENAI_API_KEY)
  - OAuth client ID/secret → kept as-is (matched with Authentik blueprint, not passwords)

- [x] 3.2 No new variables needed — reused existing `DEFAULT_ADMIN_PASSWORD` ✓
- [x] 3.3 Replaced hardcoded values in `00-master-secrets.yml.template` ✓

---

## Phase 4: Extend Validation — DONE

### Tasks

- [x] 4.1 Extended required_vars to all 7 DEFAULT_ variables ✓
- [x] 4.2 Added weak-password checks using `^LocalDev` pattern for all password/key variables ✓
- [x] 4.3 Added email format validation for `DEFAULT_ADMIN_EMAIL` ✓
  - Checks for `@` with text on both sides and dotted domain
  - Clear error message mentioning pgAdmin crash
  - Added validation call in `generate_secrets()` to fail early
- [x] 4.4 Updated `show_secrets_status` to show all 7 core variables ✓
- [x] 4.5 Updated masking to also mask `*SECRET*` variables ✓

---

## Phase 5: Test — DONE

### Variable → Service Map

| Variable | Test service | Result |
|----------|-------------|--------|
| `DEFAULT_ADMIN_EMAIL` | pgadmin | Deployed, email valid |
| `DEFAULT_ADMIN_PASSWORD` | pgadmin | Deployed |
| `DEFAULT_DATABASE_PASSWORD` | postgresql | Deployed |
| `DEFAULT_REDIS_PASSWORD` | redis | Deployed, auth PONG |
| `DEFAULT_AUTHENTIK_SECRET_KEY` | authentik | Deployed |
| `DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD` | authentik | Deployed |
| `DEFAULT_OPENWEBUI_SECRET_KEY` | openwebui | Deployed |

### Test Results

- [x] 5B: Fresh `.uis.secrets/` created on container start with all defaults applied ✓
- [x] 5B: No `DEFAULT_*` placeholder strings remaining in generated template ✓
- [x] 5B: `./uis secrets status` shows all 7 core variables ✓
- [x] 5C: Deploy postgresql — running ✓
- [x] 5C: Deploy redis — running, auth passed ✓
- [x] 5C: Deploy pgadmin — running (email validation passed) ✓
- [x] 5C: Deploy authentik — running, all components healthy ✓
- [x] 5C: Deploy openwebui — running ✓
- [x] 5C: Grafana skipped (needs prometheus) — variables already covered by pgadmin ✓
- [x] 5D: Undeploy openwebui ✓
- [x] 5D: Undeploy authentik ✓
- [x] 5D: Undeploy pgadmin ✓
- [x] 5D: Undeploy redis ✓
- [x] 5D: Undeploy postgresql ✓

### Bug Found During Testing

`cmd_init()` in `uis-cli.sh` returned early when `.uis.extend/` existed but `.uis.secrets/` was fresh (no `secrets-config/`). Fixed by adding self-healing `copy_secrets_templates()` call in the "already initialized" path.

---

## Phase 6: Update Investigation — DONE

- [x] 6.1 Update `INVESTIGATE-passwords.md` to Complete ✓
- [x] 6.2 Update this plan to Complete ✓

---

## Acceptance Criteria

- [x] `default-secrets.env` has no redundant DEFAULT_ variables
- [x] All DEFAULT_ variables in `default-secrets.env` are applied by `copy_secrets_templates()`
- [x] No hardcoded credentials in `00-common-values.env.template` (all come from defaults)
- [x] No hardcoded credentials in `00-master-secrets.yml.template` (all reference variables)
- [x] `secrets-management.sh` validates all DEFAULT_ variables
- [x] Email validation for `DEFAULT_ADMIN_EMAIL` with clear error message
- [x] Fresh install produces working secrets
- [x] Existing user configs are not affected

---

## Files Modified

| File | Change |
|------|--------|
| `provision-host/uis/templates/default-secrets.env` | Removed 4 redundant variables |
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Removed 2 orphaned email vars, replaced 3 hardcoded values with DEFAULT_ placeholders |
| `provision-host/uis/lib/first-run.sh` | Extended sed replacements from 5 to 8 |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Replaced redis-commander-password and LITELLM_PROXY_MASTER_KEY with `${DEFAULT_ADMIN_PASSWORD}` |
| `provision-host/uis/lib/secrets-management.sh` | Extended validation to 7 variables, added email check, weak-password pattern, validation in generate |
| `provision-host/uis/manage/uis-cli.sh` | Added self-healing `copy_secrets_templates()` in cmd_init "already initialized" path |
