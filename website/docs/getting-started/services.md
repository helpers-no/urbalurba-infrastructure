# Services Overview

Complete list of services available in UIS compared to their cloud equivalents.

## Cloud Services Comparison

| Functionality | Azure / AWS | UIS Service | Deploy command |
|---|---|---|---|
| **Container Orchestration** | Azure AKS, EKS | Rancher Desktop | Platform prerequisite |
| **Reverse Proxy & Ingress** | Azure Application Gateway | Traefik | Platform built-in |
| **Web Server** | Azure Static Web Apps | NGINX | `./uis deploy nginx` |
| **Primary Database** | Azure Database for PostgreSQL | PostgreSQL | `./uis deploy postgresql` |
| **Alternative SQL** | Azure Database for MySQL | MySQL | `./uis deploy mysql` |
| **NoSQL Database** | Azure Cosmos DB | MongoDB | `./uis deploy mongodb` |
| **Cache & Session Store** | Azure Cache for Redis | Redis | `./uis deploy redis` |
| **Search Engine** | Azure AI Search | Elasticsearch | `./uis deploy elasticsearch` |
| **Vector Database** | Azure AI Search | Qdrant | `./uis deploy qdrant` |
| **Object Storage** | Azure Blob Storage, AWS S3 | MinIO | `./uis deploy minio` |
| **Workflow Orchestration** | Azure Durable Functions, AWS Step Functions | Temporal | `./uis deploy temporal` |
| **Authentication & SSO** | Azure AD, AWS IAM | Authentik | `./uis deploy authentik` |
| **AI Chat Interface** | Azure OpenAI Service | OpenWebUI | `./uis deploy openwebui` |
| **LLM Proxy & Router** | Azure OpenAI, AWS Bedrock | LiteLLM | `./uis deploy litellm` |
| **Document Processing** | Azure AI Document Intelligence | Apache Tika | `./uis deploy tika` |
| **Monitoring & Dashboards** | Azure Monitor, CloudWatch | Grafana | `./uis deploy grafana` |
| **Metrics Collection** | Azure Monitor | Prometheus | `./uis deploy prometheus` |
| **Log Aggregation** | Azure Log Analytics | Loki | `./uis deploy loki` |
| **Distributed Tracing** | Azure Application Insights | Tempo | `./uis deploy tempo` |
| **Telemetry Pipeline** | Azure Application Insights | OpenTelemetry Collector | `./uis deploy otel-collector` |
| **Data Processing** | Azure Databricks | Apache Spark | `./uis deploy spark` |
| **Notebook Environment** | Azure Machine Learning | JupyterHub | `./uis deploy jupyterhub` |
| **Data Catalog** | Microsoft Purview | Unity Catalog | `./uis deploy unity-catalog` |
| **Message Broker** | Azure Service Bus, SQS | RabbitMQ | `./uis deploy rabbitmq` |
| **API Gateway** | Azure API Management | Gravitee | `./uis deploy gravitee` |
| **GitOps & CD** | Azure DevOps, GitHub Actions | ArgoCD | `./uis deploy argocd` |
| **Database Admin** | Azure Portal | pgAdmin | `./uis deploy pgadmin` |
| **Redis Admin** | Azure Portal | RedisInsight | `./uis deploy redisinsight` |
| **VPN Connectivity** | Azure VPN Gateway | Tailscale | `./uis network up tailscale` |
| **Public Tunnels** | Azure Front Door | Cloudflare Tunnels | `./uis network up cloudflare` |
| **Test Service** | — | Whoami | `./uis deploy whoami` |

## Service Categories

### Observability
- **Prometheus** — Metrics collection and alerting
- **Grafana** — Monitoring dashboards and visualization
- **Loki** — Log aggregation and analysis
- **Tempo** — Distributed tracing
- **OpenTelemetry Collector** — Telemetry pipeline

Deploy as a package: `./uis stack install observability`

### AI
- **OpenWebUI** — Chat interface for LLMs
- **LiteLLM** — Universal LLM proxy and router
- **Ollama** — Local LLM runtime
- **Tika** — Document processing and extraction
- **Qdrant** — Vector database for embeddings

### Analytics
- **Apache Spark** — Distributed data processing
- **JupyterHub** — Multi-user notebook environment
- **Unity Catalog** — Data governance and cataloging

### Identity
- **Authentik** — Authentication, SSO, and identity provider

### Databases
- **PostgreSQL** — Primary relational database
- **MySQL** — Alternative SQL database
- **MongoDB** — Document database
- **Redis** — Cache and session store
- **Elasticsearch** — Full-text search engine

### Storage
- **MinIO** — S3-compatible object storage

### Management
- **ArgoCD** — GitOps continuous delivery
- **pgAdmin** — PostgreSQL administration
- **RedisInsight** — Redis administration
- **Gravitee** — API lifecycle management

### Networking
- **Tailscale** — Secure mesh VPN
- **Cloudflare Tunnels** — Public access without port forwarding

### Integration
- **RabbitMQ** — Message queuing

## Service Dependencies

Some services require others to be running first:

| Service | Requires |
|---------|----------|
| Authentik | PostgreSQL, Redis |
| OpenWebUI | PostgreSQL |
| LiteLLM | PostgreSQL |
| Unity Catalog | PostgreSQL |
| pgAdmin | PostgreSQL |
| RedisInsight | Redis |
| Grafana | Prometheus, Loki, Tempo (for full functionality) |
| OTel Collector | Prometheus, Loki, Tempo (as backends) |

UIS checks dependencies automatically and warns if a required service is not deployed.

## Service Access

All services are accessible through `*.localhost` URLs:

| Service | URL |
|---------|-----|
| Grafana | [http://grafana.localhost](http://grafana.localhost) |
| Prometheus | [http://prometheus.localhost](http://prometheus.localhost) |
| Authentik | [http://authentik.localhost](http://authentik.localhost) |
| OpenWebUI | [http://openwebui.localhost](http://openwebui.localhost) |
| pgAdmin | [http://pgadmin.localhost](http://pgadmin.localhost) |
| ArgoCD | [http://argocd.localhost](http://argocd.localhost) |

## Related Documentation

- **[Architecture](./architecture.md)** — How UIS works
- **[AI Services](../services/ai/index.md)** — AI services configuration
- **[Identity Services](../services/identity/authentik.md)** — SSO setup
- **[Service Dependencies](../reference/service-dependencies.md)** — Full dependency graph
