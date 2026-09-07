# INVESTIGATE: Auto-Generated Documentation from Script Metadata

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-02-27
**Status:** Completed
**Related**: DevContainer Toolbox (dct) at `/Users/terje.christensen/learn/projects-2025/devcontainer-toolbox`

## Problem Statement

UIS inherited the script metadata pattern from DevContainer Toolbox (dct), but only uses it for the CLI menu (`./uis list`, `./uis deploy`). In dct, the same metadata also auto-generates a full Docusaurus documentation website — tool pages, category indexes, package tables with links, and a tools overview. UIS has this potential but doesn't use it.

The UIS documentation at `website/docs/services/` is manually written and can drift from what the scripts actually define.

---

## How dct Does It

### Script Metadata → Everything

In dct, a single install script like `install-dev-bash.sh` contains all metadata:

```bash
SCRIPT_ID="dev-bash"
SCRIPT_VER="0.0.1"
SCRIPT_NAME="Bash Development Tools"
SCRIPT_DESCRIPTION="Adds shellcheck, shfmt, bash-language-server, and VS Code extensions"
SCRIPT_CATEGORY="LANGUAGE_DEV"
SCRIPT_CHECK_COMMAND="command -v shellcheck >/dev/null 2>&1"
SCRIPT_TAGS="bash shell scripting shellcheck shfmt linting formatting"
SCRIPT_ABSTRACT="Bash scripting environment with shellcheck linting..."
SCRIPT_LOGO="dev-bash-logo.webp"
SCRIPT_WEBSITE="https://www.gnu.org/software/bash/"
SCRIPT_SUMMARY="Complete Bash development setup..."
SCRIPT_RELATED="dev-python dev-typescript"
```

This metadata drives:
1. **Menu** (`dev-setup`) — interactive dialog-based tool installer
2. **Documentation** (`dev-docs`) — auto-generated Docusaurus pages
3. **JSON data** — `tools.json` and `categories.json` for React components
4. **README** — auto-updated tools summary between markers

### Documentation Generator: `dev-docs.sh`

The `dev-docs.sh` script:
1. Scans all `install-*.sh` scripts in `.devcontainer/additions/`
2. Extracts metadata using `component-scanner.sh` library
3. Extracts package arrays (`PACKAGES_SYSTEM`, `PACKAGES_NODE`, `EXTENSIONS`, etc.)
4. Generates per-tool markdown pages with:
   - Description, abstract, summary
   - Package tables with links to registries (npm, pypi, crates.io, etc.)
   - VS Code extension links to marketplace
   - Related tools cross-links
5. Generates category index pages
6. Generates `tools.json` and `categories.json` for React components
7. Updates README.md between `<!-- TOOLS_START -->` / `<!-- TOOLS_END -->` markers

Output: `website/docs/tools/index.mdx` and `website/docs/tools/<category>/<tool>.md`

### Categories System: `categories.sh`

Centralized pipe-delimited table defining all valid categories:

```
ORDER|ID|NAME|ABSTRACT|SUMMARY|TAGS|LOGO
```

Helper functions: `get_category_name()`, `get_category_abstract()`, `get_category_order()`, `is_valid_category()`, etc.

### CI/CD: `deploy-docs.yml`

GitHub Actions workflow triggered on push to main when scripts or docs change:
1. Process logo assets (`dev-logos.sh` — SVG → WebP conversion)
2. Generate documentation (`dev-docs.sh`)
3. Build Docusaurus site
4. Deploy to GitHub Pages → `dct.sovereignsky.no`

### Version System: Two-Tier

- **Container version** (`version.txt`) — tracks Docker image, needs rebuild
- **Scripts version** (`scripts-version.txt`) — tracks scripts only, updated via `dev-sync` without rebuild
- `dev-sync` downloads latest scripts zip from GitHub releases, backs up old scripts, swaps atomically

### Command Framework: `cmd-framework.sh`

For scripts with subcommands, a pipe-delimited array:
```bash
SCRIPT_COMMANDS=(
    "Category|--flag|Description|function_name|requires_arg|param_prompt"
    "Control|--start|Start nginx|service_start|false|"
    "Status|--logs|Show logs|service_logs|false|"
)
```

Framework provides: `cmd_framework_parse_args()`, `cmd_framework_generate_help()`, `cmd_framework_validate_commands()`.

---

## What UIS Has Today

### Script Metadata (Partial)

UIS service scripts (`provision-host/uis/services/*/service-*.sh`) use:

```bash
SCRIPT_ID="tailscale-tunnel"
SCRIPT_NAME="Tailscale Tunnel"
SCRIPT_DESCRIPTION="Secure mesh VPN tunnel"
SCRIPT_CATEGORY="NETWORK"
SCRIPT_PLAYBOOK="802-deploy-network-tailscale-tunnel.yml"
SCRIPT_REMOVE_PLAYBOOK="801-remove-network-tailscale-tunnel.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n tailscale -l app=operator"
SCRIPT_REQUIRES="nginx"
SCRIPT_PRIORITY="100"
```

### What UIS Uses Metadata For

Only the CLI:
- `./uis list` — reads SCRIPT_NAME, SCRIPT_DESCRIPTION, SCRIPT_CATEGORY
- `./uis deploy <service>` — reads SCRIPT_PLAYBOOK
- `./uis undeploy <service>` — reads SCRIPT_REMOVE_PLAYBOOK
- `./uis test-all` — reads SCRIPT_REQUIRES, SCRIPT_PRIORITY

### What UIS Does NOT Use Metadata For

- Documentation generation (docs are manually written)
- JSON data for website components
- README auto-update
- Package/version tracking per service

### Missing dct Metadata Fields in UIS

| dct Field | UIS Equivalent | Status |
|-----------|---------------|--------|
| `SCRIPT_VER` | — | Missing |
| `SCRIPT_TAGS` | — | Missing |
| `SCRIPT_ABSTRACT` | — | Missing |
| `SCRIPT_LOGO` | — | Missing |
| `SCRIPT_WEBSITE` | — | Missing |
| `SCRIPT_SUMMARY` | — | Missing |
| `SCRIPT_RELATED` | — | Missing |
| `SCRIPT_DOCS` | exists in some scripts | Partial |

### UIS-Specific Fields Not in dct

| UIS Field | Purpose |
|-----------|---------|
| `SCRIPT_PLAYBOOK` | Ansible playbook for deploy |
| `SCRIPT_REMOVE_PLAYBOOK` | Ansible playbook for undeploy |
| `SCRIPT_REQUIRES` | Service dependencies |
| `SCRIPT_MANIFEST` | Kubernetes manifest paths |

---

## Comparison: dct vs UIS

| Aspect | dct | UIS |
|--------|-----|-----|
| Script types | install, service, config, cmd | service only |
| Install mechanism | Package managers (apt, npm, pip) | Ansible playbooks + Helm |
| Menu | Interactive dialog (`dev-setup`) | CLI (`./uis list`) |
| Service management | Supervisord | Kubernetes |
| Documentation | Auto-generated from metadata | Manual markdown |
| Version tracking | Two-tier (container + scripts) | None per service |
| CI/CD docs | Auto-regenerate on push | Manual |
| Categories | Centralized `categories.sh` with helpers | Inline in `uis-cli.sh` |
| Config location | `.devcontainer.extend/` | `.uis.extend/` |
| Secrets location | — | `.uis.secrets/` |

---

## Questions to Investigate

### Q1: What should auto-generated UIS docs look like?

The dct generates per-tool pages like `dct.sovereignsky.no/docs/tools/development-tools/csharp`. For UIS, this could be per-service pages showing:
- Service description, category, dependencies
- Helm chart name and version (ties into INVESTIGATE-system-version-pinning)
- Deploy/undeploy commands
- Configuration options
- Related services

### Q2: Should UIS adopt the dct documentation generator or write its own?

Options:
- **Port `dev-docs.sh`** — adapt the dct generator for UIS service scripts
- **Write a UIS-specific generator** — simpler, tailored to Helm/K8s context
- **Shared library** — extract common doc generation into a reusable tool

### Q3: What metadata fields should UIS add?

Candidates from dct:
- `SCRIPT_TAGS` — enables search
- `SCRIPT_ABSTRACT` — short card text
- `SCRIPT_LOGO` — service logos for the website
- `SCRIPT_WEBSITE` — link to upstream project
- `SCRIPT_SUMMARY` — detailed description
- `SCRIPT_RELATED` — cross-links between services

UIS-specific additions:
- `SCRIPT_HELM_CHART` — chart name (e.g., `bitnami/postgresql`)
- `SCRIPT_HELM_VERSION` — pinned chart version (ties into version pinning)
- `SCRIPT_IMAGE` — container image used
- `SCRIPT_IMAGE_VERSION` — pinned image version
- `SCRIPT_HELM_REPO` — Helm repository URL

### Q4: Should UIS centralize categories like dct does?

dct has `categories.sh` with a pipe-delimited table and helper functions. UIS categories are currently scattered. Centralizing would enable:
- Category pages in docs
- Consistent ordering
- Validation

### Q5: Should version info live in script metadata?

If each service script has `SCRIPT_HELM_VERSION` and `SCRIPT_IMAGE_VERSION`, then:
- Version pinning (INVESTIGATE-system-version-pinning) becomes part of the metadata
- Documentation generator can show versions on service pages
- A version-check script could compare pinned versions against latest available

### Q6: CI/CD pipeline for docs?

UIS already has a Docusaurus site. Should `deploy-docs.yml` be extended to auto-regenerate service docs on push, like dct does?

---

## Potential Value

### For UIS Users
- Always-current service documentation generated from the same scripts that deploy services
- Service pages showing exactly what version is deployed, what it depends on, how to configure it
- Searchable service catalog with tags

### For Developers
- Adding a new service = adding one script file. Menu, docs, and version tracking update automatically
- No more manual doc maintenance for service pages
- Version pinning metadata co-located with the service definition

### Connection to Other Investigations
- **INVESTIGATE-system-version-pinning**: If chart/image versions become script metadata, version pinning and documentation are solved together
- **STATUS-service-migration**: Service pages could replace the manual tracking table

---

## Next Steps

1. Decide which metadata fields to add to UIS service scripts
2. Decide on documentation generator approach (port dct vs custom)
3. Create a PLAN for implementation
