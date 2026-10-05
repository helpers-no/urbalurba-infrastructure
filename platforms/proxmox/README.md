# proxmox — a 3-machine Proxmox lab, two k3s clusters, from your own hardware

Turns three physical (or virtual) machines running Proxmox into:
- **A production k3s cluster** — one VM per host, joined as a genuine 3-node HA control plane
  (odd node count → real etcd quorum tolerance, survives any single machine going down)
- **A mirror test cluster** — a second VM per host, a fully independent k3s cluster (its own
  token, its own pod/service CIDRs) for trying a config or version change before it touches
  production

Six VMs total, two per host. Built via ansible + cloud-init (not OpenTofu — a Proxmox host isn't a
cloud API, it's a machine that already exists; see the PR description this platform shipped with
for why that's the deliberate choice for this platform shape, not an AKS-style one).

---

## Before you start — NOT scripted, read this first

Three things need to be true before `./uis platform up proxmox` can do anything:

1. **Proxmox is installed on all three machines.** Out of scope here — that's the Proxmox
   installer's own job (write the ISO, boot it, pick the small disk for Proxmox itself). Any
   current Proxmox major version works; all three should match each other.

2. **Each machine has a ZFS pool/storage, same name on every host.** Replication and guest
   mobility both match by storage *name*, so this has to be identical everywhere:
   ```bash
   # on each machine, find the stable disk identifier (never a kernel name like /dev/sdb —
   # those move between boots):
   ls /dev/disk/by-id/ | grep -v part

   zpool create -o ashift=12 tank /dev/disk/by-id/<your-disk-id>
   zfs set compression=lz4 tank
   zfs create -p tank/vm
   pvesm add zfspool tank-vm --pool tank/vm --content rootdir,images --sparse 1
   ```
   `PROXMOX_STORAGE` in `config.sh` must match whatever name you used for the `pvesm add` above
   (`tank-vm` in this example).

3. **The three machines are joined into one Proxmox cluster.** 🔴 **This is the one step that
   genuinely needs a human** — `pvecm add` authenticates over the Proxmox API with the *target's
   root password*, typed interactively. No SSH key, no amount of automation, removes that; it's not
   a gap in this platform, it's how Proxmox clustering works.
   ```bash
   # every machine needs every OTHER machine's name resolvable — this estate has no assumed DNS,
   # so add entries to /etc/hosts on EVERY machine for every OTHER machine:
   #   <addr> <name>.lan <name>

   # on the first machine (the one with the least to lose, or just pick one):
   pvecm create homelab

   # on each of the other two:
   pvecm add <first-machine's-name-or-address>
   #   - prompts for the FIRST machine's root password — type it
   #   - prompts "Are you sure you want to continue connecting (yes/no)?" — type the
   #     literal word "yes", not "y" (a bare "y" fails it and costs a full re-run)

   # verify from any machine:
   pvecm status      # expect: Quorate: Yes, 3 nodes
   ```
   `PROXMOX_CLUSTER_NAME` in `config.sh` should match whatever you passed to `pvecm create`.

Once all three are true, `./uis platform init proxmox` and `./uis platform up proxmox`
take it from there.

---

## Quickstart

```bash
./uis platform init proxmox     # wizard: your 3 machines' names/addresses
# review platforms/proxmox/config.sh — especially the six VMs' addresses/sizing/VMIDs,
# which default to template values that may collide with your own network or numbering

./uis platform up proxmox       # preflight → create 6 VMs → form both k3s clusters →
                                     # kubeconfig + Traefik → switch UIS target to production

./uis deploy nginx                  # verify: real pod scheduling, networking, ingress

./uis platform status proxmox   # both clusters' node state
./uis platform down proxmox     # destroy the 6 VMs — NOT the Proxmox cluster underneath
```

---

## Sizing — the reasoning, not just the numbers

`config.sh-template`'s defaults came from a real reference lab's measured headroom. The pattern
worth keeping even if your numbers differ:

- **Figure out which of your three machines is weakest** (fewest cores, slowest disk) and make
  that `host3`. Its k3s **production** node is control-plane-only (`K3S_VM_HOST3_CONTROL_PLANE_ONLY`)
  — it contributes its HA vote and runs no workload pods. Two reasons: it's the machine with the
  least spare capacity, and if its disk is noticeably slower than the other two, you don't want it
  becoming etcd's bottleneck by winning a raft leader election. (etcd only needs a *majority* — 2 of
  3 — to ack a write, so a slow third member doesn't throttle every write by itself; it only matters
  if *it* becomes leader. Not a blocker, just worth knowing if cluster performance ever seems
  oddly inconsistent.)
- **Figure out which has the most headroom** and let that one (`host2` in the template) carry the
  most generous VM — that's where real production workload capacity should concentrate.
- **The test cluster is deliberately uniform and minimal everywhere** (1–2 cores, 2GB) regardless
  of host strength. Its whole job is proving a change works before production sees it, not carrying
  load.
- **Every host ends up running two VMs.** Check `nproc`/`free -h` on each machine against what
  you're about to ask it to run — the six VMs are on top of whatever else that host might already be
  running.

---

## Architecture notes

- **k3s version is pinned to an exact release** (`K3S_VERSION`), not a floating channel — a channel
  resolves to whatever's current at install time, which silently makes two builds months apart
  different versions. Check the current `stable` value at
  `https://update.k3s.io/v1-release/channels` rather than trusting this template's value to still
  be current by the time you read it.
- **The join token is never written to any file.** k3s generates its own random token on the
  `--cluster-init` node; `03-k3s-apply.sh` reads it once over SSH and holds it only in the running
  script's memory for the rest of that run. Holding this token is equivalent to full node-level
  cluster access, so it's treated as a real secret throughout.
- **Test cluster CIDRs are deliberately different from production's defaults**
  (`10.52.0.0/16`/`10.53.0.0/16` vs. k3s's own `10.42.0.0/16`/`10.43.0.0/16`) — not because they'd
  collide (they wouldn't; each cluster's CNI only knows about its own nodes), purely so `ip route`
  or `kubectl` output is never ambiguous about which cluster you're looking at.
- **Traefik**: `ansible/playbooks/003-setup-traefik.yml` (the shared UIS playbook every platform
  uses) already auto-detects k3s's own bundled Traefik and skips the Helm install — the exact same
  thing it does for `rancher-desktop`, which also runs k3s. Nothing k3s-specific needed here.
- **VMIDs**: each host's production/test pair uses a `.90`/`.91`-style sub-range within whatever
  VMID numbering you already use for that host's other guests, chosen to sit past any
  currently-plausible ordinary-guest VMID so future growth there never collides with the k3s pair.

---

## What's deferred (first draft — see the PR description)

This is a Step 1 in the spirit of `platforms/azure-aks/`'s own first PR: get it genuinely working,
defer anything without a clear need yet.

- **Full `init`/`up`/`down`/`status` parity with `platforms/azure-aks/`** — the richer
  non-interactive escape hatches, the full C-1 state-machine edge cases, are not all implemented.
  The golden path (a human running these commands from a real terminal) is what's been verified.
- **The LXC-services phase** (a reference lab's basic services — a database, a secrets store,
  object storage — built as plain LXC containers alongside the k3s VMs) is NOT scripted here. It's
  independent of the k3s layer this platform's own verification bar tests, and genuinely optional
  for a lab that just wants the two k3s clusters.
- **Storage-class aliasing**: not included, on the theory that a plain k3s cluster's bundled
  `local-path` provisioner needs no alias (the same theory `rancher-desktop`, also plain k3s,
  already relies on). Flag it if a UIS service's deploy surfaces a missing storage class — the fix
  would follow `platforms/azure-aks/manifests/000-storage-class-azure-alias.yaml`'s exact pattern,
  pointed at k3s's own provisioner instead of Azure's.

## Troubleshooting

- **`02-k3s-preflight.sh` fails on SSH reachability** — the printed public key needs adding to each
  Proxmox host's `/root/.ssh/authorized_keys` by hand first.
- **`02-k3s-preflight.sh` fails on cluster membership** — see "Before you start" above; this step is
  deliberately never auto-attempted.
- **A VM boots but SSH never answers** — check `qm status <vmid>` on that host directly; cloud-init
  can take a few minutes on first boot if it's also running a package upgrade.
- **`k3s-ensure.yml` fails waiting for the node to report Ready** — the node object can take several
  seconds to register after the systemd unit reports active; the role already retries this, but if
  it still times out, check `systemctl status k3s` on that VM directly.
