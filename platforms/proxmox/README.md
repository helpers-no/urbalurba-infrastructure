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

## Before you start

Only one thing is a genuine, out-of-scope prerequisite. Everything else is scripted:

1. **Proxmox is installed on all three machines.** Out of scope here — that's the Proxmox
   installer's own job (write the ISO, boot it, pick the small disk for Proxmox itself). Any
   current Proxmox major version works; all three should match each other. No tool here installs
   an OS onto hardware that doesn't have one yet.

That's it. `./scripts/00-storage-ensure.sh --create-pool` and `./uis platform up proxmox` handle
the rest — including the two steps that used to be hand-typed `zpool`/`pvecm` commands:

- **ZFS pool/storage.** `./scripts/00-storage-ensure.sh --create-pool` auto-detects a candidate
  disk per host, shows you exactly which one, and asks for a typed `YES` before touching anything
  — it never proceeds on an assumption. ⚠️ **Destructive** on whatever disk it finds; run this
  once per fresh lab, by hand, before the first `up` — `up.sh` itself only ever runs this same
  script's non-destructive bootstrap/verify mode (step 1/7), never `--create-pool`. `PROXMOX_STORAGE`
  in `config.sh` must match the storage name it registers (`tank-vm` by default).
- **Proxmox clustering.** `./uis platform up proxmox` drives this itself (step 2/7,
  `01-cluster-join.sh`): `pvecm create` on the first host (fully automated, local-only, no remote
  auth needed) and `pvecm add` for the other two, held open on an interactive pty just for the one
  moment that genuinely needs a human. 🔴 **This is the one step in the whole chain that cannot be
  automated away** — `pvecm add` authenticates over the Proxmox API with the *target's* root
  password, typed interactively. No SSH key, no amount of automation, removes that; it's not a gap
  in this platform, it's how Proxmox clustering works. When prompted:
  - type that host's root password
  - type the literal word `yes` at the fingerprint prompt, not just `y` (a bare `y` fails it and
    costs a full re-run)

  `PROXMOX_CLUSTER_NAME` in `config.sh` should match whatever cluster name you configured — it's
  passed to `pvecm create` automatically. The step is idempotent: a warm re-run against an
  already-clustered lab checks quorum and skips cleanly.

So the real sequence for a fresh lab is: `./uis platform init proxmox` (wizard) →
`./scripts/00-storage-ensure.sh --create-pool` (once, destructive, asks for confirmation) →
`./uis platform up proxmox` (prompts you for each target's root password when it reaches
cluster-join, then takes it the rest of the way).

---

## Quickstart

```bash
./uis platform init proxmox     # wizard: your 3 machines' names/addresses
# review .uis.secrets/platforms/proxmox/config.sh — especially the six VMs' addresses/sizing/VMIDs,
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

## Lab extras — opt-in guests, not a UIS default

`CORE_SERVICES` (pg/bao/garage/registry/forgejo/pg-test) ships as the reference lab's own real
configuration — a fresh lab owner running `init` gets our proven settings, not a blank slate.
**Lab extras are the opposite**: guests judged genuinely useful to SOME labs but not assumed as a
UIS default. `LAB_EXTRAS` is empty by default; nothing here gets built unless you deliberately add
it with `uis platform lab-extra add proxmox <name>` (same add-one-at-a-time mechanism
`core-service add` uses, kept as a visibly separate list/script pair on purpose — see
`config.sh-template`'s own "Lab extras" section and urb-agents#1970/#1971/#1972).

Why this is a separate thing at all, rather than a 7th `CORE_SERVICES` entry: a `nas` role (Samba)
once lived in this platform the same way pg/bao/garage/registry do, generalized from the
maintainer's own private lab — and was removed outright on 2026-10-05 (see `STRUCTURE.md`'s own
"nas — deliberately not part of this platform" note) because it wasn't judged worth maintaining as
generic IaC for every lab owner. All three guests below are the same kind of lab-specific guest by
that same test — the difference is Terje's own explicit call to build them in anyway (dns-resolver
first, `nas` once that mechanism existed and proved out, `forgejo-runner` once it was clear
`vm-ensure.yml` already generalized far enough to carry a VM-kind guest too), as guests a lab owner
can opt into, rather than leave entirely outside provision-host. The opt-in-ness needs to be
visible, not just technically true, which is why none of them is just another `CORE_SERVICES` case
arm.

### dns-resolver

A dnsmasq-based LAN resolver. Generates a hosts-zone from every guest THIS platform itself
declares — the 3 Proxmox hosts, the 6 k3s VMs, and every configured `CORE_SERVICES`/lab-extras
guest (including itself) — so every name in the zone is something this platform actually built and
knows the address of, never a wider or stale inventory. Tier-0: its guest declaration sets
`startup: order=0`, so Proxmox itself boots it before everything else (including `registry`'s
`order=1`) — the same native mechanism every `CORE_SERVICES` guest's own `startup=` already uses,
no new orchestration needed.

```
./uis platform lab-extra add proxmox dns-resolver
```

**Nothing is repointed at it automatically.** Every k3s VM and `CORE_SERVICES` guest keeps using
`NETWORK_DNS` (normally your router) unless you deliberately change it afterward — repointing
consumers one at a time is a separate, later decision this first build doesn't make for you.

**The one deliberate exception to "never default a real firewall allow-list"**: every other guest
here leaves its nftables allow-list empty until you explicitly declare one (an empty default is the
safe choice for most of them — see urb-agents#1944). This guest's whole purpose is "every machine
on the LAN queries it", so `generate-ansible-config.sh` defaults its allow-range to
`CORE_SERVICES_LAN_CIDR` (the same "whole LAN" value `pg`/`pg-test` already reuse) unless you
override `LAB_EXTRA_DNS_RESOLVER_FIREWALL_ALLOW_RANGES` in `config.sh` yourself.

**VMID default is 400, not 410** — the reference lab's own real dns-resolver guest happens to run
at 410, but this template's own `CORE_SERVICE_FORGEJO_VMID` already defaults to 410 too (see
urb-agents#1940's override note in `config.sh-template`) — defaulting both to the same number would
collide for a fresh lab owner who enables both. Override `LAB_EXTRA_DNS_RESOLVER_VMID` if you're
adopting a real dns-resolver guest already at a different VMID (410 is the common case for that).

### nas

A Samba file server. Shares are **Proxmox-managed storage volumes** (`mp0`/`mp1`/...), deliberately
NOT host bind mounts: `pvesr` cannot replicate a bind mount ("unable to replicate mountpoint type
'bind'"), so a bind-mounted share's data would not follow this guest on HA failover — as a real
Proxmox volume, the service and its data move together. This is the one real structural change from
the reference role; everything else about it (package install, firewall, verification) ported as-is.

```
./uis platform lab-extra add proxmox nas
```

**Who your people are and what you call your shares is deliberately NOT in `config.sh`.** The role
ships no accounts and no shares — same discipline that got the original `nas` role removed from
this platform once already (a role that ships *this* lab's human/agent identities and share names
is wrong everywhere except where it was written, same mistake as hardcoding an IP in a role
default). Supply your own via
`platforms/proxmox/lab-extras-site-data/nas-site-data.yml-template`, copied to
`.uis.secrets/platforms/proxmox/lab-extras/nas-site-data.yml` (git-ignored, persistent, never
regenerated — same shape `config.sh` itself already is) — `09-lab-extras-apply.sh` passes it to
the role automatically if present, and the role refuses to proceed with a clear message if it's
missing or empty.

**Samba passwords are never in any file here, ever** — set one per account after the guest is up:
`ssh <nas guest IP> smbpasswd -a <user>`. A password in a declaration is a password in git, gitignored
or not.

**`LAB_EXTRA_NAS_SHARE_MOUNTS`** is `"path:size_gb"` pairs, comma-separated — one Proxmox volume
per declared share. The default is a single `/srv/shared:50`; the reference lab's own second share
is deliberately guest-writable with **no authentication at all** (Terje, 2026-10-01: "the LAN is
trusted") and is not something a generic default should hand a fresh lab owner — add a second pair
here, and a matching `nas_shares` entry in your site-data file, if you want one.

**VMID default is 404**, matching the reference lab's own real nas guest — unlike dns-resolver's
400-not-410, nothing else in this template already claims 404, so there's no collision to design
around here.

### forgejo-runner

A Forgejo Actions CI runner — the first lab extra that's a **QEMU VM, not an LXC**. It runs
Docker, and nesting Docker-in-LXC is its own can of worms this platform has never needed to open;
a VM sidesteps it entirely. `09-lab-extras-apply.sh` branches on each declaration's own
`service.kind` to call `vm-ensure.yml` instead of `guest-ensure.yml`, and skips the
replicate/HA-register steps entirely — there's nothing worth Proxmox-HA-protecting on disposable
CI-runner compute, unlike `pg`/`bao`/`garage`/`nas`'s own real data (urb-agents#1982, F5 of
`INVESTIGATE-host-provision-host-adoption.md`).

```
./uis platform lab-extra add proxmox forgejo-runner
```

**Requires `forgejo` in `CORE_SERVICES` first** — a runner with no Forgejo instance to register
against is useless. Unlike dns-resolver/nas, which both stand alone, this is the first lab extra
with a real dependency on another opt-in piece; `generate-ansible-config.sh` refuses loudly at
generation time if `forgejo-runner` is in `LAB_EXTRAS` without `forgejo` also selected. Run `uis
platform core-service add proxmox forgejo` first if you haven't already.

**Docker-in-Docker vs skopeo, and network isolation, were both Terje's own explicit calls, ported
as-is rather than re-litigated** (urb-agents#1926/#1982): job containers run as siblings on this
guest's own Docker daemon via the automounted host socket (not nested Docker-in-Docker — less
isolation, but no privileged container and no nested firewall concern, acceptable for a
single-tenant guest nothing else runs on), and the firewall is a **deny-list**, not an allow-list
(default-accept outbound, explicit deny of every other guest/host this platform currently knows
about — computed automatically, never hand-maintained). Both decisions, and the real bugs found
porting the reference role (a job-image Docker CLI defaulting to HTTPS against Forgejo's own
plain-HTTP registry; the Docker socket's GID not matching a hardcoded assumption), are documented
in `roles/forgejo-runner/tasks/main.yml`'s own comments.

**The registration token is the one real secret this guest needs, and it's never defaulted.**
Mint it once the `forgejo` guest is up (the binary refuses to run as root):
`ssh <forgejo guest IP> docker exec --user git forgejo forgejo actions generate-runner-token`.
Supply it via `platforms/proxmox/lab-extras-site-data/forgejo-runner-site-data.yml-template`,
copied to `.uis.secrets/platforms/proxmox/lab-extras/forgejo-runner-site-data.yml` — same
git-ignored, persistent, never-regenerated convention as `nas`'s own site-data file.

**VMID default is 411** — right after forgejo's own 410, no collision with anything else this
template defaults. Sized 4 cores/8192MB/40GB, matching the reference lab's own real guest at this
exact workload (Docker image builds), proven live — not a guess.

## What's deferred (first draft — see the PR description)

This is a Step 1 in the spirit of `platforms/azure-aks/`'s own first PR: get it genuinely working,
defer anything without a clear need yet.

- **Full `init`/`up`/`down`/`status` parity with `platforms/azure-aks/`** — the richer
  non-interactive escape hatches, the full C-1 state-machine edge cases, are not all implemented.
  The golden path (a human running these commands from a real terminal) is what's been verified.
- **Storage-class aliasing**: not included, on the theory that a plain k3s cluster's bundled
  `local-path` provisioner needs no alias (the same theory `rancher-desktop`, also plain k3s,
  already relies on). Flag it if a UIS service's deploy surfaces a missing storage class — the fix
  would follow `platforms/azure-aks/manifests/000-storage-class-azure-alias.yaml`'s exact pattern,
  pointed at k3s's own provisioner instead of Azure's.
- **The true zero-to-hero path has not been witnessed in one continuous run.** Every
  CORE_SERVICES/LAB_EXTRAS live-verification to date (F1/F3/F4) adopted an already-running lab's
  existing guests — a real, valuable test (it's what surfaced the VMID/firewall/secrets override
  mechanisms), but structurally different from "three genuinely blank machines, storage through
  services, one continuous run, nothing pre-existing." Each individual phase (`00-storage-ensure`,
  `01-cluster-join`, k3s apply, core-services apply) has its own track record on real hardware, but
  nobody has yet run all of them back-to-back against machines that have never seen Proxmox
  clustering or a single guest before. Component-proven and adoption-proven, not yet witnessed as
  one fresh build — flagged honestly rather than implied-covered (urb-agents#1981).

## Troubleshooting

- **`02-k3s-preflight.sh` fails on SSH reachability** — the printed public key needs adding to each
  Proxmox host's `/root/.ssh/authorized_keys` by hand first.
- **`02-k3s-preflight.sh` fails on cluster membership** — `./uis platform up proxmox` (step 2/7,
  `01-cluster-join.sh`) handles this automatically now, but still needs a human at the prompt for
  each target's root password — see "Before you start" above. Run `01-cluster-join.sh` directly
  (or re-run `up`) rather than typing `pvecm` commands by hand.
- **A VM boots but SSH never answers** — check `qm status <vmid>` on that host directly; cloud-init
  can take a few minutes on first boot if it's also running a package upgrade.
- **`k3s-ensure.yml` fails waiting for the node to report Ready** — the node object can take several
  seconds to register after the systemd unit reports active; the role already retries this, but if
  it still times out, check `systemctl status k3s` on that VM directly.
