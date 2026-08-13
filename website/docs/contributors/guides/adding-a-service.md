# Adding a Service

This guide walks through the complete process of adding a new infrastructure service to UIS. By the end, your service will be deployable with `./uis deploy myservice`, removable with `./uis undeploy myservice`, and visible in the docs.

## Overview

A UIS service consists of these pieces:

| Piece | File | Purpose |
|-------|------|---------|
| Service definition | `provision-host/uis/services/<category>/service-<id>.sh` | Metadata — tells the CLI about the service |
| Setup playbook | `ansible/playbooks/NNN-setup-<id>.yml` | Deploys the service via Helm or kubectl |
| Remove playbook | `ansible/playbooks/NNN-remove-<id>.yml` | Removes the service cleanly |
| Config / Helm values | `manifests/NNN-<id>-config.yaml` | Helm values or ConfigMap |
| IngressRoute | `manifests/NNN-<id>-ingressroute.yaml` | Traefik routing (if web-accessible) |
| Secrets entries | Three template files in `provision-host/uis/templates/` | Credentials (if needed) |
| Documentation | `website/docs/services/<category>/<id>.md` | Docs website page |

The numbered prefix (`NNN`) comes from the manifest numbering convention for your service's category.

## Prerequisites

Before starting, read these pages for context:

- **[Provisioning Rules](../rules/provisioning.md)** — Ansible playbook patterns and conventions
- **[Secrets Management Rules](../rules/secrets-management.md)** — How secrets flow through the platform
- **[Ingress and Traefik Rules](../rules/ingress-traefik.md)** — Routing and IngressRoute patterns
- **[Kubernetes Deployment Rules](../rules/kubernetes-deployment.md)** — Service metadata, deploy flow, and categories
- **[Manifests Architecture](../architecture/manifests.md)** — Manifest organization and numbering

## Step 1: Choose a category and manifest number

Services are organized into categories. Pick the one that fits:

| Category ID | Manifest Range | Examples |
|-------------|----------------|----------|
| `OBSERVABILITY` | 030-039, 230-239 | Prometheus, Grafana, Loki |
| `AI` | 200-229 | OpenWebUI, LiteLLM |
| `ANALYTICS` | 300-399 | Spark, JupyterHub |
| `IDENTITY` | 070-079 | Authentik |
| `DATABASES` | 040-044, 050-069 | PostgreSQL, MongoDB, Redis |
| `MANAGEMENT` | 600-799 | pgAdmin, ArgoCD |
| `NETWORKING` | 800-820 | Tailscale, Cloudflare tunnels |
| `STORAGE` | 000-009, 045-046 | Storage classes, MinIO |
| `INTEGRATION` | 080-091 | RabbitMQ, Gravitee |

Pick an unused number within your category's range for the manifest prefix.

## Step 2: Create the service definition

Create `provision-host/uis/services/<category>/service-<id>.sh`:

```bash
#!/bin/bash
# service-myservice.sh - My Service metadata

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
SCRIPT_IMAGE="vendor/image:tag"
SCRIPT_HELM_CHART="repo/chart-name"
SCRIPT_NAMESPACE="default"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS=""        # API names this service provides (e.g., "myservice-api")
SCRIPT_CONSUMES_APIS=""        # API names this service consumes (e.g., "litellm-api")

# === Website Metadata (Optional) ===
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
| `SCRIPT_ID` | Yes | Unique identifier used in CLI commands |
| `SCRIPT_NAME` | Yes | Display name |
| `SCRIPT_DESCRIPTION` | Yes | One-line description |
| `SCRIPT_CATEGORY` | Yes | Must match a category ID from the table above |
| `SCRIPT_PLAYBOOK` | Yes | Ansible playbook filename (in `ansible/playbooks/`) |
| `SCRIPT_MANIFEST` | No | Kubernetes manifest (alternative to playbook — not currently used by any service) |
| `SCRIPT_CHECK_COMMAND` | No | Shell command that exits 0 if service is healthy |
| `SCRIPT_REMOVE_PLAYBOOK` | No | Playbook for removal |
| `SCRIPT_REQUIRES` | No | Space-separated service IDs this service depends on |
| `SCRIPT_PRIORITY` | No | Deploy order — lower numbers deploy first (default: 50) |
| `SCRIPT_MULTI_INSTANCE` | No | Set to `"true"` if the service ships one Deployment per consuming app (e.g. PostgREST). Default `"false"`. See [Multi-instance services](#multi-instance-services). |
| `SCRIPT_IMAGE` | No | Container image reference (e.g., `enonic/xp:7.16.2-ubuntu`) |
| `SCRIPT_HELM_CHART` | No | Helm chart reference |
| `SCRIPT_NAMESPACE` | No | Kubernetes namespace |
| `SCRIPT_KIND` | No | `Component` (software) or `Resource` (infrastructure like databases). Default: `Component` |
| `SCRIPT_TYPE` | No | What kind of component/resource: `service`, `tool`, `library`, `database`, `cache`, `message-broker`. Default: `service` |
| `SCRIPT_OWNER` | No | Owning team: `platform-team` or `app-team`. Default: `platform-team` |
| `SCRIPT_PROVIDES_APIS` | No | Space-separated API names this service provides (generates `kind: API` entities in Backstage) |
| `SCRIPT_CONSUMES_APIS` | No | Space-separated API names this service consumes (shown in Backstage "Consumed APIs" tab) |

Website metadata fields (`SCRIPT_ABSTRACT`, `SCRIPT_TAGS`, etc.) are consumed by `uis-docs.sh` to generate JSON for the documentation website. Fill them in.

**Constraints:**
- `SCRIPT_PLAYBOOK` and `SCRIPT_MANIFEST` are mutually exclusive (playbook takes precedence)
- Each variable must be on its own line in `KEY="value"` format (the scanner parses line-by-line)
- Files starting with `_` are ignored by the scanner

## Step 3: Create the Helm values / config manifest

Create `manifests/NNN-myservice-config.yaml` with Helm values or a ConfigMap. This file is referenced by the setup playbook.

See **[Manifests Architecture](../architecture/manifests.md)** for organization patterns.

## Step 4: Create the IngressRoute manifest

If your service has a web UI, create `manifests/NNN-myservice-ingressroute.yaml`:

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

Use `HostRegexp` so the route works across localhost, Tailscale, and Cloudflare domains without changes. See **[Ingress and Traefik Rules](../rules/ingress-traefik.md)** for all routing patterns.

## Step 5: Create the setup playbook

Create `ansible/playbooks/NNN-setup-myservice.yml`:

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
    _target: "{{ target_host | default('rancher-desktop') }}"
    merged_kubeconf_file: "/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"
    namespace: "myservice-namespace"
    component_name: "myservice"
    manifests_folder: "/mnt/urbalurbadisk/manifests"
    config_file: "{{ manifests_folder }}/NNN-myservice-config.yaml"
    ingressroute_file: "{{ manifests_folder }}/NNN-myservice-ingressroute.yaml"
    helm_release_name: "myservice"
    helm_chart: "repo/myservice"

  tasks:
    - name: "1. Create {{ namespace }} namespace"
      kubernetes.core.k8s:
        name: "{{ namespace }}"
        api_version: v1
        kind: Namespace
        state: present
        kubeconfig: "{{ merged_kubeconf_file }}"

    - name: "2. Install/upgrade via Helm"
      kubernetes.core.helm:
        name: "{{ helm_release_name }}"
        chart_ref: "{{ helm_chart }}"
        release_namespace: "{{ namespace }}"
        create_namespace: true
        state: present
        kubeconfig: "{{ merged_kubeconf_file }}"
        values_files:
          - "{{ config_file }}"

    - name: "3. Deploy IngressRoute"
      kubernetes.core.k8s:
        state: present
        src: "{{ ingressroute_file }}"
        kubeconfig: "{{ merged_kubeconf_file }}"

    - name: "4. Wait for {{ component_name }} to be ready"
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

    - name: "5. Deployment complete"
      ansible.builtin.debug:
        msg:
          - "{{ component_name }} deployed successfully"
          - "URL: http://{{ component_name }}.localhost"
```

**Key conventions:**
- `_target` uses underscore prefix (avoids Ansible recursive template issue)
- Always pass `kubeconfig: "{{ merged_kubeconf_file }}"` to k8s modules
- Number task names for readability
- Use `changed_when: false` on read-only shell commands
- Use `no_log: true` on any task handling secrets

See **[Provisioning Rules](../rules/provisioning.md)** for full playbook conventions.

## Step 5b: Create the verify playbook (optional but recommended)

If your service has an HTTP endpoint, create a verify playbook at `ansible/playbooks/NNN-test-<id>.yml`. This gives you automated E2E tests that run with `./uis verify myservice`.

**Naming convention:** `NNN-test-<id>.yml` (same number prefix as your setup playbook).

**Standard structure:**

```yaml
---
# NNN-test-myservice.yml
# E2E verification tests for My Service

- name: Verify My Service
  hosts: localhost
  connection: local
  gather_facts: false

  vars:
    namespace: "myservice-namespace"
    merged_kubeconf_file: "/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"

  tasks:
    # --- Setup ---
    - name: "0.1 Get myservice pod name"
      # ... lookup pod for kubectl exec / curl tests

    # --- Test A: Health endpoint ---
    - name: "A1. Check health endpoint"
      ansible.builtin.shell: >
        kubectl run curl-test-a1 --image=curlimages/curl ...
      register: test_a_result

    - name: "A2. Assert health check passed"
      ansible.builtin.assert:
        that: "'UP' in test_a_result.stdout"

    - name: "A3. Display health result"
      ansible.builtin.debug:
        msg: "{{ test_a_result.stdout }}"

    # --- Test B, C, D ... follow same 3-task pattern ---

    # --- Summary ---
    - name: "SUMMARY - Display all test results"
      ansible.builtin.debug:
        msg:
          - "A. Health check: PASS"
          - "B. Auth check: PASS"
          # ...
```

Each test group (A–F) follows a 3-task pattern: **run** the test, **assert** the result, **display** the output. Common test types:

| Test | What it checks |
|------|---------------|
| Health endpoint | Service is running and responding |
| Authentication | Correct credentials return 200, wrong credentials return 401 |
| Data read-back | Service stores/returns data correctly |
| Traefik routing | IngressRoute resolves to the service |
| Management port | Metrics or management endpoint is reachable |

**Registration — two files to update:**

1. Add your service to `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh`:

```bash
VERIFY_SERVICES="
argocd:argocd verify
enonic:enonic verify
openmetadata:openmetadata verify
myservice:myservice verify
"
```

2. Add a dispatch case in `cmd_verify()` in `provision-host/uis/manage/uis-cli.sh`:

```bash
myservice)
    cmd_myservice_verify
    ;;
```

And implement `cmd_myservice_verify()` that calls `ansible-playbook NNN-test-myservice.yml`.

**Existing verify playbooks to reference:** ArgoCD (`025-test-argocd.yml`), Enonic XP (`085-test-enonic.yml`), OpenMetadata (`300-test-openmetadata.yml`).

For the full testing framework — how `test-all` works, how to register your verify playbook, and current test coverage — see the **[Integration Testing Guide](./integration-testing.md)**.

## Step 5c: Alternative — StatefulSet pattern (no Helm)

Not every service needs Helm. If the service has no official Helm chart, uses embedded storage, or is simpler to deploy directly, use a **StatefulSet manifest** instead.

Create a single manifest file `manifests/NNN-<id>-statefulset.yaml` containing:

- **PersistentVolumeClaim** — for data that survives pod restarts
- **StatefulSet** — the workload definition with volume mounts
- **Service (ClusterIP)** — exposes all ports needed (web, management, metrics)

The setup playbook then uses `kubectl apply` instead of Helm:

```yaml
- name: "2. Deploy StatefulSet + Service + PVC"
  kubernetes.core.k8s:
    state: present
    src: "{{ statefulset_file }}"
    kubeconfig: "{{ merged_kubeconf_file }}"
```

**When to use this pattern:**
- No official or maintained Helm chart exists
- Service has embedded storage (e.g., an application server with its own database)
- Helm adds complexity without benefit for simple deployments

**Reference:** Enonic XP (`manifests/085-enonic-statefulset.yaml`) — StatefulSet with PVC, 3-port Service, and a command override to inject configuration at startup.

## Step 6: Create the remove playbook

Create `ansible/playbooks/NNN-remove-myservice.yml`:

```yaml
---
# NNN-remove-myservice.yml
# Remove My Service from the Kubernetes cluster

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
    - name: "1. Check for Helm release"
      ansible.builtin.shell: >
        helm status {{ helm_release_name }} -n {{ namespace }}
        --kubeconfig {{ merged_kubeconf_file }}
      register: helm_check
      failed_when: false
      changed_when: false

    - name: "2. Remove Helm release"
      kubernetes.core.helm:
        name: "{{ helm_release_name }}"
        release_namespace: "{{ namespace }}"
        state: absent
        kubeconfig: "{{ merged_kubeconf_file }}"
      when: helm_check.rc == 0

    - name: "3. Remove PVCs (optional)"
      ansible.builtin.shell: >
        kubectl delete pvc -l app.kubernetes.io/name={{ helm_release_name }}
        -n {{ namespace }} --kubeconfig {{ merged_kubeconf_file }}
      when: _remove_pvc
      failed_when: false

    - name: "4. Remove IngressRoute"
      kubernetes.core.k8s:
        state: absent
        kind: IngressRoute
        api_version: traefik.io/v1alpha1
        name: "{{ helm_release_name }}"
        namespace: "{{ namespace }}"
        kubeconfig: "{{ merged_kubeconf_file }}"
      failed_when: false

    - name: "5. Removal complete"
      ansible.builtin.debug:
        msg: "{{ helm_release_name }} removed from {{ namespace }}"
```

**Key conventions:**
- Use `failed_when: false` on most tasks (service may already be removed)
- PVC removal is opt-in via `remove_pvc` flag (preserves data by default)

## Step 7: Add secrets (if needed)

If your service requires credentials, edit three template files in `provision-host/uis/templates/`:

**1. Add variables** to `secrets-templates/00-common-values.env.template`:

```bash
# My Service
MYSERVICE_API_KEY=your-api-key-here
MYSERVICE_DB_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
```

**2. Add a Secret block** to `secrets-templates/00-master-secrets.yml.template`:

```yaml
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

Or add keys to an existing namespace's secret block if your service deploys into `default`, `ai`, etc.

**3. Add defaults** to `default-secrets.env`:

```bash
DEFAULT_MYSERVICE_API_KEY="LocalDevMyService123"
```

**4. Read the secret** in your setup playbook:

```yaml
- name: Get API key from secrets
  ansible.builtin.shell: >
    kubectl get secret urbalurba-secrets -n myservice
    -o jsonpath="{.data.MYSERVICE_API_KEY}"
    --kubeconfig {{ merged_kubeconf_file }} | base64 -d
  register: api_key
  changed_when: false
```

**Password restrictions:** Do not use `!`, `$`, `` ` ``, `\`, or `"` in passwords — Bitnami Helm charts pass passwords through bash, which breaks on these characters.

See **[Secrets Architecture](../architecture/secrets.md)** for the full secrets flow.

## Step 8: Add Helm repository (if needed)

If your service uses a Helm chart from a repository not already registered, add it to `ansible/playbooks/05-install-helm-repos.yml`. This playbook runs during cluster provisioning and ensures all Helm repos are available.

## Step 9: Add to enabled-services.conf

Add a commented-out entry to the default template at `provision-host/uis/templates/uis.extend/enabled-services.conf.default`. This lets users opt in by uncommenting the line.

Note: `./uis deploy myservice` automatically enables the service, so users don't need to manually edit this file. The default template just documents what's available.

## Step 10: Consider stack membership

If your service belongs to a logical group (e.g., a monitoring tool alongside Prometheus and Grafana), consider adding it to an existing stack or creating a new one in `provision-host/uis/lib/stacks.sh`.

See **[Kubernetes Deployment Rules](../rules/kubernetes-deployment.md)** for stack definitions.

## Step 11: Create documentation

1. Create `website/docs/services/<category>/myservice.md`
2. Add the page to `website/sidebars.ts` under the appropriate category
3. Build the site to verify no broken links

```bash
cd website && npm run build
```

**No Node installed? Use the container.** Neither the workstation nor the
provision-host container ships Node, so this step kept being skipped — a
required check nobody could run on the machines they actually use. This needs
nothing but Docker, and pins the same Node version CI uses:

```bash
cd website && docker run --rm -u $(id -u):$(id -g) \
  -v "$PWD":/w -w /w -e HOME=/tmp -e CI=true node:20 \
  sh -c 'npm ci && npm run build'
```

First run takes a few minutes for `npm ci`. It writes `node_modules/` and
`build/` into `website/` — both gitignored, and together ~1.7 GB, so delete them
afterwards if you are working on a small disk.

⚠️ **Read the warnings, not just the exit code.** Broken links and broken anchors
are reported as warnings and the build still exits 0 — and CI does not fail on
them either. A green build with `[WARNING] Docusaurus found broken links` in it
is a failure you have to look for.

See **[Documentation Standards](../rules/documentation.md)** for page conventions.

## Testing

Deploy, remove, and verify:

```bash
# Deploy the service (also auto-enables it)
./uis deploy myservice

# Check it's running
./uis status

# Run E2E verify tests (if you created a verify playbook)
./uis verify myservice

# Test removal
./uis undeploy myservice

# Verify it appears correctly in the service list
./uis list

# Test just your service and its dependencies
./uis test-all --only myservice

# Build the docs site to check for broken links
cd website && npm run build
```

If you created a verify playbook, make sure it is registered in both `integration-testing.sh` (VERIFY_SERVICES) and `uis-cli.sh` (cmd_verify) as described in Step 5b.

## Multi-instance services

A few platform services ship **one instance per consuming application** rather than one shared instance per cluster. PostgREST is the first — every consuming app gets its own PostgREST Deployment, all sharing the `postgrest` namespace and the platform's PostgreSQL. The lifecycle becomes `./uis configure postgrest --app atlas` then `./uis deploy postgrest --app atlas`, repeated per app.

If you're adding a service that fits this shape, the conventions below are what you need on top of the single-instance flow already covered above. The full worked example is [INVESTIGATE-postgrest.md](../../ai-developer/plans/completed/INVESTIGATE-postgrest.md) — read it for the design rationale; this section is the contributor checklist.

### When to use the multi-instance shape

Use it when each consuming application needs its own copy of the service with its own configuration, credentials, or routing — and a single shared instance would not be safe or sensible to share. Example: PostgREST exposes a per-app Postgres schema, so different apps need different `PGRST_DB_URI` values, different `web_anon` roles, and different public URL prefixes.

If a single shared instance is appropriate (most services — postgresql, redis, prometheus, grafana), do **not** use this shape. Single-instance is simpler and the rest of this guide already covers it.

### The `multiInstance` flag

In your `service-<id>.sh`, add:

```bash
SCRIPT_MULTI_INSTANCE="true"
```

The scanner emits this as `"multiInstance": true` in `services.json`, and the rest of the platform reads from there:

- `configure.sh` — multi-instance services pre-check that **the dependency** is deployed (e.g. postgresql), not the service itself, since there is no shared "the service" to check.
- `uis-cli.sh` — `./uis deploy <svc>` and `./uis undeploy <svc>` **require** `--app <name>` for multi-instance services and **reject** it for single-instance services. Defaults are applied: `--url-prefix=api-<app>` and `--schema=api_v1`.
- `./uis status` and `./uis list` formatters (today: count-only; full per-instance rows are PLAN-005 work).

### The `ansible/playbooks/templates/` directory

Multi-instance services cannot use static `manifests/<NNN>-<id>-*.yaml` files — each instance needs different metadata, env-vars, and IngressRoute hostnames. Instead, put **Jinja templates** in `ansible/playbooks/templates/` and render them at playbook-execution time. The templates are parametrised by per-app extra-vars (`_app_name`, `_url_prefix`, `_schema`).

File naming: `<NNN>-<service>-<role>.yml.j2`, same numeric prefix as the service number in `service-<id>.sh`. Example for PostgREST (`SCRIPT_PLAYBOOK="088-setup-postgrest.yml"`):

```
ansible/playbooks/templates/088-postgrest-config.yml.j2          # Deployment + Service
ansible/playbooks/templates/088-postgrest-ingressroute.yml.j2    # Traefik IngressRoute
```

The full convention — including standard extra-var names and how to use `lookup('template', ...) | from_yaml_all | list` for templates that emit multiple YAML documents — lives in [`ansible/playbooks/templates/README.md`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/templates/README.md). Read it before writing your first template.

### Per-app extra-vars

The CLI translates `--app <name>` (and any defaults it applies) into Ansible extra-vars with an underscore prefix, matching the existing `_target` convention in [provisioning.md](../rules/provisioning.md):

| Extra-var | Source | Required |
|---|---|---|
| `_app_name` | `--app <name>` (no default) | yes — multi-instance deploy fails without it |
| `_url_prefix` | `--url-prefix <name>` (default: `api-<app_name>`) | optional, default applied |
| `_schema` | `--schema <name>` (default: `api_v1` for PostgREST; service-defined elsewhere) | optional, default applied |

Service-specific extra-vars (e.g. `_db_role` for PostgREST) are added by the configure handler and documented at the top of the corresponding setup playbook.

### Configure vs deploy split

Multi-instance services almost always need a **configure** step that runs before deploy: it creates per-app credentials, secrets, or roles in an upstream service, and puts the result somewhere the deploy step can pick it up.

Add a handler at `provision-host/uis/lib/configure-<id>.sh` (no `handlers/` subdir — match the existing `configure-postgresql.sh` shape). The handler is dispatched by the configure flag-parser in `provision-host/uis/lib/configure.sh` and receives the per-app context (`app_name`, `database_name`, `schema`, `url_prefix`, …).

The `deploy` playbook in turn **assumes** configure has already run and errors clearly if its preconditions are missing — the user should always be able to fix the error by running the configure step the message tells them to run.

For the lifecycle conventions (idempotent re-configure, `--rotate` to regenerate credentials, `--purge` to remove per-app state, removal-without-purge so re-deploy works without re-configure), see Decisions #16–#20 in [INVESTIGATE-postgrest.md](../../ai-developer/plans/completed/INVESTIGATE-postgrest.md).

### Worked example: PostgREST

Read these in order if you're adding a second multi-instance service:

| File | What it shows |
|---|---|
| [`service-postgrest.sh`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/provision-host/uis/services/integration/service-postgrest.sh) | `SCRIPT_MULTI_INSTANCE="true"`, the playbook references, image pinning |
| [`configure-postgrest.sh`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/provision-host/uis/lib/configure-postgrest.sh) | Per-app role creation, secret writing, idempotent re-configure, rotate, purge |
| [`088-setup-postgrest.yml`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/088-setup-postgrest.yml) | Reads extra-vars, errors on missing prereqs, renders both templates |
| [`088-postgrest-config.yml.j2`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/templates/088-postgrest-config.yml.j2) | Deployment + Service in one file (multi-doc YAML) |
| [`088-postgrest-ingressroute.yml.j2`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/templates/088-postgrest-ingressroute.yml.j2) | Per-app HostRegexp routing |
| [`088-remove-postgrest.yml`](https://github.com/helpers-no/urbalurba-infrastructure/blob/main/ansible/playbooks/088-remove-postgrest.yml) | Removes per-app k8s objects, leaves Postgres roles + secret intact |

## Two deployment paths

UIS has two separate deployment concepts:

- **`./uis deploy`** — Deploys platform infrastructure services (databases, monitoring, auth, etc.). This is what this guide covers.
- **`./uis argocd register`** — Deploys user applications from external GitHub repos via ArgoCD. This is a completely different flow.

If you're packaging a platform service, follow this guide. If you're deploying a user-facing app from a GitHub repo, see the [ArgoCD pipeline docs](../../developing/argocd-pipeline.md).

## Reference services

Use these existing services as examples:

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

### Complex (Helm + dependencies + verify): OpenMetadata

Helm-based with PostgreSQL and Elasticsearch dependencies, post-deploy password change via API, and 6 E2E tests.

```
provision-host/uis/services/analytics/service-openmetadata.sh
ansible/playbooks/300-setup-openmetadata.yml
ansible/playbooks/300-remove-openmetadata.yml
ansible/playbooks/300-test-openmetadata.yml
manifests/300-openmetadata-config.yaml
manifests/300-openmetadata-ingressroute.yaml
```

### Complex (StatefulSet + no Helm + verify): Enonic XP

Direct manifests (no Helm), entrypoint command override for config injection, 3-port Service, and 6 E2E tests.

```
provision-host/uis/services/integration/service-enonic.sh
ansible/playbooks/085-setup-enonic.yml
ansible/playbooks/085-remove-enonic.yml
ansible/playbooks/085-test-enonic.yml
manifests/085-enonic-statefulset.yaml
manifests/085-enonic-config.yaml
manifests/085-enonic-ingressroute.yaml
```

## Lessons learned

Practical pitfalls discovered during real deployments:

- **Verify image tags exist before committing.** Always `docker pull` or check the registry. Vendors use different tag conventions (`-ubuntu`, `-jdk21`, `-alpine`) and not all tags exist for all architectures.

- **Expose all ports needed for testing.** If your verify tests need health or management ports, add them to the Service definition — not just the main web port.

- **Don't assume env vars work for auth.** Check the actual docs. Some services use config files (`system.properties`), post-deploy APIs, or different env var names than expected.

- **Test response content, not just HTTP status.** Services may redirect (307) or return 401 with valid page content. Check the response body for expected strings.

- **First boot may be slow.** Services with embedded databases (Enonic XP, OpenMetadata) create indexes on first boot. Use generous startup probe timeouts (3–5 minutes).

- **Delete PVC data between test rounds.** When debugging auth or config issues, old PVC data from failed attempts can cause confusing behavior. Clean start: `./uis undeploy myservice`, then `kubectl delete pvc -n <namespace> --all`, then `kubectl delete namespace <namespace>`.
