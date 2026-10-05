# pgvector does not work on this host (CPU limitation)

## Symptom

Open WebUI crash-loops at startup, and **all of PostgreSQL restarts with it**:

```
open-webui-0   0/1   Error   3 (61s ago)
```

Open WebUI log:

```
sqlalchemy.exc.OperationalError: (psycopg2.OperationalError)
server closed the connection unexpectedly
[SQL: CREATE INDEX IF NOT EXISTS idx_document_chunk_vector
      ON document_chunk USING ivfflat (vector vector_cosine_ops) WITH (lists = 100)]
```

PostgreSQL log (`kubectl logs postgresql-0 -n default`):

```
LOG:  client backend (PID 4838) was terminated by signal 4: Illegal instruction
DETAIL:  Failed process was running: CREATE INDEX ... USING ivfflat (...)
LOG:  terminating any other active server processes
LOG:  all server processes terminated; reinitializing
```

## Root cause

This host's CPU is an **Intel Core i5-2400S** (Sandy Bridge, 2011). It has SSE4.2
and AVX, but **no AVX2 and no FMA**.

The pgvector 0.8.2 build shipped in the Bitnami PostgreSQL image compiles its
distance functions for a newer instruction set. Executing them raises SIGILL
(signal 4, illegal instruction).

This is not an index-tuning problem. It is not memory. Verified at the lowest
possible level — the vector *type* works, but every distance *operator* kills
the backend:

```bash
PGPW=$(kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.PGPASSWORD}' | base64 -d)

# works - type parsing is plain C
kubectl exec -n default postgresql-0 -- env PGPASSWORD="$PGPW" \
  psql -U postgres -d openwebui -tAc "SELECT '[1,2,3]'::vector"
# -> [1,2,3]

# crashes the server - SIMD distance kernel
kubectl exec -n default postgresql-0 -- env PGPASSWORD="$PGPW" \
  psql -U postgres -d openwebui -tAc "SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector"
# -> server closed the connection unexpectedly
```

Because a SIGILL in any backend forces the postmaster to terminate *all*
connections and reinitialize, every Open WebUI restart attempt also bounced
LiteLLM's database connection. Switching vector stores fixes both.

Changing `PGVECTOR_INDEX_METHOD` to `hnsw` does **not** help — hnsw builds use
the same distance kernels. There is no "skip the index" option; Open WebUI
always calls `_ensure_vector_index()`.

## Fix applied

`VECTOR_DB` switched from `pgvector` to `chroma` (Open WebUI's own upstream
default). Chroma is embedded in the pod and persists to the `openwebui-data`
PVC, so no extra service is needed.

Chroma was verified on this CPU before deploying:

```bash
kubectl run chroma-test -n ai --rm -i --restart=Never \
  --image=ghcr.io/open-webui/open-webui:0.11.0 --quiet --command -- \
python3 -c "
import chromadb
c = chromadb.PersistentClient(path='/tmp/ctest')
col = c.get_or_create_collection('testcol')
col.add(ids=['a','b'], embeddings=[[0.1]*384, [0.2]*384])
print('CHROMA OK ->', col.query(query_embeddings=[[0.15]*384], n_results=2)['ids'])
"
# -> CHROMA OK -> [['b', 'a']]
```

Note the collection name must be 3+ characters or Chroma rejects it.

## IMPORTANT: this patch is not durable

The change is made to `/mnt/urbalurbadisk/manifests/208-openwebui-config.yaml`
**inside the uis-provision-host container image**. UIS has no override
mechanism for Helm values — `.uis.extend/` only holds cluster and host config.

So `./uis pull` (or anything that recreates the container) **reverts it**, and
the next `./uis deploy openwebui` will crash-loop again and take PostgreSQL
down with it.

After any `./uis pull`, re-apply with:

```bash
./mac-ollama/patch-openwebui-vectordb.sh
```

---

# Second, unrelated issue: Traefik v2 vs v3 IngressRoute syntax

## Symptom

Both playbooks report `IngressRoute: ✅ Traefik routing configured`, but the
URLs return 404 — from the host *and* from inside the cluster:

```bash
curl -H "Host: openwebui.localhost" http://127.0.0.1/    # -> 404
```

## Root cause

UIS manifests use **Traefik v3** syntax:

```yaml
match: HostRegexp(`openwebui\..+`)
```

Rancher Desktop's k3s ships **Traefik v2.10.5**, where `HostRegexp` is not a
plain regex — it needs `{name:pattern}` capture groups. Under v2 the v3 form
matches nothing, so Traefik falls through to its default 404.

This affects **every** UIS service, not just these two — 18+ manifests in
`/mnt/urbalurbadisk/manifests/` use the v3 form:

```bash
docker exec uis-provision-host grep -rln HostRegexp /mnt/urbalurbadisk/manifests/
```

## Fix applied

The two deployed routes were rewritten in place to the v2 form:

```yaml
match: HostRegexp(`openwebui.{rest:.+}`)
```

Verified: `http://openwebui.localhost` and `http://litellm.localhost` both
return HTTP 200 from the host.

## IMPORTANT: this also reverts

`uis deploy litellm` and `uis deploy openwebui` re-apply the shipped manifests,
restoring the v3 syntax and breaking the URLs again. Re-run
`./mac-ollama/patch-openwebui-vectordb.sh` after either deploy — it fixes both
routes and is safe to run repeatedly.

The real fix is either upgrading this cluster's Traefik to v3, or correcting the
UIS manifests upstream. Both are bigger decisions than this deployment.

---

## Longer-term options

- Upstream a `VECTOR_DB` override into UIS's `.uis.extend/` mechanism.
- Deploy `qdrant` (`uis deploy qdrant`) and set `VECTOR_DB=qdrant` — UIS already
  provisions `qdrant-data` / `qdrant-snapshots` PVCs. Qdrant does runtime CPU
  feature detection, so it should be safe here, but it was not tested.
- Run PostgreSQL from an image whose pgvector is built for a baseline x86-64
  target, or build pgvector from source with `-march=x86-64`.
- Move this workload to a host newer than 2011.
