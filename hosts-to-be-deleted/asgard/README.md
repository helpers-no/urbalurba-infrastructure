# `.uis.extend` content for the Odin / asgard deployment

These are the manifests that live on the management host (`ops`, CT 103) at
`~/uis/.uis.extend/` and are applied to the `asgard` cluster. They are the glue
that UIS itself does not provide — the "components beside the cluster" gap.

**They are committed here for version control and recovery, not for deployment.**
The authoritative copies are the ones on `ops`; `uis` reads that directory
directly. If you change something here, copy it there and apply it — and if you
change it there, copy it back.

| File | What it does |
|---|---|
| `pg-external-proxy.yaml` | Makes the external PostgreSQL on `pg` look like an in-cluster service. Two containers: a `psql` container first (so UIS playbooks that `kubectl exec` into "the postgres pod" work) and a socat proxy |
| `minio-external-proxy.yaml` | Same shim pattern for the external MinIO |
| `storageclasses.yaml` | `fast` / `standard` classes over proxmox-csi and NFS |
| `csi-config.yaml`, `csi-values.yaml` | proxmox-csi-plugin. ⚠️ **The `token_secret` is REDACTED here.** The real Proxmox API token must come from OpenBao — never commit it |
| `eso-store.yaml` | External Secrets `ClusterSecretStore` pointing at OpenBao |
| `bao-reviewer.yaml` | ServiceAccount + token used by OpenBao's Kubernetes auth |
| `tailnet-ingress.yaml` | Tailnet-only Ingresses (Temporal, MinIO console, LiteLLM). No Funnel — these must not be internet-facing |
| `litellm-models.yaml` | The LiteLLM model list. Clients call capability names; machine-pinned `m1-*`/`m4-*` names are internal fallback targets |
| `ollama-backends.yaml` | Selector-less Services + Endpoints for the two Macs |
| `ollama-endpoint-manager.yaml` | Health controller: probes each Mac every 60s, repoints Endpoints LAN-first then Tailscale, and **clears them when nothing answers** so failures are instant rather than hanging |
| `authentik-ts.yaml`, `grafana-ts.yaml` | Individual tailnet Ingresses |

## Order matters in one place

`litellm-models.yaml` must be applied **before** `uis deploy litellm`. The
playbook only creates its default ConfigMap when none exists, and that default
points at `host.docker.internal`, which does not resolve on a real k3s node.

## Credentials

Nothing in this directory should contain a secret literal. The Proxmox CSI token
was found in plaintext on 2026-08-07 and redacted before committing; it belongs
in OpenBao and should be rotated.
