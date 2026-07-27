# Kubernetes Manifests

The `manifests/` directory contains Kubernetes manifest files — Helm values configs, IngressRoute definitions, ConfigMaps, and deployment specs — for all services in the infrastructure.

## How Manifests Are Used

Manifests are referenced by Ansible playbooks during deployment. The UIS CLI dispatches to playbooks, which apply the appropriate manifests:

```
./uis deploy postgresql
    → ansible-playbook 040-database-postgresql.yml
        → helm upgrade --install ... -f manifests/042-database-postgresql-config.yaml
```

Some manifests are Jinja2 templates (`.yaml.j2`) that Ansible renders with variables before applying.

For deployment commands, see [UIS Deployment System](../rules/kubernetes-deployment.md). For manifest naming rules, see [Naming Conventions](../rules/naming-conventions.md).

## Manifest Organization

Files are numbered by category. The number in the manifest filename matches the corresponding Ansible playbook number.

### 000-012: Core Infrastructure (Storage, Traefik)

| File | Purpose |
|------|---------|
| `000-storage-class-alias.yaml` | Storage class configuration |
| `001-storage-class-test-pvc.yaml` | PVC test for storage verification |
| `002-storage-class-test-pod.yaml` | Pod test for storage verification |
| `003-traefik-config.yaml` | Traefik ingress controller configuration |
| `012-traefik-nginx-ingress.yaml` | Traefik IngressRoute for Nginx |

### 020: Nginx

| File | Purpose |
|------|---------|
| `020-nginx-config.yaml` | Nginx Helm values |
| `020-nginx-root-ingress.yaml` | Root domain IngressRoute |
| `020-nginx-storage.yaml` | Nginx persistent storage |

### 030-039: Observability

| File | Purpose |
|------|---------|
| `030-prometheus-config.yaml` | Prometheus Helm values |
| `031-tempo-config.yaml` | Tempo distributed tracing Helm values |
| `032-loki-config.yaml` | Loki log aggregation Helm values |
| `033-otel-collector-config.yaml` | OpenTelemetry Collector Helm values |
| `034-grafana-config.yaml` | Grafana Helm values |
| `035-grafana-test-dashboards.yaml` | Installation test dashboards ConfigMap |
| `036-grafana-sovdev-metrics.yaml` | sovdev-logger metrics dashboard |
| `038-grafana-ingressroute.yaml` | Grafana IngressRoute |
| `039-otel-collector-ingress.yaml` | OTEL Collector IngressRoute |

### 040-069: Databases & Search

| File | Purpose |
|------|---------|
| `040-mongodb-config.yaml` | MongoDB Helm values |
| `042-database-postgresql-config.yaml` | PostgreSQL Helm values |
| `043-database-mysql-config.yaml` | MySQL Helm values |
| `044-qdrant-config.yaml` | Qdrant vector database Helm values |
| `050-redis-config.yaml` | Redis Helm values |
| `060-elasticsearch-config.yaml` | Elasticsearch Helm values |

`045`/`046` sit inside this range but belong to the `STORAGE` category — see below.

### 045-046: Object Storage (MinIO)

| File | Purpose |
|------|---------|
| `045-minio-config.yaml` | MinIO object storage Helm values |
| `046-minio-ingressroute.yaml` | MinIO console + S3 API Traefik routes |

MinIO was originally added under `DATABASES` and later reclassified to `STORAGE`. The numbers were kept — a manifest number is stable for the life of the service, so links, playbook names, and existing deployments are not invalidated by a category change.

### 070-079: Identity (Whoami + Authentik)

| File | Purpose |
|------|---------|
| `070-whoami-service-and-deployment.yaml` | Whoami test service deployment |
| `071-whoami-public-ingressroute.yaml` | Whoami public IngressRoute |
| `073-authentik-1-test-users-groups-blueprint.yaml` | Authentik test users/groups blueprint |
| `073-authentik-2-openwebui-blueprint.yaml` | Authentik OpenWebUI integration blueprint |
| `073-authentik-3-app-slot1-blueprint.yaml` | Authentik generic app slot blueprint |
| `073-authentik-service-protection-blueprint.yaml.j2` | Service protection blueprint (Jinja2 template) |
| `075-authentik-config.yaml.j2` | Authentik Helm values (Jinja2 template) |
| `075-authentik-config-manual.yaml` | Authentik manual config reference |
| `076-authentik-csp-middleware.yaml` | CSP middleware for external HTTPS domains |
| `076-authentik-ingressroute.yaml.j2` | Authentik IngressRoute (Jinja2 template) |
| `077-authentik-forward-auth-middleware.yaml` | Forward auth middleware for protected services |
| `078-service-protection-ingressroute.yaml.j2` | Protected service IngressRoute template |
| `079-basic-auth-middleware.yaml.j2` | Basic auth middleware template |

### 080-099: Integration

| File | Purpose |
|------|---------|
| `080-rabbitmq-config.yaml` | RabbitMQ Helm values |
| `081-rabbitmq-ingressroute.yaml` | RabbitMQ management UI IngressRoute |
| `090-gravitee-config.yaml` | Gravitee API management Helm values |
| `091-gravitee-ingress.yaml` | Gravitee IngressRoute |

### 200-229: AI & ML

| File | Purpose |
|------|---------|
| `200-ai-persistent-storage.yaml` | Shared AI persistent storage PVC |
| `201-tika-config.yaml` | Apache Tika document extraction config |
| `208-openwebui-config.yaml` | Open WebUI Helm values |
| `210-openwebui-ingress.yaml` | Open WebUI IngressRoute |
| `220-litellm-config.yaml` | LiteLLM proxy Helm values |
| `221-litellm-ingress.yaml` | LiteLLM IngressRoute |

### 220-221: Management (ArgoCD)

| File | Purpose |
|------|---------|
| `220-argocd-config.yaml` | ArgoCD Helm values |
| `221-argocd-ingressroute.yaml` | ArgoCD IngressRoute |

### 300-399: Analytics

| File | Purpose |
|------|---------|
| `300-spark-config.yaml` | Apache Spark Helm values |
| `310-jupyterhub-config.yaml` | JupyterHub Helm values |
| `311-jupyterhub-ingress.yaml` | JupyterHub IngressRoute |
| `320-unity-catalog-deployment.yaml` | Unity Catalog deployment spec |
| `321-unity-catalog-ingress.yaml` | Unity Catalog IngressRoute |

### 600-699: Management Tools

| File | Purpose |
|------|---------|
| `641-adm-pgadmin.yaml` | pgAdmin Helm values |
| `651-adm-redisinsight.yaml` | RedisInsight deployment |

### 700-799: Management Ingress

| File | Purpose |
|------|---------|
| `741-pgadmin-ingressroute.yaml` | pgAdmin IngressRoute |
| `751-redisinsight-ingressroute.yaml` | RedisInsight IngressRoute |

### 800-899: Networking

| File | Purpose |
|------|---------|
| `800-tailscale-operator-config.yaml.j2` | Tailscale operator Helm values (Jinja2 template) |
| `803-tailscale-cluster-ingress.yaml.j2` | Tailscale cluster ingress (Jinja2 template) |
| `820-cloudflare-tunnel-base.yaml` | Cloudflare tunnel deployment |

## Manifest Patterns

### Configuration Files (`*-config.yaml`)

Helm values files that configure service deployments. These are passed to `helm upgrade --install` via the `-f` flag.

```bash
# Example: deploy PostgreSQL using its config manifest
helm upgrade --install postgresql bitnami/postgresql \
  -f manifests/042-database-postgresql-config.yaml \
  --namespace default
```

### IngressRoute Files (`*-ingressroute.yaml`)

Traefik IngressRoute CRDs for routing external traffic to services. Applied directly with `kubectl apply`. See [Traefik Ingress Rules](../rules/ingress-traefik.md) for patterns.

### Jinja2 Templates (`*.yaml.j2`)

Templates that Ansible renders with variables before applying. Used when manifests need dynamic values (secrets, domain names, cluster-specific config). These are never applied directly with `kubectl`.

### Secret References

Sensitive values reference the `urbalurba-secrets` Kubernetes secret, managed via `./uis secrets generate` and `./uis secrets apply`. See [Secrets Management](./secrets.md).

## Best Practices

- Test manifests with `kubectl apply --dry-run=client -f <file>` before applying
- Manifest number must match the corresponding Ansible playbook number
- Keep Helm values in external config files, never inline in playbooks
- Separate configuration from IngressRoute files
- Leave gaps in numbering for future expansion within each range
