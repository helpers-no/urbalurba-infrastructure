# Kubernetes Deployment

How UIS deploys and manages services on your Kubernetes cluster.

## How it Works

When you run `./uis deploy <service>`, the provision host:

1. Looks up the service's Ansible playbook
2. Checks dependencies (e.g., PostgreSQL must be running before pgAdmin)
3. Runs the playbook, which uses Helm and/or kubectl to deploy
4. Verifies the deployment is healthy

All playbooks, Helm charts, and manifests are baked into the provision host container image.

## Deploying Services

```bash
# Deploy a single service
./uis deploy postgresql

# Deploy a full package (deploys all services in order)
./uis stack install observability

# List all services and their status
./uis list

# Remove a service
./uis undeploy postgresql
```

## Autostart Configuration

You can configure services to deploy automatically when the cluster is built:

```bash
# Enable a service for autostart
./uis enable prometheus

# Disable autostart
./uis disable prometheus

# See which services are enabled
./uis list-enabled
```

## Service Categories

Services are organized into packages by function:

| Category | Services |
|----------|----------|
| **Observability** | Prometheus, Grafana, Loki, Tempo, OTel Collector |
| **AI** | OpenWebUI, LiteLLM, Ollama, Tika, Qdrant |
| **Analytics** | Spark, JupyterHub, Unity Catalog |
| **Identity** | Authentik |
| **Databases** | PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch |
| **Management** | ArgoCD, pgAdmin, RedisInsight, Nginx, Whoami |
| **Networking** | Tailscale, Cloudflare Tunnels |
| **Integration** | RabbitMQ, Gravitee |

See the [full services list](../../getting-started/services.md) for cloud equivalents and deploy commands.

## Service Dependencies

Some services require others to be running first. UIS warns you if dependencies are missing:

| Service | Requires |
|---------|----------|
| Authentik | PostgreSQL, Redis |
| OpenWebUI | PostgreSQL |
| LiteLLM | PostgreSQL |
| Unity Catalog | PostgreSQL |
| pgAdmin | PostgreSQL |
| RedisInsight | Redis |
| Grafana | Prometheus, Loki, Tempo (for full functionality) |

## Accessing Services

After deployment, services are available at `*.localhost` URLs:

```bash
# Check what's deployed
./uis list

# Access in your browser
http://grafana.localhost
http://authentik.localhost
http://openwebui.localhost
```

For external access, see [Tailscale](../../networking/tailscale-setup.md) and [Cloudflare Tunnels](../../networking/cloudflare.md).

## Debugging Deployments

```bash
# Open a shell in the provision host
./uis shell

# Check pod status
kubectl get pods -A

# View logs for a service
kubectl logs -n default -l app=grafana --tail=50

# Describe a failing pod
kubectl describe pod -n default <pod-name>

# Interactive cluster dashboard
k9s
```

## Related Documentation

- **[How Deployment Works](../../advanced/how-deployment-works.md)** — Deep dive into the deploy flow, dependency resolution, health checks, and stacks
- **[Architecture](../../getting-started/architecture.md)** — System architecture overview
- **[Kubernetes Deployment Rules](../rules/kubernetes-deployment.md)** — Conventions for writing playbooks
- **[Provisioning Rules](../rules/provisioning.md)** — Script and playbook standards
- **[UIS CLI Reference](../../reference/uis-cli-reference.md)** — Complete command reference
