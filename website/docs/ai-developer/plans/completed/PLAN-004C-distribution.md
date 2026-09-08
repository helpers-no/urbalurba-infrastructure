# PLAN-004C: Distribution & Cross-Platform Support

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Create curl-installable script and cross-platform wrapper scripts for UIS distribution.

**Last Updated**: 2026-01-22

**Part of**: [PLAN-004-uis-orchestration-system.md](./PLAN-004-uis-orchestration-system.md) (Epic)

**Prerequisites**: [PLAN-004A-core-cli.md](./PLAN-004A-core-cli.md) - Core CLI system

**Priority**: Medium

**Delivers**:
- `curl -fsSL https://uis.sovereignsky.no/install.sh | bash` - One-line install
- `uis.ps1` - PowerShell wrapper for Windows
- Cross-platform support (macOS, Linux, Windows, WSL2)

---

## Overview

This plan enables easy distribution of UIS:
1. **Install script** - Download and setup with one command
2. **Cross-platform wrappers** - Native scripts for each platform
3. **Platform detection** - Automatic selection of right wrapper

**Architecture Note**: See [PLAN-004A Architecture Section](./PLAN-004A-core-cli.md#architecture-container-vs-host-boundary) for the definitive guide on what runs on the host vs container. This plan implements the **HOST** side of that architecture.

**Target Experience**:
```bash
# Any platform
curl -fsSL https://uis.sovereignsky.no/install.sh | bash
./uis start && ./uis deploy
# Services running!
```

---

## Phase 7: Install Script — COMPLETE

Create curl-installable script for new users.

### Tasks

- [x] 7.1 Create `install.sh` for website hosting ✅
  - **File**: `website/static/install.sh`
  - Checks prerequisites:
    - Docker is installed and running
    - Sufficient disk space (~2GB)
  - Pulls container image from ghcr.io
  - Creates `./uis` wrapper script in current directory
  - Does NOT create config folders (first-run does that)
  - Prints next steps

  ```bash
  #!/bin/bash
  set -e

  echo "Installing UIS (Urbalurba Infrastructure Stack)..."

  # Check Docker
  if ! command -v docker &> /dev/null; then
      echo "Error: Docker is not installed"
      echo "Please install Docker Desktop or Rancher Desktop first"
      exit 1
  fi

  # Check Docker running
  if ! docker info &> /dev/null; then
      echo "Error: Docker is not running"
      echo "Please start Docker Desktop or Rancher Desktop"
      exit 1
  fi

  # Pull container image
  echo "Pulling UIS container image..."
  docker pull ghcr.io/terchris/uis-provision-host:latest

  # Download wrapper script
  echo "Creating ./uis wrapper..."
  curl -fsSL https://uis.sovereignsky.no/uis -o ./uis
  chmod +x ./uis

  echo ""
  echo "✓ UIS installed successfully!"
  echo ""
  echo "Next steps:"
  echo "  ./uis start        # Start the UIS container"
  echo "  ./uis deploy       # Deploy default services"
  echo "  ./uis setup        # Interactive configuration"
  echo ""
  echo "Documentation: https://uis.sovereignsky.no"
  ```

- [x] 7.2 Create wrapper script for download ✅
  - **File**: `website/static/uis`
  - The bash wrapper that gets downloaded
  - Standalone version with full platform support

- [x] 7.3 Add install URL to website ✅
  - URL: `https://uis.sovereignsky.no/install.sh`
  - Usage: `curl -fsSL https://uis.sovereignsky.no/install.sh | bash`
  - (Homepage update deferred to website deployment)

- [x] 7.4 Create version check endpoint ✅
  - **File**: `website/static/version.txt`
  - Contains current version number (0.1.0)
  - Used by `uis version --check` to see if update available

- [ ] 7.5 Document installation prerequisites (deferred)
  - Update website docs with:
    - Minimum Docker version
    - Rancher Desktop setup instructions
    - Disk space requirements
    - Network requirements (for pulling images)

### Validation

```bash
# In a fresh directory
curl -fsSL https://uis.sovereignsky.no/install.sh | bash
# Output:
#   Installing UIS (Urbalurba Infrastructure Stack)...
#   Pulling UIS container image...
#   Creating ./uis wrapper...
#   ✓ UIS installed successfully!

./uis start
# Container starts, first-run creates folders

./uis deploy
# Deploys nginx (default service)
```

---

## Phase 8: Cross-Platform Wrapper Scripts — COMPLETE

Create platform-specific wrapper scripts that call into the container.

### Architecture

```
User's machine                          uis-provision-host container
┌─────────────────┐                    ┌─────────────────────────────┐
│                 │                    │                             │
│  uis (bash)     │ ──── docker ────▶  │  provision-host/uis/        │
│  uis.ps1        │      exec          │  └── manage/uis-cli.sh      │
│                 │                    │                             │
└─────────────────┘                    └─────────────────────────────┘
```

The wrapper scripts are thin - they just:
1. Ensure uis-provision-host container is running
2. Create `.uis.extend/` and `.uis.secrets/` on first run
3. Mount config folders into container
4. Pass commands to `uis-cli.sh` inside the container

### Tasks

- [x] 8.1 Create `uis` bash wrapper (macOS/Linux) ✅
  - **File**: `website/static/uis`
  - Handles: macOS, Linux, WSL2, Git Bash on Windows
  - Platform detection for kubeconfig path
  - First-run: Creates `.uis.extend/`, `.uis.secrets/`
  - Commands routed to: `docker exec uis-provision-host /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh`

  ```bash
  #!/bin/bash
  CONTAINER_NAME="uis-provision-host"
  IMAGE_NAME="ghcr.io/terchris/uis-provision-host:latest"

  # Detect platform and set kubeconfig path
  detect_kubeconfig() {
      if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
          # Git Bash on Windows
          echo "/mnt/c/Users/$USER/.kube/config"
      else
          # macOS, Linux, WSL2
          echo "$HOME/.kube/config"
      fi
  }

  # First-run initialization
  first_run() {
      if [[ ! -d ".uis.extend" ]]; then
          echo "First run - creating configuration folders..."
          mkdir -p .uis.extend .uis.secrets
          # Copy defaults from container...
      fi
  }

  # Start container with mounts
  start_container() {
      docker run -d --name $CONTAINER_NAME \
          -v "$(pwd)/.uis.extend:/mnt/urbalurbadisk/.uis.extend" \
          -v "$(pwd)/.uis.secrets:/mnt/urbalurbadisk/.uis.secrets" \
          -v "$(detect_kubeconfig):/home/ansible/.kube/config:ro" \
          $IMAGE_NAME tail -f /dev/null
  }

  # Route commands
  case "$1" in
      start) first_run && start_container ;;
      stop) docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME ;;
      shell) docker exec -it $CONTAINER_NAME bash ;;
      *) docker exec $CONTAINER_NAME /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh "$@" ;;
  esac
  ```

- [x] 8.2 Create `uis.ps1` PowerShell wrapper (Windows) ✅
  - **File**: `website/static/uis.ps1`
  - Handles: Windows PowerShell, PowerShell Core
  - Kubeconfig: `$env:USERPROFILE\.kube\config`
  - First-run: Creates `.uis.extend\`, `.uis.secrets\`
  - Same command routing as bash version

  ```powershell
  # uis.ps1 - UIS wrapper for Windows PowerShell
  $ContainerName = "uis-provision-host"
  $ImageName = "ghcr.io/terchris/uis-provision-host:latest"

  function Get-KubeConfigPath {
      return "$env:USERPROFILE\.kube\config"
  }

  function Initialize-FirstRun {
      if (-not (Test-Path ".uis.extend")) {
          Write-Host "First run - creating configuration folders..."
          New-Item -ItemType Directory -Path ".uis.extend" -Force | Out-Null
          New-Item -ItemType Directory -Path ".uis.secrets" -Force | Out-Null
          # Copy defaults from container...
      }
  }

  function Start-UISContainer {
      Initialize-FirstRun
      $kubeconfig = Get-KubeConfigPath
      docker run -d --name $ContainerName `
          -v "${PWD}\.uis.extend:/mnt/urbalurbadisk/.uis.extend" `
          -v "${PWD}\.uis.secrets:/mnt/urbalurbadisk/.uis.secrets" `
          -v "${kubeconfig}:/home/ansible/.kube/config:ro" `
          $ImageName tail -f /dev/null
  }

  # Route commands
  switch ($args[0]) {
      "start" { Start-UISContainer }
      "stop" { docker stop $ContainerName; docker rm $ContainerName }
      "shell" { docker exec -it $ContainerName bash }
      default { docker exec $ContainerName /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh @args }
  }
  ```

- [x] 8.3 Create `uis.cmd` batch wrapper (Windows fallback) ✅
  - **File**: `website/static/uis.cmd`
  - For users who prefer Command Prompt
  - Calls PowerShell script internally

- [x] 8.4 Update install script with platform detection ✅
  - **File**: `website/static/install.sh`
  - Detect platform and download appropriate wrapper
  - Handle WSL2 detection

  ```bash
  # Detect platform
  detect_platform() {
      case "$(uname -s)" in
          Linux*)
              if grep -q Microsoft /proc/version 2>/dev/null; then
                  echo "wsl2"
              else
                  echo "linux"
              fi
              ;;
          Darwin*) echo "macos" ;;
          MINGW*|CYGWIN*) echo "windows-gitbash" ;;
          *) echo "unknown" ;;
      esac
  }
  ```

- [x] 8.5 Create PowerShell install script ✅
  - **File**: `website/static/install.ps1`
  - For native Windows installation
  - Same flow as bash version

  ```powershell
  # install.ps1 - UIS installer for Windows
  Write-Host "Installing UIS (Urbalurba Infrastructure Stack)..."

  # Check Docker
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      Write-Error "Docker is not installed. Please install Docker Desktop or Rancher Desktop."
      exit 1
  }

  # Pull image
  Write-Host "Pulling UIS container image..."
  docker pull ghcr.io/terchris/uis-provision-host:latest

  # Download wrapper scripts
  Write-Host "Creating wrapper scripts..."
  Invoke-WebRequest -Uri "https://uis.sovereignsky.no/uis.ps1" -OutFile ".\uis.ps1"
  Invoke-WebRequest -Uri "https://uis.sovereignsky.no/uis.cmd" -OutFile ".\uis.cmd"

  Write-Host ""
  Write-Host "UIS installed successfully!" -ForegroundColor Green
  Write-Host ""
  Write-Host "Next steps:"
  Write-Host "  .\uis.ps1 start    # Start the UIS container"
  Write-Host "  .\uis.ps1 deploy   # Deploy default services"
  ```

- [x] 8.6 Add wrapper scripts to website static files ✅
  - `website/static/uis` - Bash wrapper
  - `website/static/uis.ps1` - PowerShell wrapper
  - `website/static/uis.cmd` - CMD wrapper
  - `website/static/install.sh` - Bash installer
  - `website/static/install.ps1` - PowerShell installer
  - `website/static/version.txt` - Version file (0.1.0)

### Wrapper Script Responsibilities

See [PLAN-004A Architecture Section](./PLAN-004A-core-cli.md#architecture-container-vs-host-boundary) for detailed architecture.

| Responsibility | Where | Notes |
|----------------|-------|-------|
| Container lifecycle (start/stop) | Wrapper (host) | `./uis start`, `./uis stop` |
| First-run folder creation | Wrapper (host) | Creates `.uis.extend/`, `.uis.secrets/` on first run |
| Mount volumes into container | Wrapper (host) | `-v` flags in docker run |
| Copy default templates | Container (`first-run.sh`) | Populates empty mounted folders |
| Service scanning, deployment | Container (`uis-cli.sh`) | All CLI commands except start/stop/shell |
| Kubernetes operations | Container (`kubectl`) | Via mounted kubeconfig |
| Ansible playbooks | Container (`ansible-playbook`) | Via mounted configs |

### Kubeconfig Paths by Platform

| Platform | Kubeconfig Location | Notes |
|----------|---------------------|-------|
| macOS | `~/.kube/config` | Rancher Desktop writes here |
| Linux | `~/.kube/config` | Standard location |
| WSL2 | `~/.kube/config` | Rancher Desktop integration |
| Windows | `%USERPROFILE%\.kube\config` | Rancher Desktop writes here |
| Git Bash | `/c/Users/<name>/.kube/config` | Windows path in Unix format |

### Validation

```bash
# macOS/Linux
./uis version
./uis list

# Windows PowerShell
.\uis.ps1 version
.\uis.ps1 list

# Windows CMD
uis version
uis list
```

---

## Acceptance Criteria

- [ ] `curl -fsSL https://uis.sovereignsky.no/install.sh | bash` works on macOS
- [ ] `curl -fsSL https://uis.sovereignsky.no/install.sh | bash` works on Linux
- [ ] `curl -fsSL https://uis.sovereignsky.no/install.sh | bash` works on WSL2
- [ ] PowerShell install script works on Windows
- [ ] `./uis` wrapper works on macOS
- [ ] `./uis` wrapper works on Linux
- [ ] `./uis` wrapper works on WSL2
- [ ] `.\uis.ps1` wrapper works on Windows PowerShell
- [ ] `uis.cmd` wrapper works on Windows CMD
- [ ] First-run creates config folders on all platforms
- [ ] Kubeconfig is correctly mounted on all platforms
- [ ] Container can access Rancher Desktop cluster from all platforms

---

## Files to Create

| File | Description |
|------|-------------|
| **Install Scripts** | |
| `website/static/install.sh` | Curl-installable bash script |
| `website/static/install.ps1` | PowerShell install script |
| **Wrapper Scripts** | |
| `website/static/uis` | Bash wrapper for download |
| `website/static/uis.ps1` | PowerShell wrapper |
| `website/static/uis.cmd` | CMD wrapper |
| **Other** | |
| `website/static/version.txt` | Current version for update check |

## Files to Modify

| File | Change |
|------|--------|
| `uis` (repo root) | Update with full platform support |

---

## Gaps Identified

1. **Docker vs Rancher Desktop** - Install script should detect which is installed and give appropriate instructions

2. **Permissions on Windows** - PowerShell execution policy may block scripts. Need to document or handle.

3. **Path separators** - Windows uses `\`, Unix uses `/`. Need careful handling in wrapper scripts.

4. **Container image updates** - How does user update to new container version? Need `uis update` command.

5. **Offline installation** - What if user can't reach ghcr.io? Need offline/airgap installation option.

6. **Proxy support** - Corporate environments may need proxy configuration for Docker pulls.

7. **WSL2 Docker integration** - WSL2 can use Windows Docker Desktop. Need to detect and handle.

8. **Git Bash limitations** - Some commands may not work well in Git Bash. Need to document.

9. **Rancher Desktop vs Docker Desktop kubeconfig** - They may write to different locations. Need to detect.

10. **Uninstall script** - How to cleanly remove UIS? Need `uninstall.sh` / `uninstall.ps1`.

---

## Next Plan

After completing this plan, proceed to:
- [PLAN-004D-website-testing.md](./PLAN-004D-website-testing.md) - Website JSON generation and testing framework
