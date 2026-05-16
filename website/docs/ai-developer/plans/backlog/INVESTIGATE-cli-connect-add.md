# Investigate: UIS Connect Commands for All Services

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Build a generic `uis service connect <service> [arg]` surface that opens an interactive client into any deployed service. Replaces the per-service-verb framing (`uis connect postgresql …`) with a single umbrella verb under `uis service <verb>` (alongside future `uis service logs`, `uis service describe`, etc.).

**Direction (2026-05-16)** — promote the `uis service <verb>` namespace as the lock-in shape from the start. The 4 existing connects (`uis connect postgresql/mysql/redis/mongodb` from PLAN-002) move under the umbrella; the legacy form stays as an alias for one release cycle. The per-service interactive surface ("what each service can offer") is what needs investigation — see "Per-service client surface" section below.

**Priority**: Low — the pod-exec fallback works; shell commands are a convenience.

**Last Updated**: 2026-05-16

**Related**:
- [PLAN-002-uis-template-command.md](../active/PLAN-002-uis-template-command.md) — initial `uis connect` with 4 services (postgresql, mysql, redis, mongodb) landed here
- [PLAN-001-uis-configure-expose.md](../completed/PLAN-001-uis-configure-expose.md) — same pod-exec pattern used by `uis configure`

---

## Problem

Testers and developers often need to verify deployments by querying the service directly. Each service has a native client (psql, mysql, redis-cli, mongosh, etc.), but:

1. **We can't bake every client into `uis-provision-host`** — postgresql-client, mysql-client, mongosh, redis-tools, etc. add 50-200MB combined. And we'd need to keep them updated with each service version.

2. **The host machine may not have clients installed** — macOS doesn't ship with psql, developers don't always want to install DB clients globally.

3. **Every service pod already has its own native client** — that's how `uis configure` works internally. We just need to expose that pattern.

## Initial Implementation (in PLAN-002)

A minimal `uis connect <service>` command was added with 4 services:

```bash
uis connect postgresql              # psql as admin
uis connect postgresql demo_db      # psql into specific database
uis connect mysql                   # mysql as root
uis connect redis                   # redis-cli with auth
uis connect mongodb                 # mongosh as root
```

Implementation: `provision-host/uis/lib/shell.sh` uses a lookup table (`SHELL_CONFIG`) mapping service → pod selector, namespace, client command, secret key for admin password.

## Target shape under `uis service <verb>`

```bash
uis service connect redis                          # redis-cli with auth
uis service connect postgresql                     # psql as admin
uis service connect postgresql demo_db             # psql into specific database
uis service connect mongodb                        # mongosh as root
uis service connect mysql                          # mysql as root
```

The optional trailing argument is service-specific. The lookup table grows from `service → command` to `service → command-template`, where the template knows how to consume the arg (e.g. for postgres, it becomes the `-d <database>` flag; for redis, maybe a key prefix; for mongo, a database name).

## Per-service client surface — what does each service actually offer?

Open question the user flagged. The pattern only works if each service either ships a useful CLI in its pod or can be wrapped in a `curl`-around-the-API shim. Survey:

| Service | In-pod client | Connect mode | Trailing-arg meaning | Notes |
|---|---|---|---|---|
| postgresql | `psql` | interactive | database name (`-d`) | default to `postgres` (admin DB); arg switches DB |
| mysql | `mysql` | interactive | database name | same shape as postgres |
| mongodb | `mongosh` | interactive | database name | mongosh's last positional arg is the DB |
| redis | `redis-cli` | interactive REPL | DB number (`-n`) or key prefix | trailing arg less obvious; could be ignored |
| elasticsearch | curl-only (no REPL) | one-shot or wrapper | index name or query | needs a curl-around-API shim, e.g. drop into `curl localhost:9200/<arg>` |
| qdrant | curl-only | one-shot or wrapper | collection name | same as elasticsearch — REST wrapper |
| rabbitmq | `rabbitmqctl` (non-interactive) | one-shot subcommand | rabbitmqctl subcommand | `uis service connect rabbitmq list_queues` style |
| grafana | none (web-only) | sh fallback | — | drop into pod `sh` for debugging; warn the user |
| prometheus | `promtool` (non-interactive) | one-shot | promtool subcommand | same shape as rabbitmq |
| loki | `logcli` (in some images) | non-interactive | query | depends on image |
| authentik | `ak` (Django mgmt) | interactive shell + subcommands | mgmt subcommand | `uis service connect authentik shell_plus` |
| nginx | none useful | sh fallback | — | warn-and-fall-back |

The pattern crystallises into three buckets:

1. **Interactive REPL** (postgres, mysql, mongo, redis) — `kubectl exec -it … <client>`, optional trailing arg maps to a known flag.
2. **One-shot subcommand** (rabbitmq, promtool, authentik mgmt) — `kubectl exec -- <client> <subcommand>`, no `-it`.
3. **No useful CLI** (grafana, nginx, elasticsearch UI) — drop into `sh` and print a "use the web UI at …" hint, or use a curl-wrapper if there's an API to hit.

`SHELL_CONFIG` should carry an explicit `mode` field per service so the dispatch picks the right `kubectl exec` shape.

## Open Design Questions

1. **Coverage** — which services need connects? Data services (postgresql, mysql, mongodb, redis, elasticsearch, qdrant) are obvious. What about:
   - **Observability**: grafana (has a CLI), prometheus (promtool), loki (logcli)?
   - **Messaging**: rabbitmq (rabbitmqctl)?
   - **Search**: elasticsearch (via curl), qdrant (via curl)?
   - **Auth**: authentik (Django shell)?

2. **Non-shell services** — some services don't have interactive clients (web-only admin like pgAdmin, Grafana). For these, `uis connect` could:
   - Return an error "use the web UI at http://grafana.localhost"
   - Run a generic `sh`/`bash` shell in the pod for debugging
   - Open a `curl`-based query prompt

3. **Admin vs app-user credentials** — currently all connects connect as the service admin (postgres, root, etc.). Should there be:
   - `uis connect postgresql --as demo_app` to connect as an app user (requires stored password)
   - Default to admin (simpler, always works)

4. **Data source for SHELL_CONFIG** — currently hardcoded in shell.sh. Could be moved to `services.json` as a `shell` field per service:
   ```json
   {
     "id": "postgresql",
     "shell": {
       "selector": "app.kubernetes.io/name=postgresql",
       "namespace": "default",
       "client": "psql -U postgres",
       "secret": "PGPASSWORD"
     }
   }
   ```
   This makes adding connects for new services a metadata change, not a code change.

5. **Pod entrypoint vs direct command** — for some services, the client binary is at a specific path or needs environment setup. Do we always `exec -it pod -- <client>`, or sometimes `exec -it pod -- sh -c "source env && <client>"`?

## Candidate Services to Add

After the initial 4 services (postgresql, mysql, mongodb, redis), candidates in priority order:

| Service | Client | Priority | Notes |
|---------|--------|----------|-------|
| elasticsearch | curl + Elasticsearch API | High | No interactive CLI, need curl wrapper |
| qdrant | curl + Qdrant API | High | Same — curl-based |
| rabbitmq | rabbitmqctl | Medium | Built into pod |
| authentik | ak (Django management) | Medium | Admin-only commands |
| nginx | shell | Low | Just for debugging |

## Related verbs in the same `uis service <verb>` namespace

The umbrella is what makes the shape coherent — once `service connect` exists, the obvious next siblings are:

- `uis service logs <service>` — kubectl logs for the service pod
- `uis service describe <service>` — kubectl describe for debugging
- `uis service exec <service> -- <cmd>` — generic pod-exec for cases the mode table doesn't cover

These don't need to ship in the first PLAN — but the connect dispatcher should be built so it slots into a shared `cmd_service_*` family in `uis-cli.sh`.

## Next Steps

- [ ] Lock in the `uis service connect <service> [arg]` shape (legacy `uis connect <service>` stays as alias for one release).
- [ ] Decide on coverage round 1 (the 4 already-shipped REPL services + elasticsearch/qdrant as curl-wrappers, or REPL-only for round 1).
- [ ] Decide on config source — keep `SHELL_CONFIG` lookup in `shell.sh`, or move to a `connect` block in `services.json` (metadata vs code).
- [ ] Add a `mode` field per service (`repl` / `oneshot` / `sh-fallback`) so the dispatcher picks the right `kubectl exec` shape.
- [ ] Create PLAN when scope is clear.
