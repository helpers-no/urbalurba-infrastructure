# Secrets Management Rules

Mandatory rules for managing secrets in UIS. These rules ensure security, prevent accidental exposure, and maintain consistency across services.

## Decision: internal addresses already in this repo are accepted

**Decided by Terje, 2026-08-30.** Raised 2026-08-26 after a scan of this repository.

This repository is **public**. Around two dozen private-range (RFC1918) addresses from the
reference installation's own network appear in about ten markdown files, mostly under
`ai-developer/plans/`, where they were written as ordinary working notes. They are **staying**.
The repository is not being sanitised and is not being made private.

**The reasoning, so nobody has to reconstruct it.** RFC1918 addresses are not routable from the
internet and grant no access on their own. **No credential is exposed** — that was checked, and it
is the fact the decision rests on. What the addresses do give away is internal topology to someone
who *already* has a foothold, and they pair badly with the detail elsewhere in this repo about what
runs where. So the severity is **low, but not nothing**, and the decision is a deliberate
acceptance of that residual rather than a judgement that it does not exist.

### This is not a licence to add more

The decision covers **what was already committed**. It says nothing about new material.

- Do not put an address in a new plan because older plans have them.
- Prefer a placeholder — `<postgres-host>`, `<node-ip>` — wherever the actual value is not
  load-bearing for the reader.
- Where a real value genuinely helps, keep it in the private `home` repository and reference it
  from here.

### The boundary that made it acceptable

Two conditions, and **both** hold today:

| | Condition |
|---|---|
| 1 | **Private-range addresses only** — RFC1918, not routable from the internet |
| 2 | **No credentials of any kind** — no passwords, tokens, keys, or connection strings carrying one |

**If either stops being true, that is a new decision, not this one.** A publicly routable address, a
hostname that resolves outside the network, or anything credential-shaped is out of scope here and
needs Terje. Under this project's own rules the platform owner is the only person who can approve
public exposure — see the roles section of `TALK.md`.

⚠️ **Today this boundary is enforced by review, not by a check.** Nothing in CI fails a commit that
adds a public address or a credential-shaped string to this repo. That is worth fixing, and it is a
separate piece of work from the decision recorded here.

## Core Pattern: Template + Gitignore

All secrets follow a three-stage pipeline:

```
Container image templates  →  .uis.secrets/secrets-config/  →  .uis.secrets/generated/
        ↑                              ↑                              ↑
  Git-tracked (${VARIABLES})     Gitignored (actual values)    Gitignored (final YAML)
```

### Safe operations

- Edit files in `.uis.secrets/secrets-config/` with actual secret values
- Run `./uis secrets generate` to produce final YAML
- Run `./uis secrets apply` to push to the cluster

### Forbidden operations

- **Never** put actual secrets in container image templates
- **Never** commit `.uis.secrets/` to git
- **Never** edit files in `.uis.secrets/generated/` directly
- **Never** store secrets in documentation or comments

## Variable Substitution

All secrets use centralized variable management. Define values once in `00-common-values.env.template`, reference them everywhere via `${VARIABLE}`:

```bash
# .uis.secrets/secrets-config/00-common-values.env.template
DEFAULT_DATABASE_PASSWORD=YourSecurePassword123
DEFAULT_ADMIN_EMAIL=admin@yourcompany.com
```

```yaml
# .uis.secrets/secrets-config/00-master-secrets.yml.template
PGPASSWORD: "${DEFAULT_DATABASE_PASSWORD}"
AUTHENTIK_BOOTSTRAP_EMAIL: "${DEFAULT_ADMIN_EMAIL}"
```

**Anti-pattern** — hard-coding different passwords per service:

```yaml
# WRONG: breaks centralized rotation
PGPASSWORD: "postgres-specific-password"
MYSQL_ROOT_PASSWORD: "mysql-different-password"
```

Centralized variables enable password rotation across all services simultaneously.

## Correct Workflow

```bash
# 1. Edit your values
nano .uis.secrets/secrets-config/00-common-values.env.template

# 2. Generate secrets
./uis secrets generate

# 3. Validate before applying
kubectl apply --dry-run=client -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml

# 4. Apply to cluster
./uis secrets apply
```

**Anti-pattern** — editing generated files directly or skipping validation:

```bash
# WRONG: edits will be overwritten on next generate
nano .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
```

## Git Safety

Before any git operation, verify no secrets are staged:

```bash
# Check what's staged
git status

# Verify gitignore covers secrets
git check-ignore .uis.secrets/

# Check for secret patterns in staged files
git diff --cached | grep -i "password\|secret\|key"
```

Never use `git add .` without checking what's included. Never add `.uis.secrets/` to git.

## Service Integration

When adding secrets for a new service, use the established namespace pattern:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: urbalurba-secrets
  namespace: myservice
type: Opaque
stringData:
  MYSERVICE_DATABASE_PASSWORD: "${DEFAULT_DATABASE_PASSWORD}"
  MYSERVICE_API_KEY: "${MYSERVICE_API_KEY}"
```

**Anti-patterns:**
- Hard-coding secrets in templates instead of using `${VARIABLES}`
- Using service-specific secret names instead of `urbalurba-secrets`
- Skipping namespace organization

## No Helm Chart Defaults for Security Values

Never use Helm chart default values for security-sensitive parameters. Always override with values from `urbalurba-secrets`:

```yaml
# In Ansible playbook
helm upgrade --install {{ service_name }} bitnami/rabbitmq \
  --set auth.username={{ rabbitmq_username_fact | quote }} \
  --set auth.password={{ rabbitmq_password_fact | quote }} \
  --set auth.erlangCookie={{ rabbitmq_erlang_cookie_fact | quote }}
```

Parameters to always override: `auth.username`, `auth.password`, `rootPassword`, `adminPassword`, `apiKey`, `secretKey`, `jwtSecret`, `erlangCookie`, and any connection strings with embedded credentials.

Common Bitnami chart defaults to avoid:

| Chart | Default Username | Default Password |
|-------|-----------------|-----------------|
| PostgreSQL | `postgres` | `postgres` |
| Redis | — | `bitnami` |
| RabbitMQ | `user` | `bitnami` |
| MongoDB | `root` | `root` |

## ConfigMap Management

ConfigMaps follow the same template pattern but for non-sensitive configuration:

```
.uis.secrets/secrets-config/configmaps/[namespace]/[category]/*.template
```

ConfigMaps are auto-discovered and auto-labeled based on directory conventions:

| Directory | Auto-Label |
|-----------|-----------|
| `dashboards/` | `grafana_dashboard: "1"` |
| `nginx/` | `app: nginx` |
| `otel/` | `app.kubernetes.io/name: otel-collector` |
| Default | `managed-by: secrets-pipeline` |

**ConfigMap vs Secret**: Use ConfigMaps for application config files, dashboard definitions, public certificates, hosts/ports. Use Secrets for passwords, API keys, tokens, private keys, connection strings with credentials.

## Testing and Validation

All secret changes must be validated before deployment:

```bash
# 1. Generate and validate YAML
./uis secrets generate
kubectl apply --dry-run=client -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml

# 2. Check for unresolved variables (should return nothing)
grep '${' .uis.secrets/generated/kubernetes/kubernetes-secrets.yml

# 3. Verify critical secrets are present
grep -c "PGPASSWORD\|REDIS_PASSWORD\|AUTHENTIK_SECRET_KEY" \
  .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
```

## Secret Rotation

```bash
# 1. Update central variables
nano .uis.secrets/secrets-config/00-common-values.env.template

# 2. Generate and validate
./uis secrets generate
kubectl apply --dry-run=client -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml

# 3. Apply to cluster
./uis secrets apply

# 4. Restart affected services
./uis undeploy postgresql
./uis deploy postgresql
```

## Incident Response

If secrets are accidentally committed to git:

1. Remove from git immediately (`git reset HEAD~1` if not pushed)
2. If pushed, contact the team — may need `git filter-branch`
3. Rotate all exposed secrets in `secrets-config/`
4. Audit access logs for the exposed period

## Template Update Rules

The generation script prioritizes `.uis.secrets/secrets-config/` over container image templates (to allow user customization). When updating base templates in the container image, also update the user's config for immediate effect:

```bash
# Verify user config is up to date with base templates
diff <container-template> .uis.secrets/secrets-config/00-master-secrets.yml.template
```

On `./uis start`, new template variables are automatically synced to `secrets-config/`. Existing values are preserved.

## Cross-System Dependencies

- **Deployment**: Secrets must be generated and applied before deploying services
- **Ingress**: Domain names in secrets must match ingress configurations
- **Verification**:
  ```bash
  kubectl get secret urbalurba-secrets -n default
  kubectl get secret urbalurba-secrets -n ai
  kubectl get secret urbalurba-secrets -n authentik
  ```

## Related Documentation

- **[Secrets Management Reference](../architecture/secrets.md)** — Commands, file structure, and defaults
- **[Provisioning Rules](./provisioning.md)** — Ansible playbook patterns
- **[Ingress & Networking Rules](./ingress-traefik.md)** — Domain and routing configuration
