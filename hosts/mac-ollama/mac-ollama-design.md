# External Ollama backends for LiteLLM

LiteLLM runs in the cluster; the models do not. Two Macs on the network serve
them, each exposed as a selector-less Service with hand-managed Endpoints so it
gets a stable cluster DNS name.

| Backend | Host | Service DNS | Address | Reached via |
|---|---|---|---|---|
| M4 Pro | `MBP-J4G0G066W2` | `mac-ollama.ai.svc.cluster.local:11434` | `192.168.68.58` | LAN (DHCP) |
| M1 | `tecMacDev` | `m1-ollama.ai.svc.cluster.local:11434` | `100.127.6.20` | Tailscale |

## Files

| File | Purpose |
|---|---|
| `00-mac-ollama-endpoint.yaml` | M4 Service + Endpoints |
| `02-m1-ollama-endpoint.yaml` | M1 Service + Endpoints |
| `01-litellm-models.yaml` | `ai-models-litellm` ConfigMap — the LiteLLM model list |
| `patch-openwebui-vectordb.sh` | Re-applies the two local UIS workarounds |
| `README-cpu-limitation.md` | Why pgvector is unusable here, and the Traefik v2/v3 fix |

Apply order matters only on a fresh install: `210-setup-litellm.yml` creates a
default ConfigMap *only if one does not exist*, so apply `01-litellm-models.yaml`
**before** `uis deploy litellm` to keep your own model list.

```bash
kubectl apply -f 00-mac-ollama-endpoint.yaml
kubectl apply -f 02-m1-ollama-endpoint.yaml
kubectl apply -f 01-litellm-models.yaml
kubectl rollout restart deployment/litellm -n ai   # only after editing the ConfigMap
```

## Model naming

Unprefixed names are on the **M4**. Everything on the **M1** is prefixed `m1-`.

This is deliberate. `gemma3:4b`, `llava:7b` and `nomic-embed-text` exist on both
machines. LiteLLM treats two entries sharing a `model_name` as a load-balancing
pool, so without the prefix you could not tell — or control — which Mac served a
given request. The prefix keeps them addressable independently.

If you *want* failover across both Macs for a given model, that is the one case
to drop the prefix: give both entries the same `model_name` and LiteLLM will
distribute between them.

| Model | M4 | M1 |
|---|---|---|
| gpt-oss:20b | `gpt-oss:20b`, `mac-gpt-oss-balanced` | — |
| gemma4 | `gemma4:latest` | — |
| qwen3:8b | `qwen3:8b` | — |
| qwen2.5-coder:7b | `qwen2.5-coder:7b` | — |
| deepseek-coder:6.7b | `deepseek-coder:6.7b` | — |
| deepseek-r1 | — | `m1-deepseek-r1` |
| mistral | — | `m1-mistral` |
| gemma3:4b | `gemma3:4b` | `m1-gemma3:4b` |
| llava:7b | `llava:7b` | `m1-llava:7b` |
| nomic-embed-text | `nomic-embed-text` | `m1-nomic-embed-text` |

## Known rough edge: a sleeping Mac hangs the request

Neither address survives its laptop sleeping, and the failure is slow rather
than clean. `litellm_settings.request_timeout` is `600`, so a call to a model on
a sleeping Mac can hang for up to **10 minutes** before erroring — measured at
45s with no response and still climbing.

That timeout is high on purpose: a large local model can be slow to first token,
and lowering it globally would break legitimate long generations on the M4. If
the hang becomes annoying, the better fixes are per-model `timeout` overrides on
the fast small models, or a LiteLLM `fallbacks` entry so a sleeping host rolls
over to the other Mac instead of stalling.

First thing to check when `m1-*` or unprefixed models start timing out: **is the
Mac awake?**

## When an address changes

Only the endpoint file needs editing — the LiteLLM config refers to DNS names,
and no restart is needed because the name is resolved per request.

```bash
getent hosts MBP-J4G0G066W2.local     # M4, LAN
getent hosts tecMacDev.local          # M1, LAN
getent hosts tecMacDev                # M1, Tailscale
# update the ip in the matching *-endpoint.yaml, then kubectl apply -f it
```

The M4 is **not on Tailscale**, so it uses its LAN address and there is no
alternative for it — `getent hosts MBP-J4G0G066W2` returns nothing. Its DHCP
address moves, so `00-mac-ollama-endpoint.yaml` needs updating when it does.

The M1 is on the tailnet, so it uses its Tailscale address, which does not move
and also works when that laptop is off the LAN.

## Using LiteLLM from your other machines

LiteLLM speaks the OpenAI API, so anything that accepts a custom base URL works.

### Endpoints

| From | Base URL | Notes |
|---|---|---|
| Anything on the tailnet | `http://imac/v1` | **Preferred.** MagicDNS, stable, works off-LAN |
| Anything on the tailnet | `http://100.84.7.57/v1` | Same, by IP |
| Same LAN only | `http://192.168.68.55/v1` | This host's LAN IP — **DHCP, will move** |
| This machine | `http://litellm.localhost/v1` | Also serves the admin UI |

Prefer the tailnet name. The LAN address is a DHCP lease and changes; `imac`
does not, and keeps working when a laptop leaves the house.

### Why a bare IP works at all

UIS routes LiteLLM by hostname (`HostRegexp(litellm.{rest:.+})`), which is
useless to SDKs — they send `Host: <ip>`, which matches nothing, and Traefik
returns 404. Rancher Desktop does not forward NodePorts to the host either, so
that escape hatch is closed.

`03-litellm-lan-access.yaml` adds a second, host-independent route matching
`PathPrefix(/v1)` at the lowest priority. Any hostname reaches the API, while
every existing Host-based rule still wins — `openwebui.localhost/v1` still goes
to Open WebUI. Apply it with `kubectl apply -f 03-litellm-lan-access.yaml`; it
is a separate object from the UIS-managed `litellm` IngressRoute, so
`uis deploy litellm` will not wipe it.

### Getting a key

The admin/master key:

```bash
kubectl get secret urbalurba-secrets -n ai \
  -o jsonpath='{.data.LITELLM_PROXY_MASTER_KEY}' | base64 -d
```

**Do not hand that out** — it is an admin credential. Issue a per-machine
virtual key instead, optionally scoped to specific models:

```bash
MASTER=$(kubectl get secret urbalurba-secrets -n ai \
  -o jsonpath='{.data.LITELLM_PROXY_MASTER_KEY}' | base64 -d)

curl -s -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d '{"key_alias":"laptop","models":["m1-mistral","gemma3:4b"],"max_budget":10}' \
  http://litellm.localhost/key/generate
```

Verified: a key scoped to `m1-mistral` gets `200` for that model and `403` for
anything else. Revoke with `/key/delete`, or manage keys in the admin UI at
<http://litellm.localhost/ui>.

### Client examples

Environment variables — picked up by most OpenAI-compatible tooling:

```bash
export OPENAI_BASE_URL="http://imac/v1"
export OPENAI_API_KEY="sk-...your-virtual-key..."
```

curl:

```bash
curl http://imac/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-oss:20b","messages":[{"role":"user","content":"hello"}]}'
```

Python:

```python
from openai import OpenAI
client = OpenAI(base_url="http://imac/v1", api_key="sk-...")
print(client.chat.completions.create(
    model="m1-mistral",
    messages=[{"role": "user", "content": "hello"}],
).choices[0].message.content)
```

List what is available: `curl -s http://imac/v1/models -H "Authorization: Bearer $OPENAI_API_KEY"`

Remember the model naming rule above — unprefixed names run on the M4,
`m1-*` on the M1 — and that a request to a sleeping Mac hangs rather than
failing fast.

## Keeping the Macs awake

Both Macs sleep, and a sleeping backend is the most likely cause of `m1-*` or
unprefixed models failing. Two halves to this: recovery and prevention.

### Recovery — wake it from here

```bash
./wake-macs.sh          # wake any backend that is not responding
./wake-macs.sh m4       # just the M4
```

Both Macs have "Wake for network access" enabled, so a Wake-on-LAN magic packet
brings them back. Verified on the M4: asleep ~30 minutes with every TCP port
closed, awake and serving on the first poll after the packet.

### Prevention — must be done ON each Mac

This cannot be configured from the Linux box. On the Mac itself:

```bash
# never sleep while on the power adapter
sudo pmset -c sleep 0

# kernel-level sleep veto (persists until cleared or reboot)
sudo pmset -a disablesleep 1

# confirm it took
pmset -g | grep -i sleepdisabled     # expect: SleepDisabled  1

# to undo later
sudo pmset -a disablesleep 0
```

Scoped to a single session instead, no sudo, ends when you Ctrl-C it:

```bash
caffeinate -is ollama serve
```

**The lid is the catch.** On Apple Silicon from macOS Ventura onward, closing
the lid triggers a hardware magnet check that forces sleep — and *neither*
`pmset disablesleep` *nor* `caffeinate` overrides it. The only supported ways to
run with the lid shut are clamshell mode (external display + keyboard + power)
or simply leaving the lid open.

So for an always-available Ollama box: plugged into power, lid open (or full
clamshell), `pmset -c sleep 0`. Keep `wake-macs.sh` as the fallback for when it
sleeps anyway.

Note that `disablesleep 1` persists until cleared or you reboot — a laptop left
that way will not sleep overnight either.
