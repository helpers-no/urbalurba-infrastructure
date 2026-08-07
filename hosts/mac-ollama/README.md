# Mac Ollama backends — operational notes

Rescued from the iMac on 2026-08-07, the day after its root filesystem failed.
These existed nowhere else and are not reproducible from the rest of the repo.

| File | Why it is kept |
|---|---|
| `wake-macs.sh` | Wake-on-LAN for the two Macs. Still needed: the M4 sleeps in 9–16 minute cycles and a sleeping Mac answers ICMP while every TCP port is closed, so `ping` is not a liveness check |
| `README-cpu-limitation.md` | Why pgvector cannot run on the 2011 iMac: no AVX2/FMA, and a SIGILL in a distance operator kills the **postmaster**, not just the query — taking down every database on that instance |
| `mac-ollama-design.md` | The selector-less Service + hand-managed Endpoints pattern, so a backend address change is a one-file edit with no LiteLLM restart |

## Deliberately not rescued

- `M1-LITELLM-SETUP.md` — points at the dead iMac gateway and contains its API
  key in plaintext. Superseded; not committed
- `00/01/02/03-*.yaml` — superseded by `hosts/asgard/ollama-backends.yaml` and
  `hosts/asgard/litellm-models.yaml`
- `patch-openwebui-vectordb.sh` — a workaround for a machine that no longer runs
