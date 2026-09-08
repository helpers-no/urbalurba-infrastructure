# Investigation: How to Add a New Service to UIS

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Document the complete lifecycle of adding a new service to the UIS platform — from service definition to deployment, secrets, removal, and documentation.

**Created**: 2026-03-05
**Last Updated**: 2026-03-05 (gap analysis applied)

---

## Purpose

This document traces the full path of how a service gets deployed, from `uis deploy` through every script, playbook, manifest, and configuration file. It serves as a reference for anyone adding a new service to the platform.

**Important distinction:** UIS has two separate deployment concepts:
- **Infrastructure services** (`uis deploy`) — Platform services managed by UIS (databases, monitoring, auth, etc.). This is what this document covers.
- **User applications** (`uis argocd register`) — External GitHub repos deployed via ArgoCD. This is a completely different flow (see Finding 13).

---

## Finding 1: The Complete Deployment Flow

When a user runs `uis deploy`, this is the exact call chain:

```
User runs: uis deploy [service-id]
    │
    ├─ uis.ps1 / uis.cmd (Windows) or docker exec (Linux/Mac)
    │   └─ Routes to: provision-host/uis/manage/uis-cli.sh
    │
    ├─ uis-cli.sh :: cmd_deploy()
    │   ├─ 1. check_first_run()           → Creates .uis.extend/ and .uis.secrets/ if missing
    │   ├─ 2. ensure_secrets_applied()     → Generates and applies kubernetes-secrets.yml
    │   └─ 3. deploy_single_service()      → Or deploy_enabled_services() if no ID given
    │
    ├─ service-deployment.sh :: deploy_single_service(service_id)
    │   ├─ 1. find_service_script()        → Locates provision-host/uis/services/*/service-*.sh
    │   ├─ 2. source "$script"             → Loads metadata (SCRIPT_PLAYBOOK, SCRIPT_REQUIRES, etc.)
    │   ├─ 3. check_dependencies()         → Verifies SCRIPT_REQUIRES services are deployed
    │   ├─ 4. ansible-playbook              → All 26 services use SCRIPT_PLAYBOOK
    │   ├─ 5. SCRIPT_CHECK_COMMAND         → Health check to verify deployment
    │   └─ 6. enable_service()             → Auto-enables in enabled-services.conf
    │
    └─ Ansible playbook (e.g., 040-database-postgresql.yml)
        ├─ Create namespace
        ├─ Add Helm repo
        ├─ Install via Helm (or kubectl apply manifests)
        ├─ Create IngressRoute
        └─ Wait for pods to be ready
```

### Key files in the chain

| Step | File | Purpose |
|------|------|---------|
| Entry point | `provision-host/uis/manage/uis-cli.sh` | CLI command router |
| First run | `provision-host/uis/lib/first-run.sh` | Directory creation, secret generation |
| Secrets | `provision-host/uis/lib/secrets-management.sh` | Secret validation and application |
| Service discovery | `provision-host/uis/lib/service-scanner.sh` | Find and parse service definitions |
| Deployment logic | `provision-host/uis/lib/service-deployment.sh` | Execute deployments |
| Enable/disable | `provision-host/uis/lib/service-auto-enable.sh` | Manage enabled-services.conf |
| Path resolution | `provision-host/uis/lib/paths.sh` | All path constants |
| Categories | `provision-host/uis/lib/categories.sh` | Category metadata |
| Stacks | `provision-host/uis/lib/stacks.sh` | Stack (service group) definitions |
| Helm repos | `ansible/playbooks/05-install-helm-repos.yml` | Prerequisite Helm repo setup |

---

## Finding 2: The Files You Create for a New Service

Adding a new service requires creating/modifying these files:

### Required Files

#### 1. Service definition: `provision-host/uis/services/<category>/service-<id>.sh`

Pure metadata — no executable logic. Example:

```bash
# === Service Metadata (Required) ===
SCRIPT_ID="myservice"
SCRIPT_NAME="My Service"
SCRIPT_DESCRIPTION="Short description of what it does"
SCRIPT_CATEGORY="DATABASES"

# === Deployment (Required) ===
SCRIPT_PLAYBOOK="NNN-setup-myservice.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n default -l app=myservice --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="NNN-remove-myservice.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="50"

# === Deployment Details (Optional) ===
SCRIPT_HELM_CHART="repo/chart-name"
SCRIPT_NAMESPACE="default"
SCRIPT_IMAGE="myservice/myservice:latest"

# === Website Metadata (Optional — consumed by uis-docs.sh) ===
SCRIPT_ABSTRACT="Brief abstract for documentation"
SCRIPT_SUMMARY="Extended description for the documentation page"
SCRIPT_LOGO="myservice-logo.webp"
SCRIPT_WEBSITE="https://myservice.example.com"
SCRIPT_TAGS="tag1,tag2,tag3"
SCRIPT_DOCS="/docs/services/category/myservice"
```

**Field reference:**

| Field | Required | Description |
|-------|----------|-------------|
| `SCRIPT_ID` | Yes | Unique identifier (used in `uis enable/deploy/disable`) |
| `SCRIPT_NAME` | Yes | Display name |
| `SCRIPT_DESCRIPTION` | Yes | One-line description |
| `SCRIPT_CATEGORY` | Yes | Must match a category in `categories.sh` |
| `SCRIPT_PLAYBOOK` | Yes | Ansible playbook filename (in `ansible/playbooks/`) |
| `SCRIPT_MANIFEST` | No | Kubernetes manifest filename — supported but **no service currently uses this**; all 26 use SCRIPT_PLAYBOOK |
| `SCRIPT_CHECK_COMMAND` | No | Shell command that exits 0 if service is deployed |
| `SCRIPT_REMOVE_PLAYBOOK` | No | Playbook for removal (can include `-e` params) |
| `SCRIPT_REQUIRES` | No | Space-separated list of required service IDs |
| `SCRIPT_PRIORITY` | No | Deployment order (lower = first, default 50) |
| `SCRIPT_HELM_CHART` | No | Helm chart reference (for metadata/docs) |
| `SCRIPT_NAMESPACE` | No | Kubernetes namespace |
| `SCRIPT_IMAGE` | No | Docker image reference (for metadata/docs) |
| `SCRIPT_ABSTRACT` | No | Short abstract for website |
| `SCRIPT_SUMMARY` | No | Extended description for website |
| `SCRIPT_LOGO` | No | Logo filename for website |
| `SCRIPT_WEBSITE` | No | Official project URL |
| `SCRIPT_TAGS` | No | Comma-separated tags for website |
| `SCRIPT_DOCS` | No | Internal docs path for website |

**Note:** Website metadata fields (`SCRIPT_ABSTRACT`, `SCRIPT_TAGS`, etc.) are consumed by `uis-docs.sh` which generates `services.json`, `categories.json`, `stacks.json`, and `tools.json` for the documentation website.

#### 2. Ansible setup playbook: `ansible/playbooks/NNN-setup-myservice.yml`

The deployment playbook. See Finding 4 for the standard template.

#### 3. Ansible remove playbook: `ansible/playbooks/NNN-remove-myservice.yml`

The removal playbook. See Finding 5 for the standard template.

### Usually Required Files

#### 4. Helm values / config: `manifests/NNN-myservice-config.yaml`

Helm values file or ConfigMap. Referenced by the playbook.

#### 5. IngressRoute: `manifests/NNN-myservice-ingressroute.yaml`

Traefik IngressRoute for web-accessible services.

### Optional Files

#### 6. Secrets entries (if service needs credentials)

Three files in `provision-host/uis/templates/` (the source-of-truth shipped in the container):
- `secrets-templates/00-common-values.env.template` — add variable definitions
- `secrets-templates/00-master-secrets.yml.template` — add Kubernetes Secret block
- `default-secrets.env` — add development default values

See Finding 6 for details.

#### 7. Documentation: `website/docs/services/<category>/myservice.md`

Docusaurus page. Add to `website/sidebars.ts` under the appropriate category.

---

## Finding 3: Available Categories

Categories are defined in `provision-host/uis/lib/categories.sh`:

| Category ID | Display Name | Manifest Range |
|-------------|-------------|----------------|
| `OBSERVABILITY` | Observability | 030-039, 230-239 |
| `AI` | AI & Machine Learning | 200-229 |
| `ANALYTICS` | Analytics | 300-399 |
| `IDENTITY` | Identity & Auth | 070-079 |
| `DATABASES` | Databases | 040-099 |
| `MANAGEMENT` | Management | 600-799 |
| `NETWORKING` | Networking | 800-820 |
| `STORAGE` | Storage | 000-009 |
| `INTEGRATION` | Integration | 080-091 |

---

## Finding 4: Ansible Setup Playbook Template

Every setup playbook follows this structure. Here's the annotated template:

```yaml
---
# NNN-setup-myservice.yml
# Deploy My Service to the Kubernetes cluster
#
# Usage:
#   ansible-playbook NNN-setup-myservice.yml -e "target_host=rancher-desktop"

- name: Deploy My Service
  hosts: localhost
  connection: local
  gather_facts: false

  vars:
    # Target Kubernetes context (passed via -e target_host=xxx)
    _target: "{{ target_host | default('rancher-desktop') }}"

    # Kubeconfig (centralized path)
    merged_kubeconf_file: "/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"

    # Service-specific variables
    namespace: "myservice-namespace"
    component_name: "myservice"
    manifests_folder: "/mnt/urbalurbadisk/manifests"
    config_file: "{{ manifests_folder }}/NNN-myservice-config.yaml"
    ingressroute_file: "{{ manifests_folder }}/NNN-myservice-ingressroute.yaml"

    # Helm variables (if using Helm)
    helm_release_name: "myservice"
    helm_chart: "repo/myservice"
    helm_repo_name: "myrepo"
    helm_repo_url: "https://charts.example.com"

  tasks:
    # --- Step 1: Create namespace ---
    - name: "1. Create {{ namespace }} namespace"
      kubernetes.core.k8s:
        name: "{{ namespace }}"
        api_version: v1
        kind: Namespace
        state: present
        kubeconfig: "{{ merged_kubeconf_file }}"

    # --- Step 2: Add Helm repo (if using Helm) ---
    - name: "2. Add Helm repository"
      kubernetes.core.helm_repository:
        name: "{{ helm_repo_name }}"
        repo_url: "{{ helm_repo_url }}"

    # --- Step 3: Get secrets (if service needs credentials) ---
    - name: "3. Get database password from Kubernetes secrets"
      ansible.builtin.shell: >
        kubectl get secret --namespace default urbalurba-secrets
        -o jsonpath="{.data.PGPASSWORD}" --kubeconfig {{ merged_kubeconf_file }}
        | base64 -d
      register: db_password
      changed_when: false

    # --- Step 4: Install via Helm ---
    - name: "4. Install/upgrade via Helm"
      kubernetes.core.helm:
        name: "{{ helm_release_name }}"
        chart_ref: "{{ helm_chart }}"
        release_namespace: "{{ namespace }}"
        create_namespace: true
        state: present
        kubeconfig: "{{ merged_kubeconf_file }}"
        values_files:
          - "{{ config_file }}"
      # OR for commands that need secret values:
      # ansible.builtin.command: >
      #   helm upgrade --install {{ helm_release_name }} {{ helm_chart }}
      #   -f {{ config_file }}
      #   --set auth.password={{ db_password.stdout | quote }}
      #   --namespace {{ namespace }}
      #   --timeout 600s
      #   --kubeconfig {{ merged_kubeconf_file }}
      # no_log: true

    # --- Step 5: Apply IngressRoute ---
    - name: "5. Deploy IngressRoute"
      kubernetes.core.k8s:
        state: present
        src: "{{ ingressroute_file }}"
        kubeconfig: "{{ merged_kubeconf_file }}"

    # --- Step 6: Wait for pods ---
    - name: "6. Wait for {{ component_name }} to be ready"
      kubernetes.core.k8s_info:
        kind: Pod
        namespace: "{{ namespace }}"
        label_selectors:
          - "app.kubernetes.io/name={{ component_name }}"
        kubeconfig: "{{ merged_kubeconf_file }}"
      register: service_pods
      retries: 20
      delay: 15
      until: >
        service_pods.resources | length > 0 and
        service_pods.resources[0].status.phase == "Running"

    # --- Step 7: Display result ---
    - name: "7. Deployment complete"
      ansible.builtin.debug:
        msg:
          - "{{ component_name }} deployed successfully"
          - "Namespace: {{ namespace }}"
          - "URL: http://{{ component_name }}.localhost"
```

### Key patterns observed across existing playbooks:

- **`_target`** always uses underscore prefix (avoids Ansible recursive template issue)
- **`kubeconfig`** parameter for `kubernetes.core.k8s` and `kubernetes.core.helm` modules — use `kubeconfig: "{{ merged_kubeconf_file }}"` consistently in new playbooks
- **Note:** Older playbooks inconsistently use `context: "{{ _target }}"` instead. Both work, but `kubeconfig` is preferred for new code since it points to the merged kubeconfig file.
- **`no_log: true`** on any task that handles secrets
- **Numbered task names** ("1. Create namespace", "2. Add Helm repo") for readability
- **`changed_when: false`** on read-only shell commands
- **Retries with delay** for pod readiness (typically 20 retries x 15s = 5 minutes)

---

## Finding 5: Ansible Remove Playbook Template

```yaml
---
# NNN-remove-myservice.yml
# Remove My Service from the Kubernetes cluster
#
# Usage:
#   ansible-playbook NNN-remove-myservice.yml -e "target_host=rancher-desktop"
#   ansible-playbook NNN-remove-myservice.yml -e "target_host=rancher-desktop" -e "remove_pvc=true"

- name: Remove My Service
  hosts: localhost
  connection: local
  gather_facts: false

  vars:
    _target: "{{ target_host | default('rancher-desktop') }}"
    _remove_pvc: "{{ remove_pvc | default(false) | bool }}"
    merged_kubeconf_file: "/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"
    namespace: "myservice-namespace"
    helm_release_name: "myservice"

  tasks:
    # --- Step 1: Check if Helm release exists ---
    - name: "1. Check for Helm release"
      ansible.builtin.shell: >
        helm status {{ helm_release_name }} -n {{ namespace }}
        --kubeconfig {{ merged_kubeconf_file }}
      register: helm_check
      failed_when: false
      changed_when: false

    # --- Step 2: Remove Helm release ---
    - name: "2. Remove Helm release"
      kubernetes.core.helm:
        name: "{{ helm_release_name }}"
        release_namespace: "{{ namespace }}"
        state: absent
        kubeconfig: "{{ merged_kubeconf_file }}"
      when: helm_check.rc == 0

    # --- Step 3: Remove PVCs (optional) ---
    - name: "3. Remove PVCs"
      ansible.builtin.shell: >
        kubectl delete pvc -l app.kubernetes.io/name={{ helm_release_name }}
        -n {{ namespace }} --kubeconfig {{ merged_kubeconf_file }}
      when: _remove_pvc
      failed_when: false

    # --- Step 4: Remove IngressRoute ---
    - name: "4. Remove IngressRoute"
      kubernetes.core.k8s:
        state: absent
        kind: IngressRoute
        api_version: traefik.io/v1alpha1
        name: "{{ helm_release_name }}"
        namespace: "{{ namespace }}"
        kubeconfig: "{{ merged_kubeconf_file }}"
      failed_when: false

    # --- Step 5: Wait for cleanup ---
    - name: "5. Wait for pods to terminate"
      kubernetes.core.k8s_info:
        kind: Pod
        namespace: "{{ namespace }}"
        label_selectors:
          - "app.kubernetes.io/name={{ helm_release_name }}"
        kubeconfig: "{{ merged_kubeconf_file }}"
      register: pods
      retries: 10
      delay: 5
      until: pods.resources | length == 0

    - name: "6. Removal complete"
      ansible.builtin.debug:
        msg: "{{ helm_release_name }} removed from {{ namespace }}"
```

### Key patterns for removal:

- **`failed_when: false`** on most tasks (service may already be removed)
- **Optional PVC removal** via `remove_pvc` flag (data preservation by default)
- **Same-file deploy/remove** pattern: Some services (e.g., whoami) use a single playbook with `-e operation=delete`

---

## Finding 6: Secrets Integration

### How secrets flow to services

```
User edits:     .uis.secrets/secrets-config/00-common-values.env.template
                    │
                    ▼ (source as bash variables)
Template:       .uis.secrets/secrets-config/00-master-secrets.yml.template
                    │
                    ▼ (envsubst)
Generated:      .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
                    │
                    ▼ (kubectl apply)
Kubernetes:     Secret "urbalurba-secrets" in each namespace
                    │
                    ▼ (read by playbook)
Playbook:       kubectl get secret ... -o jsonpath="{.data.KEY}" | base64 -d
                    │
                    ▼ (passed to Helm)
Helm:           --set auth.password=$value
```

### Adding secrets for a new service

**Step 1:** Add variables to `provision-host/uis/templates/secrets-templates/00-common-values.env.template`:

```bash
# My Service
MYSERVICE_API_KEY=your-api-key-here
MYSERVICE_DB_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
```

**Step 2:** Add a Secret block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`:

```yaml
---
# If service uses its own namespace:
apiVersion: v1
kind: Namespace
metadata:
  name: myservice
---
apiVersion: v1
kind: Secret
metadata:
  name: urbalurba-secrets
  namespace: myservice
type: Opaque
stringData:
  MYSERVICE_API_KEY: "${MYSERVICE_API_KEY}"
  MYSERVICE_DB_PASSWORD: "${MYSERVICE_DB_PASSWORD}"
```

Or add keys to an existing namespace's secret block if the service deploys into `default`, `ai`, etc.

**Step 3:** Add defaults to `provision-host/uis/templates/default-secrets.env`:

```bash
DEFAULT_MYSERVICE_API_KEY="LocalDevMyService123"
```

**Step 4:** In the setup playbook, read the secret:

```yaml
- name: Get API key from secrets
  ansible.builtin.shell: >
    kubectl get secret urbalurba-secrets -n myservice
    -o jsonpath="{.data.MYSERVICE_API_KEY}"
    --kubeconfig {{ merged_kubeconf_file }} | base64 -d
  register: api_key
  changed_when: false
```

### Existing namespace secrets

| Namespace | Secret Name | Contains |
|-----------|-------------|----------|
| `default` | `urbalurba-secrets` | DB passwords, Redis, Tailscale, Cloudflare, GitHub, pgAdmin, ArgoCD, Gravitee |
| `ai` | `urbalurba-secrets` | OpenWebUI DB, LiteLLM API keys, OAuth config |
| `argocd` | `urbalurba-secrets` | ArgoCD admin password (plaintext) |
| `authentik` | `urbalurba-secrets` | Secret key, DB/Redis credentials, bootstrap password |
| `monitoring` | `urbalurba-secrets` | Grafana admin credentials |
| `jupyterhub` | `urbalurba-secrets` | JupyterHub auth password |
| `unity-catalog` | `urbalurba-secrets` | Database URL and credentials |

### Password restrictions

- **DO NOT USE** in passwords: `!`, `$`, `` ` ``, `\`, `"`
- Bitnami Helm charts pass passwords through bash, which escapes these characters
- Admin email **must** have a real domain (not `admin@localhost`) — pgAdmin requires it

---

## Finding 7: IngressRoute Pattern

Services accessible via browser need a Traefik IngressRoute. The standard pattern:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myservice
  namespace: myservice-namespace
spec:
  entryPoints:
    - web
  routes:
    - match: "HostRegexp(`myservice\\..+`)"
      kind: Rule
      services:
        - name: myservice-svc
          port: 8080
```

### Routing patterns used in the platform

| Pattern | Matches | Used By |
|---------|---------|---------|
| `HostRegexp(`name\..+`)` | name.localhost, name.example.com | Most services |
| `Host(`name.localhost`)` | Only name.localhost | Development-only |
| `PathPrefix(`/path`)` | Any host + /path | API services |

The `HostRegexp` pattern is preferred because it works across localhost, Tailscale, and Cloudflare domains without changes.

---

## Finding 8: Manifest Numbering Convention

| Range | Category | Examples |
|-------|----------|----------|
| 000-009 | Storage classes | `000-storage-class-alias.yaml` |
| 003-015 | Traefik & Ingress | `003-traefik-config.yaml`, `012-traefik-nginx-ingress.yaml` |
| 020-029 | Nginx, Whoami | `020-nginx-config.yaml`, `025-whoami-*.yaml` |
| 030-039 | Prometheus, Grafana | `030-prometheus-config.yaml`, `034-grafana-config.yaml` |
| 040-069 | Databases | `040-mongodb-*.yaml`, `042-postgresql-*.yaml` |
| 070-079 | Authentik | `070-whoami-*.yaml`, `073-authentik-*.yaml` |
| 080-091 | RabbitMQ, Gravitee | `080-rabbitmq-*.yaml`, `090-gravitee-*.yaml` |
| 200-210 | AI services | `200-ai-*.yaml`, `208-openwebui-*.yaml` |
| 220-229 | ArgoCD | `220-argocd-*.yaml` (management, but numbered in 200-range) |
| 230-239 | Observability extras | `230-otel-*.yaml`, `231-loki-*.yaml` |
| 300-399 | Analytics | `300-spark-*.yaml`, `310-jupyterhub-*.yaml`, `320-unity-*.yaml` |
| 600-699 | Admin tools | `641-pgadmin.yaml`, `650-redisinsight-*.yaml` |
| 800-820 | Networking | `800-tailscale-*.yaml`, `810-cloudflare-*.yaml` |

Pick a number in the appropriate range for your service.

---

## Finding 9: The `uis deploy` vs `uis deploy <service>` Difference

### `uis deploy` (no argument)

Deploys **all enabled services** from `.uis.extend/enabled-services.conf`:

1. Reads config file line by line
2. Deploys each service sequentially
3. **Stops on first failure** (fail-fast)
4. Order is determined by config file order combined with `SCRIPT_PRIORITY`

### `uis deploy <service-id>`

Deploys a **single service**:

1. Finds the service definition in `provision-host/uis/services/`
2. Checks dependencies (`SCRIPT_REQUIRES`)
3. Runs the playbook or applies the manifest
4. Runs health check
5. **Auto-enables the service** in `enabled-services.conf` (so it deploys on next `uis deploy`)

This means `uis deploy myservice` is sufficient — no need to run `uis enable` separately.

### `uis enable <service-id>`

Only adds the service to `enabled-services.conf`. Does **not** deploy it. Useful for configuring which services deploy on next `uis deploy` without deploying immediately.

### `uis undeploy <service-id>`

Removes a deployed service. Calls `remove_single_service()` which uses `SCRIPT_REMOVE_PLAYBOOK`. Does **not** remove from `enabled-services.conf` — use `uis disable` for that.

### `uis disable <service-id>`

Removes from `enabled-services.conf`. Does **not** undeploy — the service keeps running until explicitly removed.

---

## Finding 10: Existing Services as References

### Simple (manifest-only, no Helm): Whoami

```
provision-host/uis/services/management/service-whoami.sh
ansible/playbooks/025-setup-whoami-testpod.yml
manifests/070-whoami-service-and-deployment.yaml
manifests/025-whoami-ingressroute-*.yaml
```

### Medium (Helm-based database): PostgreSQL

```
provision-host/uis/services/databases/service-postgresql.sh
ansible/playbooks/040-database-postgresql.yml
ansible/playbooks/040-remove-database-postgresql.yml
manifests/042-database-postgresql-config.yaml
```

### Complex (Helm + secrets + auth): OpenWebUI

```
provision-host/uis/services/ai/service-openwebui.sh
ansible/playbooks/200-setup-open-webui.yml
ansible/playbooks/200-remove-open-webui.yml
manifests/200-ai-persistent-storage.yaml
manifests/208-openwebui-config.yaml
```

### Complex (Helm + blueprints + middleware): Authentik

```
provision-host/uis/services/identity/service-authentik.sh
ansible/playbooks/070-setup-authentik.yml
ansible/playbooks/070-remove-authentik.yml
manifests/073-authentik-*.yaml (multiple blueprint files)
manifests/075-authentik-config.yaml.j2
manifests/076-authentik-csp-middleware.yaml
```

---

## Finding 11: Documentation Integration

When adding a service, the documentation page goes in `website/docs/services/<category>/`:

1. Create `website/docs/services/<category>/myservice.md`
2. Add to `website/sidebars.ts` under the appropriate category
3. Run `npm run build` in `website/` to verify no broken links

The `uis-docs.sh` script generates JSON files from service metadata for the website:
- `services.json` — all service metadata (from `service-*.sh` files)
- `categories.json` — category definitions (from `categories.sh`)
- `stacks.json` — stack definitions (from `stacks.sh`)
- `tools.json` — tools metadata

This means the website metadata fields in service definitions (`SCRIPT_ABSTRACT`, `SCRIPT_TAGS`, `SCRIPT_SUMMARY`, `SCRIPT_LOGO`, `SCRIPT_DOCS`) are consumed by a real pipeline — fill them in.

---

## Finding 12: CI/CD Pipeline

The service itself is not tested in CI/CD directly, but:

- `test-uis.yml` — Tests `uis-cli.sh` commands (list, enable, disable, version)
- `build-container.yml` — Builds the container image (triggered by changes to `provision-host/uis/**`)
- `deploy-docs.yml` — Builds and deploys the documentation website

New service definitions and playbooks are included in the container image automatically when merged to main.

**Validation commands** available locally:
- `uis test-all` — Full integration test: deploys and undeploys all services
- `uis test-all --dry-run` — Show test plan without executing
- `uis test-all --only <svc>` — Test specific service + dependencies

---

## Finding 13: ArgoCD Registration — A Separate Deployment Path

The `uis argocd register` command is a **completely different flow** from `uis deploy`. It deploys user applications (external GitHub repos), not infrastructure services.

```
uis argocd register <app-name> <github-repo-url>
    │
    └─ ansible/playbooks/argocd-register-app.yml
        ├─ Create namespace <app-name>
        ├─ Register repo with ArgoCD
        ├─ Create ArgoCD Application resource
        ├─ Wait for sync
        ├─ Discover Service in namespace
        ├─ Auto-create platform IngressRoute (HostRegexp pattern)
        └─ Report URL: http://<app-name>.localhost
```

Key differences from `uis deploy`:
- No service definition file needed
- No `enabled-services.conf` entry
- ArgoCD manages the deployment lifecycle (sync, health, rollback)
- The platform auto-creates an IngressRoute so the app is accessible at `<app-name>.localhost`
- Removal via `uis argocd remove <app-name>` (deletes namespace, which cascades)

**Relevance to adding new services:** If your new service is a platform infrastructure service (database, monitoring tool, etc.), use the `uis deploy` path. If it's a user-facing application deployed from a GitHub repo, use `uis argocd register`.

---

## Finding 14: Stacks — Deploying Groups of Services

Stacks are predefined groups of related services. Defined in `provision-host/uis/lib/stacks.sh`.

| Stack | Services | Description |
|-------|----------|-------------|
| `observability` | prometheus, tempo, loki, otel-collector, grafana | Full monitoring stack |
| `ai-local` | litellm, openwebui | Local AI with external API proxying |
| `analytics` | spark, jupyterhub, unity-catalog | Data science platforms |

Commands:
- `uis stack list` — list available stacks
- `uis stack info <stack>` — show services in a stack
- `uis stack install <stack>` — deploy all services in the stack
- `uis stack install <stack> --skip-optional` — deploy only required services
- `uis stack remove <stack>` — remove all services in the stack

**Relevance to adding new services:** If your service belongs to a logical group, consider adding it to an existing stack or creating a new one in `stacks.sh`.

---

## Finding 15: Service Overrides — User Customization

Users can override Helm values for any service without modifying platform files.

**Location:** `.uis.extend/service-overrides/<service-id>-config.yaml`

This directory is created during first-run initialization. Users place custom Helm values files here, which are merged with the platform defaults during deployment.

**Relevance to adding new services:** Your setup playbook should check for and apply service overrides if they exist, following the pattern used by other services.

---

## Finding 16: Helm Repository Prerequisite

Before deploying Helm-based services, the Helm repositories must be registered. This is handled by:

**File:** `ansible/playbooks/05-install-helm-repos.yml`

This playbook adds all required Helm repos and runs `helm repo update`. It's called during cluster provisioning, not during individual service deployment. If your service uses a Helm chart from a new repo, add the repo to this playbook.

---

## Checklist: Adding a New Service

### Step-by-step

- [ ] **1. Choose category and manifest number range** (see Finding 3 and Finding 8)
- [ ] **2. Create service definition** in `provision-host/uis/services/<category>/service-<id>.sh` — include all required fields and website metadata
- [ ] **3. Add Helm repo** to `ansible/playbooks/05-install-helm-repos.yml` if using a new Helm repository
- [ ] **4. Create Helm values / config** in `manifests/NNN-myservice-config.yaml`
- [ ] **5. Create IngressRoute** in `manifests/NNN-myservice-ingressroute.yaml` (if web-accessible, use `HostRegexp` pattern)
- [ ] **6. Create setup playbook** in `ansible/playbooks/NNN-setup-myservice.yml` (see Finding 4 template)
- [ ] **7. Create remove playbook** in `ansible/playbooks/NNN-remove-myservice.yml` (see Finding 5 template)
- [ ] **8. Add secrets** if service needs credentials — edit all three template files (see Finding 6)
- [ ] **9. Add to default enabled-services.conf** (commented out) in `provision-host/uis/templates/uis.extend/enabled-services.conf.default`
- [ ] **10. Consider adding to a stack** in `provision-host/uis/lib/stacks.sh` if part of a logical group
- [ ] **11. Create documentation** page in `website/docs/services/<category>/` and add to `website/sidebars.ts`
- [ ] **12. Test deployment**: `uis deploy myservice` (auto-enables)
- [ ] **13. Test removal**: `uis undeploy myservice`
- [ ] **14. Verify**: `uis list` shows the service with correct category and metadata
- [ ] **15. Run site build**: `cd website && npm run build` to check for broken links

---

## Next Steps

- [ ] This investigation is complete and can be used as-is for reference
- [ ] Consider creating a PLAN for a scaffolding script (`uis service create <id>`) that generates the boilerplate files
