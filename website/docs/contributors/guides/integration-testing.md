# Integration Testing

This page explains how to run the full integration test suite and how to add tests for new services.

## Overview

`./uis test-all` deploys and undeploys every service in the platform, in dependency order, verifying that each one works. It's the definitive test that the system is healthy.

```bash
# Run the full test suite
./uis test-all

# Preview the test plan without executing
./uis test-all --dry-run

# Clean the cluster first, then run tests
./uis test-all --clean

# Test only specific services (and their dependencies)
./uis test-all --only postgresql grafana
```

---

## How It Works

The test runner (`provision-host/uis/lib/integration-testing.sh`) reads service metadata to build a test plan, then executes it in 3 phases:

```
Phase 1: Deploy foundation services
  (services that others depend on — kept running)

Phase 2: Test regular services
  For each service: deploy → verify → undeploy

Phase 3: Cleanup foundation services
  (undeploy in reverse order)
```

### Phase 1: Foundation Services

Foundation services are those required by other services (they appear in some service's `SCRIPT_REQUIRES`). For example, PostgreSQL and Redis are foundation services because Authentik, pgAdmin, OpenWebUI, etc. depend on them.

Foundation services are deployed first and **kept running** throughout the test so that dependent services can be tested against them.

### Phase 2: Regular Services

Each regular service goes through a full cycle:

1. **Deploy** — `./uis deploy <service>`
2. **Verify** — `./uis verify <service>` (if a verify playbook exists)
3. **Undeploy** — `./uis undeploy <service>`

If any step fails, the test suite **stops immediately** and prints a summary of what passed.

### Phase 3: Cleanup

Foundation services are undeployed in **reverse priority order** (highest priority last), cleaning up the cluster.

---

## Test Plan Building

The test plan is built automatically from service metadata:

- **Priority** (`SCRIPT_PRIORITY`): determines deployment order within each phase — lower numbers deploy first
- **Dependencies** (`SCRIPT_REQUIRES`): determines which services are foundation vs regular
- **Skip list**: some services are always skipped or conditionally skipped

### Skip Lists

| Type | Services | Reason |
|------|----------|--------|
| **Always skipped** | Gravitee | Broken before migration — see [Gravitee investigation](../../ai-developer/plans/completed/INVESTIGATE-gravitee-fix.md) |
| **Conditionally skipped** | Tailscale tunnel, Cloudflare tunnel | Require real OAuth credentials. Skipped if secrets contain placeholder values (`your-*`, `*-here`) |

The conditional skip logic checks `.uis.secrets/secrets-config/00-common-values.env.template` for placeholder values.

### The `--only` Filter

When using `--only`, the test runner:

1. Takes the specified services as "regular" (deploy + verify + undeploy)
2. Recursively resolves their dependencies
3. Deploys dependencies as "foundation" (deploy only, kept running)
4. Tests only the requested services

```bash
# This deploys PostgreSQL as foundation, then tests pgAdmin
./uis test-all --only pgadmin
```

### The `--clean` Flag

Before running tests, the runner checks if any services are already deployed. If so:

- **Without `--clean`**: refuses to start (prints deployed services and tells you to add `--clean`)
- **With `--clean`**: undeploys all deployed services first, then runs the test suite

---

## Verify Playbooks

Some services have dedicated **verify playbooks** — Ansible playbooks that run end-to-end tests against the deployed service. These are triggered by `./uis verify <service>`.

### Current Verify Coverage

| Service | Verify Playbook | Tests |
|---------|----------------|-------|
| ArgoCD | `025-test-argocd.yml` | Health endpoint, UI access |
| Backstage | `025-test-backstage.yml` | Health endpoint, catalog API |
| Enonic XP | `085-test-enonic.yml` | Health, management port, content API |
| Nextcloud | `620-test-nextcloud.yml` | Health, login page, WebDAV |
| OpenMetadata | `300-test-openmetadata.yml` | Health, API, authentication |

Services without verify playbooks are still tested — they go through deploy + undeploy. The verify step adds deeper validation.

### Verify Playbook Structure

Each verify playbook follows a consistent 3-task pattern per test group:

```yaml
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
```

Test groups are labeled A through F (or more), each testing a different aspect:

| Test Group | What it checks |
|------------|---------------|
| Health endpoint | Service is running and responding |
| Authentication | Correct credentials return 200, wrong return 401 |
| Data read-back | Service stores/returns data correctly |
| Traefik routing | IngressRoute resolves to the service |
| Management port | Metrics or management endpoint is reachable |

---

## Adding Verify Tests for a New Service

### Step 1: Create the verify playbook

Create `ansible/playbooks/NNN-test-<id>.yml` using the same manifest number as your setup playbook. See [Adding a Service — Step 5b](./adding-a-service.md#step-5b-create-the-verify-playbook-optional-but-recommended) for the full template.

### Step 2: Register in integration-testing.sh

Add your service to `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh`:

```bash
VERIFY_SERVICES="
argocd:argocd verify
backstage:backstage verify
enonic:enonic verify
nextcloud:nextcloud verify
openmetadata:openmetadata verify
myservice:myservice verify
"
```

The format is `service_id:cli_args` — the CLI args are passed to `uis-cli.sh`.

### Step 3: Add dispatch case in uis-cli.sh

Add a case in the `cmd_verify()` function in `provision-host/uis/manage/uis-cli.sh`:

```bash
myservice)
    cmd_myservice_verify
    ;;
```

And implement `cmd_myservice_verify()` that calls `ansible-playbook NNN-test-myservice.yml`.

### Step 4: Test it

```bash
# Test just your service
./uis test-all --only myservice

# Or run verify directly
./uis verify myservice
```

---

## Test Results

The test suite prints a summary table at the end:

```
SERVICE              DEPLOY     UNDEPLOY   VERIFY
─────────────────────────────────────────────────────────
postgresql           PASS       PASS       -
redis                PASS       PASS       -
authentik            PASS       PASS       -
argocd               PASS       PASS       PASS
grafana              PASS       PASS       -
─────────────────────────────────────────────────────────
Result: ALL PASSED (47/47 operations)
```

A log file is written to `/tmp/uis-test-all-<timestamp>.log` for debugging failed tests.

---

## CI/CD Integration

The `test-uis.yml` GitHub Actions workflow runs static tests, unit tests, and JSON validation on every PR. It does **not** run the full `test-all` integration suite because that requires a Kubernetes cluster.

Deploy tests can be triggered manually via workflow dispatch — they use a [kind](https://kind.sigs.k8s.io/) cluster but currently only test a single service (nginx).

See [CI/CD Pipelines and Generators](./ci-cd-and-generators.md) for the full workflow reference.

---

## Related Documentation

- **[Adding a Service — Step 5b](./adding-a-service.md#step-5b-create-the-verify-playbook-optional-but-recommended)** — Verify playbook template and conventions
- **[CI/CD Pipelines and Generators](./ci-cd-and-generators.md)** — GitHub Actions workflow reference
- **[UIS CLI Reference](../../reference/uis-cli-reference.md)** — `test-all` command reference
