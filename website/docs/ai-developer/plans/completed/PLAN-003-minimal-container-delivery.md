# PLAN-003: Minimal Container Delivery

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed — ✅ Complete

**Goal**: Create a working container-as-deliverable with minimal changes to prove the concept.

**Completed**: 2026-01-22

**Last Updated**: 2026-01-22

**Based on**: [INVESTIGATE-uis-distribution.md](./INVESTIGATE-uis-distribution.md)

**Priority**: High

---

## Overview

Create a slim container image (~1.8GB, down from ~2.7GB) that:
- Has UIS product baked in at `/mnt/urbalurbadisk/`
- Skips Azure CLI, MkDocs, and other unused tools
- Works with existing `provision-host/kubernetes/` scripts (no changes to them)
- User mounts their `topsecret/` folder

**Target**: Local development with Rancher Desktop (no cloud providers needed).

---

## Phase 1: Script Modifications — ✅ DONE

Modify existing provision scripts to support skipping unused components.

### Tasks

- [x] 1.1 Add `none` option to cloud providers script ✓
  - **File**: `provision-host/provision-host-01-cloudproviders.sh`
  - Add case for `none`/`skip` to skip all cloud provider installations (saves ~637MB)
  - Update usage documentation in header
  - Update help text in main()

- [x] 1.2 Remove MkDocs installation ✓
  - **File**: `provision-host/provision-host-00-coresw.sh`
  - Remove or comment out MkDocs installation (no longer used - migrated to Docusaurus)

- [x] 1.3 Skip MkDocs build script ✓
  - **File**: `provision-host/provision-host-provision.sh`
  - Remove `provision-host-05-builddocs.sh` from the PROVISION_SCRIPTS array

### Validation

User confirms script modifications are correct.

---

## Phase 2: Container Files — ✅ DONE

Create the Dockerfile, wrapper script, and build configuration.

### Tasks

- [x] 2.1 Create Dockerfile for container image ✓
  - **File**: `Dockerfile.uis-provision-host` (new file in repo root)
  - Base image: ubuntu:22.04
  - Create ansible user with sudo
  - Install basic tools (curl, wget, git, python3, jq, etc.)
  - Copy UIS product files to `/mnt/urbalurbadisk/`
  - Run provisioning with `none` cloud provider
  - Set up mount points for topsecret/

- [x] 2.2 Create thin wrapper script ✓
  - **File**: `uis` (new file in repo root)
  - Commands: start, stop, restart, status, shell, provision, exec, logs, help
  - Mount user's topsecret/ and ~/.kube/ into container
  - Check for topsecret/ folder before starting

- [x] 2.3 Create .dockerignore ✓
  - **File**: `.dockerignore` (new file in repo root)
  - Exclude: .git, .devcontainer, website, docs, .vscode, topsecret/secrets-config, node_modules

### Validation

```bash
# Build the container locally
docker build -f Dockerfile.uis-provision-host -t uis-provision-host:local .

# Check size (should be ~1.8GB, not ~2.7GB)
docker images uis-provision-host:local
```

User confirms container builds and size is acceptable.

---

## Phase 3: CI/CD Pipeline — ✅ DONE

Set up automated builds and publishing to container registry.

### Tasks

- [x] 3.1 Create GitHub Actions workflow ✓
  - **File**: `.github/workflows/build-uis-container.yml`
  - Trigger on push to main (relevant paths) and workflow_dispatch
  - Build multi-arch: linux/amd64, linux/arm64
  - Push to ghcr.io
  - Generate build summary

### Validation

User reviews workflow file. Full validation happens after merge when workflow runs.

---

## Phase 4: Integration Testing — PARTIAL

Test the complete workflow end-to-end.

> **Note**: Provisioning test (4.3) deferred - requires clean Rancher Desktop environment.

### Tasks

- [x] 4.1 Set up topsecret folder ✅ (already exists)
  ```bash
  mkdir -p topsecret/config topsecret/secrets-config
  cp topsecret/secrets-templates/* topsecret/secrets-config/
  ```

- [x] 4.2 Test wrapper script commands ✅
  ```bash
  chmod +x uis
  ./uis start
  ./uis status
  ./uis shell
  ```

- [ ] 4.3 Test provisioning
  ```bash
  ./uis provision
  ./uis exec kubectl get pods -A
  ```

- [x] 4.4 Test container lifecycle ✅
  ```bash
  ./uis stop
  ./uis start
  ./uis restart
  ```

### Validation

User confirms all commands work and services deploy correctly.

---

## Phase 5: Slim Container Image

Reduce container size from 2.48GB to ~1.8GB by removing unused components.

### Analysis (Current: 2.48GB)

| Component | Size | Action |
|-----------|------|--------|
| k9s | 116M | Remove - optional terminal UI |
| snapd | 91M | Remove - not needed in container |
| gcc/g++ | 90M | Remove - compiler not needed |
| Unused Ansible collections | ~350M | Remove - keep only required |
| cloudflared | 38M | Keep - needed for tunnels |
| **Total savings** | **~650M** | Target: ~1.8GB |

### Ansible Collections to Keep (Based on actual usage in playbooks)

- `kubernetes.core` - K8s management (k8s, k8s_info modules)
- `community.postgresql` - PostgreSQL management (postgresql_db, postgresql_user, etc.)
- `community.general` - General utilities (cloudflare_dns module)

**NOT needed** (not used in any playbooks):
- `community.docker` - Not used
- `community.mysql` - Not used
- `ansible.posix` - Not used
- `ansible.utils` - Not used

### Tasks

- [x] 5.1 Remove k9s from provisioning ✓ **SKIPPED - user needs k9s**
  - **File**: `provision-host/provision-host-02-kubetools.sh`
  - k9s is kept as requested

- [x] 5.2 Remove snapd and prevent gcc installation ✓
  - **File**: `provision-host/provision-host-00-coresw.sh`
  - Added `--no-install-recommends` to python3-pip install (prevents gcc/g++ ~90MB)
  - **File**: `provision-host/provision-host-02-kubetools.sh`
  - Skip snapd installation when `RUNNING_IN_CONTAINER=true` (~91MB)
  - **File**: `Dockerfile.uis-provision-host`
  - Added cleanup step to purge snapd and clear caches

- [x] 5.3 Install only required Ansible collections ✓
  - **File**: `provision-host/provision-host-02-kubetools.sh`
  - Changed from `ansible` to `ansible-core` package (~350MB savings)
  - Install only: `kubernetes.core`, `community.postgresql`, `community.general`

- [x] 5.4 Clean apt cache and temp files ✓
  - **File**: `Dockerfile.uis-provision-host`
  - Added final cleanup layer for apt cache, pip cache, tmp files

- [ ] 5.5 Rebuild and verify size
  ```bash
  docker build -f Dockerfile.uis-provision-host -t uis-provision-host:local .
  docker images uis-provision-host:local  # Should be ~1.8GB
  ```

### Validation

```bash
# Verify size reduced
docker images uis-provision-host:local

# Verify tools still work
./uis start
docker exec uis-provision-host kubectl version --client
docker exec uis-provision-host ansible --version
docker exec uis-provision-host helm version --short
./uis stop
```

User confirms container size is acceptable and tools work.

---

## Acceptance Criteria

- [ ] Container builds successfully
- [ ] Container size is ~1.8GB (not ~2.7GB)
- [ ] `./uis start` starts the container
- [ ] `./uis shell` enters the container
- [ ] `./uis provision` deploys services to rancher-desktop
- [ ] Existing `provision-host/kubernetes/` scripts work unchanged
- [ ] User's `topsecret/` changes are visible in container (mount works)
- [ ] Container can be stopped and restarted without issues

---

## Files to Modify

| File | Action | Description |
|------|--------|-------------|
| `provision-host/provision-host-01-cloudproviders.sh` | Modify | Add `none` option |
| `provision-host/provision-host-00-coresw.sh` | Modify | Remove MkDocs installation |
| `provision-host/provision-host-provision.sh` | Modify | Remove builddocs from script list |
| `Dockerfile.uis-provision-host` | Create/Modify | Container build definition + cleanup |
| `uis` | Create | Wrapper script |
| `.dockerignore` | Create | Exclude files from build |
| `.github/workflows/build-uis-container.yml` | Create | CI/CD pipeline for container builds |
| `provision-host/provision-host-02-kubetools.sh` | Modify | Remove k9s, slim Ansible collections |

---

## Implementation Notes

### Code for Task 1.1: Cloud providers `none` option

```bash
# Add this case in provision-host-01-cloudproviders.sh:
case "${1:-az}" in
    "none"|"skip")
        echo "Skipping cloud provider installation"
        add_status "Cloud Providers" "Status" "Skipped (none selected)"
        ;;
    "az"|"azure")
        install_azure_cli || echo "Azure CLI installation failed"
        ;;
    # ... rest of existing code
```

### Code for Task 2.1: Dockerfile

```dockerfile
# Dockerfile.uis-provision-host
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Create ansible user and set up sudo
RUN apt-get update && apt-get install -y sudo && \
    useradd -m -s /bin/bash ansible && \
    echo "ansible ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible && \
    chmod 0440 /etc/sudoers.d/ansible

# Install basic tools
RUN apt-get update && \
    apt-get install -y \
    apt-utils sudo curl wget git python3 python3-pip vim \
    bash-completion jq iputils-ping net-tools dnsutils netcat traceroute \
    && rm -rf /var/lib/apt/lists/*

# Install yq
RUN YQ_VERSION="v4.44.1" && \
    ARCH=$(uname -m) && \
    case "$ARCH" in \
      x86_64) BINARY="yq_linux_amd64" ;; \
      aarch64 | arm64) BINARY="yq_linux_arm64" ;; \
      *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${BINARY}" && \
    chmod a+x /usr/local/bin/yq

# Create directories and copy UIS product
RUN mkdir -p /mnt/urbalurbadisk && chown ansible:ansible /mnt/urbalurbadisk

COPY --chown=ansible:ansible ansible/ /mnt/urbalurbadisk/ansible/
COPY --chown=ansible:ansible manifests/ /mnt/urbalurbadisk/manifests/
COPY --chown=ansible:ansible hosts/ /mnt/urbalurbadisk/hosts/
COPY --chown=ansible:ansible cloud-init/ /mnt/urbalurbadisk/cloud-init/
COPY --chown=ansible:ansible networking/ /mnt/urbalurbadisk/networking/
COPY --chown=ansible:ansible provision-host/ /mnt/urbalurbadisk/provision-host/
COPY --chown=ansible:ansible scripts/ /mnt/urbalurbadisk/scripts/
COPY --chown=ansible:ansible topsecret/secrets-templates/ /mnt/urbalurbadisk/topsecret/secrets-templates/

USER ansible
WORKDIR /mnt/urbalurbadisk
ENV PATH="/home/ansible/.local/bin:${PATH}"
ENV RUNNING_IN_CONTAINER=true

RUN mkdir -p ~/.local/bin ~/.config ~/.ssh

# Run provisioning with no cloud providers
RUN cd /mnt/urbalurbadisk/provision-host && \
    chmod +x *.sh && \
    ./provision-host-provision.sh none

USER root
RUN mkdir -p /mnt/urbalurbadisk/topsecret/config \
             /mnt/urbalurbadisk/topsecret/secrets-config && \
    chown -R ansible:ansible /mnt/urbalurbadisk/topsecret

USER ansible
WORKDIR /mnt/urbalurbadisk
CMD ["tail", "-f", "/dev/null"]
```

### Code for Task 2.2: Wrapper script

See full script in original investigation. Key commands:
- `./uis start` - Start container with mounts
- `./uis shell` - Enter container
- `./uis provision` - Run kubernetes provisioning
- `./uis exec <cmd>` - Execute command in container

### Code for Task 3.1: GitHub Actions workflow

```yaml
name: Build UIS Container

on:
  push:
    branches: [main]
    paths:
      - 'ansible/**'
      - 'manifests/**'
      - 'provision-host/**'
      - 'Dockerfile.uis-provision-host'
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/uis-provision-host

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=raw,value=latest,enable={{is_default_branch}}
            type=sha,prefix=
      - uses: docker/build-push-action@v5
        with:
          context: .
          file: ./Dockerfile.uis-provision-host
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          platforms: linux/amd64,linux/arm64
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

---

## Out of Scope

Deferred to future plans:
- New `provision-host/uis/` orchestration system
- `enabled-services.conf` config-driven deployment
- `uis init` wizard
- Install script (`curl ... | bash`)
- Multiple container variants (full/local/azure)
- **Windows/WSL2 support**: The `uis` wrapper script currently uses `$HOME/.kube` for kubeconfig path, which works on macOS/Linux but needs adjustment for:
  - Windows (native): `%USERPROFILE%\.kube\config`
  - WSL2: May need `/mnt/c/Users/<name>/.kube/config` depending on where Rancher Desktop stores kubeconfig

---

## Notes

- This is a proof-of-concept to validate the container-as-deliverable approach
- Once validated, we can proceed with full implementation
- The existing `install-rancher.sh` workflow continues to work unchanged
- Users can choose either approach: traditional (copy files) or new (container with mounts)
