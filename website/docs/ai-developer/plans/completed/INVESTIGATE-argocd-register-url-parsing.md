# INVESTIGATE: ArgoCD Register Command Redesign

**Status:** Completed — PLAN implemented and verified
**Created:** 2026-03-03
**Last Updated:** 2026-03-03
**Related to:** [INVESTIGATE-argocd-migration](INVESTIGATE-argocd-migration.md) (completed)
**Plan:** [PLAN-argocd-register-redesign](PLAN-argocd-register-redesign.md)
**Depends on:** None

---

## Problem Statement

`uis argocd register` has two critical issues:

1. **Only accepts bare repo names** — users naturally pass full GitHub URLs, which breaks because the `repo_name` is used directly as the Kubernetes namespace (invalid characters)
2. **Requires GitHub username in secrets** — even for public repos where no authentication is needed

---

## Decision: Two Required Parameters

```bash
uis argocd register <name> <repo-url>
```

- `<name>` — Application name. Used as Kubernetes namespace and ArgoCD app name. Must be DNS-compatible. Must not already be in use.
- `<repo-url>` — Full GitHub HTTPS URL. Must start with `https://`.

No backward compatibility needed — system is not yet released.

### Why two parameters?

- **Name is always explicit** — no URL-to-namespace parsing, no ambiguity
- **Name can differ from repo** — user picks a short, meaningful name
- **URL is always complete** — no guessing, no secrets dependency for public repos
- **Follows established patterns** — `helm install <release> <chart>`, `docker run --name <name> <image>`

### Examples

```bash
# Register a public repo
uis argocd register hello-world https://github.com/terchris/urb-dev-typescript-hello-world

# Name doesn't have to match repo name
uis argocd register my-app https://github.com/someorg/some-long-repo-name

# Remove uses just the name
uis argocd remove hello-world

# List shows all registered apps
uis argocd list
```

### CLI Validation (in `uis-cli.sh`, before calling playbook)

| Check | Error message |
|-------|---------------|
| Missing `<name>` argument | Usage message with examples |
| Missing `<repo-url>` argument | Usage message with examples |
| `<name>` not DNS-compatible | "Name must be lowercase, alphanumeric, and hyphens only (max 63 chars)" |
| `<name>` already in use as namespace | "Name 'X' is already in use. Choose a different name or remove it first: uis argocd remove X" |
| `<repo-url>` doesn't start with `https://` | "Repository URL must be a full HTTPS URL (e.g., https://github.com/owner/repo)" |

### Help text

```
Usage: uis argocd register <name> <repo-url>

Register a GitHub repo as an ArgoCD application.

Arguments:
  <name>      Application name (used as namespace, must be unique)
  <repo-url>  Full GitHub repository URL (https://...)

Examples:
  uis argocd register hello-world https://github.com/terchris/urb-dev-typescript-hello-world
  uis argocd register my-app https://github.com/myorg/my-k8s-app
```

### When is a GitHub PAT needed?

| Scenario | PAT Required? |
|----------|--------------|
| Public repo | No |
| Private repo | Yes — configured in secrets |

If a PAT is configured in secrets, it is used automatically for authentication. If the repo is private and no PAT is configured, the GitHub API pre-flight check will fail with a clear message.

---

## Playbook Changes Required

The playbook currently receives `github_username` and `repo_name` and constructs the URL internally. With the new design:

### CLI keeps it simple — playbook does the heavy lifting

The CLI only validates basic input and passes two values to the playbook:

```bash
ansible-playbook argocd-register-app.yml \
  -e "app_name=hello-world" \
  -e "repo_url=https://github.com/terchris/urb-dev-typescript-hello-world" \
  -e "github_pat=$github_pat"
```

The **playbook** handles all URL parsing and logic:
- Extract `github_owner` and `repo_name` from `repo_url` (Ansible regex or split filter)
- Use `app_name` for namespace, ArgoCD Application name, and secret naming (instead of `repo_name`)
- Use `repo_url` for the ArgoCD source URL (instead of constructing it)
- Use extracted `github_owner` and `repo_name` for GitHub API pre-flight checks
- Remove the `github_username` requirement — owner comes from the URL

### `remove` command — no changes to parameters

```bash
uis argocd remove <name>
```

The `remove` playbook already only needs `repo_name` — rename the variable to `app_name` for clarity, but behavior is the same.

---

## Error Handling Analysis

### What the playbook checks today

**Pre-flight checks (fail fast, nothing created yet):**

| Check | Result on Failure |
|-------|-------------------|
| `github_username` variable missing | Clear error: variable is mandatory |
| `repo_name` variable missing | Clear error: variable is mandatory |
| Repo doesn't exist on GitHub | Clear error: "Repository not found or not accessible" with suggestions (typo, private repo, token access) |
| `manifests/` directory missing in repo | Clear error: "No manifests/ directory found" with expected repo structure |

**Post-deployment checks (waits with retries, 30 attempts x 10s = 5 min timeout):**

| Check | Result on Failure |
|-------|-------------------|
| ArgoCD Application object created | Timeout: "Timeout waiting for ArgoCD application to be created" |
| Sync starts (leaves Unknown state) | Timeout: "Timeout waiting for ArgoCD application to start syncing" |
| Sync completes (status = Synced) | Timeout: generic sync status message |
| App becomes Healthy | Timeout: generic health status message |
| Pods reach Running state | Timeout: shows list of pod phases |
| No services detected | Warning (does not fail): "NO SERVICES DETECTED. Your application cannot be accessed!" |

**Auto-cleanup on failure (rescue block):**

If anything fails after resource creation starts, the playbook cleans up:
1. Removes the ArgoCD Application
2. Removes the GitHub credentials secret
3. Removes the application namespace
4. Shows "All resources have been cleaned up" message

### Gaps — errors that are NOT diagnosed

| Scenario | What actually happens | What the user sees |
|----------|----------------------|-------------------|
| **Container image doesn't exist / can't pull** | Pod stays in `ImagePullBackOff` | Generic "Timeout waiting for pods to be in Running state" — no mention of the bad image name |
| **Container image tag wrong** | Same as above — `ImagePullBackOff` or `ErrImagePull` | Same generic timeout message |
| **Manifests have invalid YAML** | ArgoCD sync fails | Generic "Timeout waiting for ArgoCD application to be synced" — no parse error shown |
| **Manifests reference resources that don't exist** (e.g., missing CRD) | Sync fails with K8s API errors | Same generic sync timeout |
| **ArgoCD server not running** | Creating the Application resource fails | Falls through to cleanup, but error message doesn't specifically say "ArgoCD is not deployed" |
| **Port conflicts with existing services** | Pod may start but service routing fails | Not detected — app shows as Healthy |
| **Manifests target wrong namespace** | Resources deploy to unexpected namespace | Not detected — playbook only checks the namespace it created |
| **Insufficient cluster resources** (CPU/memory) | Pod stays in `Pending` | Generic timeout waiting for Running state |
| **Private container registry without pull secret** | `ImagePullBackOff` | Generic timeout — no hint about registry auth |

### Recommendations for improvement

1. **ArgoCD not running**: Add a pre-flight check (in CLI or playbook) that ArgoCD server pods are running before attempting registration.

2. **On pod timeout**: Check pod status for `ImagePullBackOff`, `ErrImagePull`, `CrashLoopBackOff`, or `Pending` and show a specific diagnostic message for each:
   - `ImagePullBackOff` → "Container image not found. Check image name and tag in your manifests."
   - `CrashLoopBackOff` → "Container starts but crashes. Check application logs."
   - `Pending` → "Pod cannot be scheduled. Check cluster resources (CPU/memory)."

3. **On sync timeout**: Query the ArgoCD Application's `.status.conditions` or `.status.operationState.message` to show the actual sync error instead of a generic timeout.

---

## Affected Files

| File | Changes needed |
|------|---------------|
| `provision-host/uis/manage/uis-cli.sh` | Rewrite `cmd_argocd_register()` for two-param syntax. Validate name (DNS-safe, not in use) and URL (starts with `https://`). Pass `app_name` and `repo_url` to playbook. Update help text. |
| `ansible/playbooks/argocd-register-app.yml` | Accept `app_name` and `repo_url`. Parse owner/repo from URL. Use `app_name` for namespace/app. Use `repo_url` for ArgoCD source. Add ArgoCD pre-flight check. |
| `ansible/playbooks/argocd-remove-app.yml` | Rename `repo_name` variable to `app_name` for consistency. |

---

## Outcome

All recommendations from this investigation were implemented in [PLAN-argocd-register-redesign](../completed/PLAN-argocd-register-redesign.md):

1. **ArgoCD pre-flight check** — implemented in playbook task 5/5a/5b ✓
2. **Pod timeout diagnostics** — implemented in task 25a (ImagePullBackOff, CrashLoopBackOff, Pending) ✓
3. **Sync timeout diagnostics** — implemented in tasks 16, 18, 21 (queries `operationState.message`) ✓
4. **Two-parameter CLI** — `uis argocd register <name> <repo-url>` with DNS and URL validation ✓
5. **No GitHub username dependency** — owner parsed from URL ✓

### Additional finding during implementation

The investigation did not anticipate the **IngressRoute routing problem**: when `app_name` differs from the repo name, the repo's own `ingress.yaml` routes `<repo-name>.localhost`, not `<app-name>.localhost`. This was discovered during end-to-end testing (Round 4) and fixed by adding a platform-managed IngressRoute (Phase 6 of the plan).

A secondary finding was that **Ansible Jinja2 renders integers as strings** without `jinja2_native=true`, causing Traefik to misinterpret the port as a named port. Fixed using the `from_yaml` filter pattern.
