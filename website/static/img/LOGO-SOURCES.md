# Logo Sources Reference

This document tracks the sources for all logos used in the UIS documentation website.

## Category Logos

All category logos use [Heroicons](https://heroicons.com/) (MIT License) with SovereignSky green (#3a8f5e).

| Logo ID | Category | Heroicon Name | Source | Reused from DCT |
|---------|----------|---------------|--------|-----------------|
| `ai-logo` | AI & Machine Learning | Sparkles | [heroicons.com](https://heroicons.com/) | Yes |
| `authentication-logo` | Authentication & SSO | ShieldCheck | [heroicons.com](https://heroicons.com/) | No |
| `databases-logo` | Databases | CircleStack | [heroicons.com](https://heroicons.com/) | No |
| `monitoring-logo` | Observability & Monitoring | ServerStack | [heroicons.com](https://heroicons.com/) | Yes |
| `queues-logo` | Message Queues & Caching | QueueList | [heroicons.com](https://heroicons.com/) | No |
| `search-logo` | Search & Indexing | MagnifyingGlass | [heroicons.com](https://heroicons.com/) | No |
| `datascience-logo` | Data Science & Analytics | ChartBar | [heroicons.com](https://heroicons.com/) | Yes |
| `core-logo` | Core Infrastructure | Cog | [heroicons.com](https://heroicons.com/) | Yes |
| `management-logo` | Management Tools | AdjustmentsHorizontal | [heroicons.com](https://heroicons.com/) | No |
| `development-logo` | Development Tools | Code | [heroicons.com](https://heroicons.com/) | Yes |

## Service Logos

Service logos sourced from official project websites and icon repositories. SVG preferred, PNG as fallback.

**Actual Sources Used:**
- **CNCF Artwork**: prometheus, argocd, otel-collector
- **Simple Icons**: grafana, postgresql, mysql, mongodb, redis, rabbitmq, elasticsearch, nginx, spark, jupyterhub, cloudflare, tailscale, traefik, ollama
- **Official GitHub**: authentik, litellm, qdrant, loki (PNG), openwebui (PNG), pgadmin (PNG), unity-catalog (PNG)
- **Created (Heroicons style)**: gravitee, redisinsight, tempo, tika, minio

### Core Infrastructure
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `traefik-logo` | Traefik | [traefik.io](https://traefik.io/) | Traefik Labs |
| `nginx-logo` | NGINX | [nginx.org](https://nginx.org/) | F5/NGINX |

### Databases
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `postgresql-logo` | PostgreSQL | [postgresql.org/media](https://www.postgresql.org/media/img/) | PostgreSQL License |
| `mysql-logo` | MySQL | [mysql.com](https://www.mysql.com/) | Oracle |
| `mongodb-logo` | MongoDB | [mongodb.com](https://www.mongodb.com/) | MongoDB |
| `qdrant-logo` | Qdrant | [qdrant.tech](https://qdrant.tech/) | Apache 2.0 |
| `minio-logo` | MinIO | Created (Heroicons style, MinIO red #C72E29) | Heroicons MIT |

### Message Queues & Caching
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `redis-logo` | Redis | [redis.io](https://redis.io/) | Redis Ltd |
| `rabbitmq-logo` | RabbitMQ | [rabbitmq.com](https://www.rabbitmq.com/) | Mozilla Public License |

### Search & Indexing
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `elasticsearch-logo` | Elasticsearch | [elastic.co/brand](https://www.elastic.co/brand) | Elastic |

### API Management
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `gravitee-logo` | Gravitee | [gravitee.io](https://www.gravitee.io/) | Gravitee |

### Management Tools
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `pgadmin-logo` | pgAdmin | [pgadmin.org](https://www.pgadmin.org/) | PostgreSQL License |
| `redisinsight-logo` | RedisInsight | [redis.io/insight](https://redis.io/insight/) | Redis Ltd |

### AI & Machine Learning
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `openwebui-logo` | Open WebUI | [openwebui.com](https://openwebui.com/) | MIT |
| `ollama-logo` | Ollama | [ollama.ai](https://ollama.ai/) | MIT |
| `litellm-logo` | LiteLLM | [litellm.ai](https://litellm.ai/) | MIT |
| `tika-logo` | Apache Tika | [tika.apache.org](https://tika.apache.org/) | Apache 2.0 |

### Development Tools
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `argocd-logo` | Argo CD | [CNCF Artwork](https://github.com/cncf/artwork/tree/main/projects/argo) | Apache 2.0 |

### Network
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `tailscale-logo` | Tailscale | [tailscale.com](https://tailscale.com/) | Tailscale |
| `cloudflare-logo` | Cloudflare | [cloudflare.com](https://www.cloudflare.com/) | Cloudflare |

### Data Science & Analytics
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `spark-logo` | Apache Spark | [Apache Foundation](https://www.apache.org/logos/) | Apache 2.0 |
| `jupyterhub-logo` | JupyterHub | [jupyter.org](https://jupyter.org/) | BSD |
| `unity-catalog-logo` | Unity Catalog | [unitycatalog.io](https://www.unitycatalog.io/) | Apache 2.0 |

### Observability & Monitoring
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `prometheus-logo` | Prometheus | [CNCF Artwork](https://github.com/cncf/artwork/tree/main/projects/prometheus) | Apache 2.0 |
| `grafana-logo` | Grafana | [grafana.com/brand-guidelines](https://grafana.com/brand-guidelines/) | Grafana Labs |
| `loki-logo` | Loki | [CNCF Artwork](https://github.com/cncf/artwork) | Apache 2.0 |
| `tempo-logo` | Tempo | [CNCF Artwork](https://github.com/cncf/artwork) | Apache 2.0 |
| `otel-collector-logo` | OpenTelemetry Collector | [CNCF Artwork](https://github.com/cncf/artwork/tree/main/projects/opentelemetry) | Apache 2.0 |

### Authentication & SSO
| Logo ID | Service | Source | License |
|---------|---------|--------|---------|
| `authentik-logo` | Authentik | [goauthentik.io](https://goauthentik.io/) | MIT |

**Total: 28 service logos**

## Stack Logos

Stack logos represent groups of services that work together. Created using Heroicons style with SovereignSky green (#3a8f5e).

| Logo ID | Stack | Description | Style |
|---------|-------|-------------|-------|
| `observability-stack-logo` | Observability Stack | Metrics/logs/traces visualization | Heroicons (custom) |
| `ai-local-stack-logo` | Local AI Stack | Neural network/processor | Heroicons (custom) |
| `datascience-stack-logo` | Data Science Stack | Beaker/flask with data | Heroicons (custom) |

**Total: 3 stack logos**

## General Icon Sources

These sites provide large collections of tech brand icons:

1. **[Heroicons](https://heroicons.com/)** - Generic UI icons (MIT license)
2. **[Simple Icons](https://simpleicons.org/)** - 3000+ tech brand SVGs with official colors
3. **[CNCF Artwork](https://github.com/cncf/artwork)** - All CNCF project logos
4. **[Devicon](https://devicon.dev/)** - Programming language and dev tool icons
5. **[Wikimedia Commons](https://commons.wikimedia.org/)** - Many tech logos with clear licensing

## Folder Structure

```
static/img/
├── categories/
│   ├── src/              # Source SVG files
│   │   └── *.svg
│   └── *.svg             # Production SVGs (copied from src)
├── services/
│   ├── src/              # Original source files (various formats)
│   └── *-logo.svg        # Production SVGs or PNG files
├── stacks/
│   ├── src/              # Source SVG files
│   │   └── *.svg
│   └── *-stack-logo.svg  # Production SVGs
└── LOGO-SOURCES.md       # This file
```

## Naming Convention

- Category logos: `{category-id}-logo.svg` (e.g., `ai-logo.svg`)
- Service logos: `{service-id}-logo.svg` or `{service-id}-logo.png`
- Stack logos: `{stack-id}-stack-logo.svg` (e.g., `observability-stack-logo.svg`)
- Source files kept in `src/` subfolder for future editing

## Color Scheme

All category icons use SovereignSky brand colors:
- **Primary green**: `#3a8f5e`
- **Teal**: `#25c2a0`
- **Navy**: `#1e3a5f`

## Harmonization with DevContainer Toolbox

5 category logos are shared with DCT project:
- ai-logo (Sparkles)
- monitoring-logo (ServerStack)
- datascience-logo (ChartBar)
- core-logo (Cog)
- development-logo (Code)

When updating these, consider updating both projects for consistency.
