# Urbalurba Infrastructure Documentation

**Purpose**: Master documentation index and entry point for Urbalurba Infrastructure
**Target Audience**: All users, developers, and administrators

## Overview

Welcome to the complete documentation for **Urbalurba Infrastructure** — a zero-friction developer platform that provides a complete datacenter environment on your laptop. This documentation covers everything from installation to advanced configuration and troubleshooting.

## Quick Start

**New to Urbalurba?** Start here:

1. **[Getting Started](../getting-started/overview.md)** — 5-minute first test with your browser
2. **[Installation Guide](../getting-started/installation.md)** — Get up and running in 2 simple steps
3. **[System Architecture](../getting-started/architecture.md)** — Understand how everything fits together
4. **[Services Overview](../getting-started/services.md)** — See all available services vs Azure equivalents

## Documentation Categories

### Getting Started

*Essential guides for new users and system administrators*

| Document | Purpose |
|----------|---------|
| [Getting Started](../getting-started/overview.md) | 5-minute first test guide with browser access |
| [Installation Guide](../getting-started/installation.md) | Simple 2-step installation guide |
| [System Architecture](../getting-started/architecture.md) | Two-tier architecture overview with diagrams |
| [Infrastructure Overview](../getting-started/infrastructure.md) | Infrastructure components and relationships |
| [Services Overview](../getting-started/services.md) | Complete services comparison with Azure equivalents |

### Services — Observability

*Metrics, logs, and distributed tracing*

| Document | Purpose |
|----------|---------|
| [Observability Overview](../services/observability/index.md) | Stack overview and architecture |
| [Prometheus](../services/observability/prometheus.md) | Metrics collection and alerting |
| [Grafana](../services/observability/grafana.md) | Visualization and dashboards |
| [Loki](../services/observability/loki.md) | Log aggregation |
| [Tempo](../services/observability/tempo.md) | Distributed tracing |
| [OpenTelemetry Collector](../services/observability/otel-collector.md) | Telemetry pipeline |
| [OTLP Collector](../services/observability/otel.md) | OTLP ingestion configuration |
| [sovdev-logger](../services/observability/sovdev-logger.md) | Multi-language OTLP integration library |

### Services — AI & ML

*AI services, LLM integration, and model management*

| Document | Purpose |
|----------|---------|
| [AI & ML Overview](../services/ai/index.md) | AI platform overview |
| [Open WebUI](../services/ai/openwebui.md) | ChatGPT-like interface |
| [LiteLLM](../services/ai/litellm.md) | LLM proxy configuration |
| [LiteLLM Client Keys](../services/ai/litellm-client-keys.md) | API key setup for Claude Code integration |
| [OpenWebUI Model Access](../services/ai/openwebui-model-access.md) | Model access configuration |
| [Environment Management](../services/ai/environment-management.md) | AI environment and model management |

### Services — Analytics

*Data science, notebooks, and distributed computing*

| Document | Purpose |
|----------|---------|
| [Analytics Overview](../services/analytics/index.md) | Analytics platform overview |
| [Apache Spark](../services/analytics/spark.md) | Distributed computing |
| [JupyterHub](../services/analytics/jupyterhub.md) | Collaborative notebooks |
| [Unity Catalog](../services/analytics/unity-catalog.md) | Data governance |

### Services — Identity

*SSO, authentication, and access control*

| Document | Purpose |
|----------|---------|
| [Identity Overview](../services/identity/index.md) | Identity and access management overview |
| [Authentik](../services/identity/authentik.md) | Authentik SSO service |
| [Auth10 Blueprints](../services/identity/auth10.md) | Dynamic blueprint creation and management |
| [Blueprints Syntax](../services/identity/blueprints-syntax.md) | Authentik blueprint configuration reference |
| [Developer Guide](../services/identity/developer-guide.md) | Auth10 developer guide |
| [Technical Implementation](../services/identity/technical-implementation.md) | Authentik technical implementation details |
| [Test Users](../services/identity/test-users.md) | Test user configuration |

### Services — Databases

*Data storage and caching services*

| Document | Purpose |
|----------|---------|
| [Databases Overview](../services/databases/index.md) | Database services overview |
| [PostgreSQL](../services/databases/postgresql.md) | Primary relational database with AI/ML extensions |
| [MySQL](../services/databases/mysql.md) | Alternative SQL database |
| [MongoDB](../services/databases/mongodb.md) | NoSQL document database |
| [Redis](../services/databases/redis.md) | In-memory cache and message broker |
| [Elasticsearch](../services/databases/elasticsearch.md) | Search and analytics engine |
| [Qdrant](../services/databases/qdrant.md) | Vector database |

### Services — Storage

*Platform storage infrastructure*

| Document | Purpose |
|----------|---------|
| [Storage Overview](../services/storage/index.md) | Storage services overview |
| [MinIO](../services/storage/minio.md) | S3-compatible object storage |

### Services — Management

*Admin tools, GitOps, and test services*

| Document | Purpose |
|----------|---------|
| [Management Overview](../services/management/index.md) | Management tools overview |
| [ArgoCD](../services/management/argocd.md) | GitOps continuous deployment |
| [pgAdmin](../services/management/pgadmin.md) | PostgreSQL administration UI |
| [RedisInsight](../services/management/redisinsight.md) | Redis administration UI |
| [Nginx](../services/management/nginx.md) | Web server |
| [Whoami](../services/management/whoami.md) | Test/debug service |
| [Dev Templates](../developing/dev-templates.md) | Development templates and project setup |

### Services — Integration

*Messaging and API gateways*

| Document | Purpose |
|----------|---------|
| [Integration Overview](../services/integration/index.md) | Integration services overview |
| [RabbitMQ](../services/integration/rabbitmq.md) | Message broker |
| [Gravitee](../services/integration/gravitee.md) | API management platform |
| [Temporal](../services/integration/temporal.md) | Durable workflow orchestration engine |

### Services — Networking

*VPN tunnels and network access services*

| Document | Purpose |
|----------|---------|
| [Networking Services Overview](../services/networking/index.md) | Network services |
| [Cloudflare tunnel](../networking/cloudflare.md) | Cloudflare tunnel (in-cluster `cloudflared`, `uis network ... cloudflare`) |
| [Tailscale Tunnel](../services/networking/tailscale-tunnel.md) | Tailscale tunnel service |

### Networking

*Network architecture, ingress, and external connectivity setup guides*

| Document | Purpose |
|----------|---------|
| [Networking Overview](../networking/index.md) | Dual-tunnel internet access architecture |
| [Cloudflare Setup](../networking/cloudflare-setup.md) | Cloudflare tunnel configuration guide |
| [Tailscale Setup](../networking/tailscale-setup.md) | Tailscale tunnel configuration guide |
| [Tailscale Network Isolation](../networking/tailscale-network-isolation.md) | Tailscale funnel security setup |

### Hosts & Platforms

*Multi-environment deployment strategies and cloud platform integration*

| Document | Purpose |
|----------|---------|
| [Hosts Overview](../platforms/index.md) | Host types and deployment strategies |
| [Rancher Kubernetes](../platforms/rancher-kubernetes.md) | Default local development environment |
| [Azure AKS](../platforms/azure-aks.md) | Production Azure Kubernetes Service |
| [Azure MicroK8s](../platforms/azure-microk8s.md) | Azure VM with MicroK8s |
| [Multipass MicroK8s](../platforms/multipass-microk8s.md) | Legacy Multipass deployment (superseded by Rancher) |
| [Raspberry Pi MicroK8s](../platforms/raspberry-microk8s.md) | Edge computing on Raspberry Pi |
| [Cloud-Init Guide](../platforms/cloud-init/index.md) | Cloud-init automation for Ubuntu-based hosts |
| [Cloud-Init Secrets](../platforms/cloud-init/secrets.md) | SSH key setup for cloud-init and Ansible |

### Provision Host

*Central management container documentation*

| Document | Purpose |
|----------|---------|
| [Provision Host Overview](../advanced/provision-host/index.md) | Central management container guide |
| [Rancher Desktop](../advanced/provision-host/rancher.md) | Rancher Desktop configuration |

### Reference

*Configuration, troubleshooting, and operational reference*

| Document | Purpose |
|----------|---------|
| [UIS CLI Reference](./uis-cli-reference.md) | Complete UIS command-line reference |
| [Tools](./tools.md) | Built-in tools and installable CLIs (`./uis tools install <id>`) |
| [Service Dependencies](./service-dependencies.md) | Service dependency graph |
| [Factory Reset](./factory-reset.md) | Factory reset and full verification guide |
| [Troubleshooting](./troubleshooting.md) | Troubleshooting guide for common issues |

### Contributors — Rules & Standards

*Development guidelines, workflows, and architectural standards*

| Document | Purpose |
|----------|---------|
| [Rules Overview](../contributors/rules/index.md) | Rules guide and index |
| [UIS Deployment System](../contributors/rules/kubernetes-deployment.md) | UIS CLI, service metadata, stacks, and deploy flow |
| [Provisioning](../contributors/rules/provisioning.md) | Ansible playbook patterns and testing standards |
| [Naming Conventions](../contributors/rules/naming-conventions.md) | File, resource, and identifier naming patterns |
| [Ingress & Traefik](../contributors/rules/ingress-traefik.md) | Traefik IngressRoute standards |
| [Git Workflow](../contributors/rules/git-workflow.md) | Git branching, commits, and PR standards |
| [Secrets Management Rules](../contributors/rules/secrets-management.md) | Secrets management rules |
| [Development Workflow](../contributors/rules/development-workflow.md) | Development workflow and command execution |
| [Documentation Guide](../contributors/rules/documentation.md) | Documentation standards |

### Contributors — Architecture

*Internal system design and implementation details*

| Document | Purpose |
|----------|---------|
| [Deploy System](../contributors/architecture/deploy-system.md) | Kubernetes-specific management tools |
| [Tools System Architecture](../contributors/architecture/tools.md) | How `./uis tools` and install scripts work; how to add a new optional tool |
| [Kubernetes Manifests](../contributors/architecture/manifests.md) | Manifest file reference |
| [Secrets Management System](../contributors/architecture/secrets.md) | Secrets management system documentation |

### AI Development

*Guides for contributors using AI-assisted development*

| Document | Purpose |
|----------|---------|
| [AI Developer Guide](../ai-developer/README.md) | Overview for AI coding assistants |
| [Workflow](../ai-developer/WORKFLOW.md) | Workflow for AI-assisted contributions |
| [Plans](../ai-developer/PLANS.md) | Plan structure, templates, and best practices |

## Finding What You Need

### By Role

**Developers:**
- Start: [Installation](../getting-started/installation.md) → [Architecture](../getting-started/architecture.md) → [Provision Host](../advanced/provision-host/index.md)
- AI Development: [AI & ML Overview](../services/ai/index.md)
- Authentication: [Identity Overview](../services/identity/index.md)

**Infrastructure Engineers:**
- Start: [Architecture](../getting-started/architecture.md) → [Hosts](../platforms/index.md)
- Production: [Azure AKS](../platforms/azure-aks.md)
- Networking: [Traefik Rules](../contributors/rules/ingress-traefik.md)

**Architects:**
- Start: [Architecture](../getting-started/architecture.md) → [UIS Deployment System](../contributors/rules/kubernetes-deployment.md)
- Security: [Identity](../services/identity/index.md) → [Secrets Management](../contributors/architecture/secrets.md)

**Data Scientists:**
- Start: [Analytics Overview](../services/analytics/index.md)
- AI/ML: [AI Overview](../services/ai/index.md) → [LiteLLM](../services/ai/litellm.md)

### By Use Case

**Getting Started:**
1. [Installation Guide](../getting-started/installation.md) — Install and setup
2. [System Architecture](../getting-started/architecture.md) — Understand the system
3. [Provision Host](../advanced/provision-host/index.md) — Learn management tools

**Setting Up Authentication:**
1. [Identity Overview](../services/identity/index.md) — Core SSO setup
2. [Auth10 Blueprints](../services/identity/auth10.md) — Blueprint management
3. [Technical Implementation](../services/identity/technical-implementation.md) — Integration details

**AI Development:**
1. [AI & ML Overview](../services/ai/index.md) — Platform overview
2. [LiteLLM](../services/ai/litellm.md) — LLM proxy setup
3. [Open WebUI](../services/ai/openwebui.md) — Chat interface

**Production Deployment:**
1. [Hosts Overview](../platforms/index.md) — Deployment strategies
2. [Azure AKS](../platforms/azure-aks.md) — Azure production
3. [Networking Overview](../networking/index.md) — External access

**External Access:**
1. [Cloudflare Setup](../networking/cloudflare-setup.md) — Cloudflare tunnels
2. [Tailscale Setup](../networking/tailscale-setup.md) — VPN access
3. [Networking Overview](../networking/index.md) — Network architecture

## Getting Help

- **Technical Issues**: See [Troubleshooting Guide](./troubleshooting.md)
- **Architecture Questions**: Review [System Architecture](../getting-started/architecture.md)
- **Bug Reports**: Use GitHub issues in the main repository
- **Contributions**: Follow [Git Workflow Rules](../contributors/rules/git-workflow.md)

## Documentation Standards

All documentation follows the standards defined in:
- [Documentation Guide](../contributors/rules/documentation.md) — Documentation writing standards
- [Git Workflow Rules](../contributors/rules/git-workflow.md) — Git workflow and contribution standards

---

**Total Documentation**: 92 pages (excluding internal plans) | **Last Updated**: March 2026
