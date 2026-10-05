# platforms/proxmox — folder structure

One platform, four phases, organized as numbered scripts under one `scripts/` directory — not
separate sibling platforms per phase. A lab owner runs `./uis platform init proxmox` → `up` once;
everything below is what that one command actually does, broken into pieces small enough to
debug individually.

✅ = exists today. 🔲 = planned, not yet written — tracked in this repo's own plan docs, not here.

```
platforms/proxmox/
├── config.sh-template          ✅  one config for the whole platform: host1/2/3 names+addresses,
│                                    k3s sizing, CORE_SERVICES list — everything in one file
├── README.md                    ✅  "Before you start" + all phases + troubleshooting (colocated
│                                    with the code deliberately, not split into a separate docs tree)
├── STRUCTURE.md                 ✅  this file
│
├── scripts/
│   ├── 00-storage-ensure.sh     ✅  Phase 2: per-host SSH key install (one password, once) +
│   │                                 ZFS pool creation (typed "YES" to confirm the disk)
│   ├── 01-cluster-join.sh       ✅  Phase 3: preflight checks → interactive `pvecm add` (still
│   │                                 genuinely manual — root-password auth, no wrapper removes
│   │                                 that) → verify, chained into one script call
│   ├── 02-k3s-preflight.sh      ✅  Phase 4a: verify hosts reachable/clustered/storage present
│   ├── 03-k3s-apply.sh          ✅  Phase 4b: create 6 VMs, form both k3s clusters
│   ├── 04-k3s-post-apply.sh     ✅  Phase 4c: kubeconfig + Traefik + switch UIS target
│   ├── 05-core-services-apply.sh ✅ Phase 5: fencing/watchdog check once, then per service in
│   │                                 CORE_SERVICES: guest → install → health check → replicate
│   │                                 to both other nodes → register under the flat HA rule, then
│   │                                 two CONDITIONAL k3s-wiring steps (registry → registries.yaml
│   │                                 on every node; bao → ESO + ClusterSecretStore per cluster) —
│   │                                 each runs only if its service was actually selected
│   ├── 06-destroy.sh            ✅  tear down the 6 k3s VMs (core services are not torn down by
│   │                                 this — a lab owner's databases/secrets are not something
│   │                                 `down`/`destroy` should ever delete silently)
│   ├── generate-ansible-config.sh ✅  also generates vars/core-services/*.yml + secrets now
│   ├── init.sh                  ✅  interactive wizard → config.sh
│   ├── up.sh                    ✅  chains all 5 numbered build steps in one unbroken run
│   ├── down.sh                  ✅
│   └── status.sh                ✅

(no platform-local `.gitignore` — `config.sh` and `ansible/generated/` are covered by entries in
 the repo root's own `.gitignore`, fixed 2026-10-05 to match the rename)
│
└── ansible/
    ├── ansible.cfg               ✅  (`roles_path = roles` — needed because roles/ sits beside
    │                                  playbooks/, not nested under it)
    ├── playbooks/
    │   ├── storage-ensure.yml   ✅  heavy lifting for 00 — the actual zpool/zfs/pvesm commands
    │   ├── cluster-join.yml     ✅  heavy lifting for 01 — ported + generalized from the
    │   │                            maintainer's private-lab original (preflight/pause/verify
    │   │                            split, the two real `pvecm add` gotchas documented in-line)
    │   │                            ⚠️ both this file and storage-ensure.yml originally used
    │   │                            `ansible.posix.authorized_key`. Found running this platform
    │   │                            for real inside the actual `uis-provision-host` image
    │   │                            (2026-10-05): that collection isn't installed there — it
    │   │                            only worked when run directly on ops's own separate ansible
    │   │                            environment. Replaced with a plain `ansible.builtin.lineinfile`
    │   │                            so no new collection is required to run this platform.
    │   ├── vm-ensure.yml         ✅  existing — creates a Proxmox guest from a declaration
    │   ├── k3s-ensure.yml        ✅  existing — installs/joins k3s on a VM
    │   ├── guest-ensure.yml     ✅  LXC equivalent of vm-ensure.yml, for core services
    │   ├── service-pg.yml       ✅  install/configure PostgreSQL
    │   ├── service-bao.yml      ✅  install/configure OpenBao
    │   ├── service-garage.yml  ✅  install/configure Garage (S3-compatible object store)
    │   ├── service-registry.yml ✅  install/configure zot — ONE pull-through cache instance
    │   │                            fronting every upstream (docker.io, registry.k8s.io, ghcr.io,
    │   │                            quay.io), swapped from four separate `registry:2` containers
    │   │                            on 2026-10-05 (see roles/registry/defaults/main.yml for why)
    │   ├── service-nas.yml     ✅  install/configure Samba — **guest-owned volumes only, never
    │   │                            a host bind mount** (a bind-mounted guest cannot be
    │   │                            replicated by Proxmox at all, found the expensive way)
    │   ├── replication-ensure.yml ✅  idempotent `pvesr create-local-job`, one guest → both
    │   │                              other nodes
    │   │                              ⚠️ DESTROYING A GUEST DOES NOT CLEAN UP WHAT IT ALREADY
    │   │                              REPLICATED. `pct destroy --purge` only purges the SOURCE
    │   │                              node's dataset; the ZFS copies already pushed to the other
    │   │                              two nodes (`tank/vm/subvol-<vmid>-disk-*` there) are
    │   │                              orphaned, not removed. Rebuild that same VMID and the new
    │   │                              guest's replication job fails with "No common base
    │   │                              snapshot" — the stale copy on the target has no shared
    │   │                              history with the brand-new dataset. Found running this for
    │   │                              real on 2026-10-05 after destroying+rebuilding garage (407)
    │   │                              and registry (409) twice in one session: `pvesr status`
    │   │                              showed jobs stuck in `pending`/error 5, and
    │   │                              `journalctl -u pvescheduler` gave the exact cause and fix
    │   │                              Proxmox itself suggests. **Fix:** on each OTHER node (not
    │   │                              the one you rebuilt), `zfs destroy -r tank/vm/subvol-<vmid>-
    │   │                              disk-N` for every disk of that VMID, after confirming no
    │   │                              `pct config <vmid>` exists there (i.e. it's a replication
    │   │                              target copy, not a live guest) — then `pvesr schedule-now
    │   │                              <jobid>` to force a fresh full sync. This is an operational
    │   │                              gotcha of Proxmox's own replication model, not a bug in any
    │   │                              playbook here — nothing in this platform's code needs to
    │   │                              change, but whoever rebuilds a core-services guest by hand
    │   │                              (destroy + let the orchestrator recreate it) needs to know
    │   │                              this, or replication silently sits broken until someone
    │   │                              checks `pvesr status`.
    │   └── ha-ensure.yml        ✅  `ha-manager add ct:<id>` per guest, then one flat
    │                                 `node-affinity` rule naming every node with no priority
    │                                 (every node an equal failover target). ⚠️ This Proxmox
    │                                 version (9.2) has migrated the older "HA groups" mechanism
    │                                 to "rules" — `ha-manager groupadd` no longer exists
    │                                 ("ha groups have been migrated to rules"). Found running
    │                                 this for real; check `ha-manager rules add --help` on a
    │                                 newer release if this drifts again.
    │   ├── k3s-registry-ensure.yml ✅ wires every k3s node (both clusters) to the registry
    │   │                            cache's `registries.yaml` — runs ONLY when
    │   │                            05-core-services-apply.sh resolved a registry guest IP, i.e.
    │   │                            only when "registry" is in CORE_SERVICES. ⚠️ A RESTART IS
    │   │                            REQUIRED — verified for real: writing registries.yaml and
    │   │                            waiting does NOT regenerate containerd's certs.d/ on its
    │   │                            own on this k3s version. Registry port/upstream→path mapping
    │   │                            read from roles/registry/defaults/main.yml, not duplicated.
    │   └── k3s-bao-ensure.yml   ✅  wires ESO + a `ClusterSecretStore` named "openbao" to bao,
    │                                 per k3s cluster — same conditional shape, runs only when
    │                                 "bao" is in CORE_SERVICES. bao's contract isn't an address
    │                                 (see roles/bao's own comments and the openbao investigation
    │                                 this platform fed findings back into): the auth is
    │                                 BIDIRECTIONAL — the cluster calls bao for secrets, bao calls
    │                                 BACK into the cluster's TokenReview API, so each cluster gets
    │                                 its own `kubernetes-<context>` auth mount on the shared bao
    │                                 (Vault/OpenBao's auth config is per-mount, not per-role — two
    │                                 clusters cannot share one). The root token never leaves the
    │                                 bao guest. Proven end to end, not just "objects exist": a
    │                                 real secret written in bao's KV reaches a real k8s Secret
    │                                 with the correct value, verified independently afterward.
    ├── roles/
    │   ├── k3s/                  ✅  existing
    │   ├── postgres/             ✅  ported from the maintainer's private lab. Two real bugs
    │   │                            found running this against a genuinely fresh guest
    │   │                            (2026-10-05): `locale_gen` generates a locale but does not
    │   │                            set it as the system default — `pg_createcluster`'s
    │   │                            non-interactive postinst reads `/etc/default/locale`, not
    │   │                            `locale -a`, fixed with an explicit `update-locale` call;
    │   │                            and `community.postgresql.postgresql_ext`'s database
    │   │                            parameter is `login_db` on the installed collection
    │   │                            version, not `db` — the latter fails with "missing required
    │   │                            arguments: login_db" rather than silently doing nothing.
    │   ├── bao/                 ✅
    │   ├── garage/               ✅  real bug found running this for real: the docker
    │   │                            save/load bootstrap order was backwards (tried to save an
    │   │                            image before ever pulling or loading one — "reference does
    │   │                            not exist" on a genuinely fresh guest). Fixed to match
    │   │                            registry's already-correct check → load-from-seed → pull →
    │   │                            save-last order.
    │   ├── registry/            ✅
    │   └── nas/                 ✅
    └── generated/                 ✅  gitignored — inventory.yml, vars/vms/*.yml, and
                                        vars/core-services/*.yml (one guest/service declaration
                                        per configured service, plus a gitignored _extra-vars.yml
                                        for secrets/site-data — garage's credentials, nas's
                                        default share), all built fresh from config.sh on every
                                        run by generate-ansible-config.sh. No bind mounts, ever,
                                        in any of these.
```

## Why numbering starts at 00

This platform originally shipped (`#532`/`#533`) with only the k3s phase (then `02`/`03`/`04` in
this numbering), on the understanding that storage setup and cluster formation were manual
prerequisites documented in prose in README.md's "Before you start." Both are now written and
verified against a real 3-node lab: `00-storage-ensure.sh` (idempotent, `changed=0` on a clean
re-run) and `01-cluster-join.sh` (the already-clustered guard and the verify path both confirmed
for real; the actual live `pvecm add` join itself wasn't re-tested — doing so would mean
un-joining our own production cluster first, too disruptive just to prove it, and the underlying
mechanism already has a real track record: `PLAN-storage-cluster-001-formation.md` used an earlier
version of this exact playbook to join `odin` for real). `up.sh` chains both automatically now
(storage-ensure fully safe by default, cluster-join idempotent — skips cleanly if already
clustered), and continues to the k3s phase in one unbroken run when there's nothing left to do.

## Why one platform, not three

Storage setup, cluster join, k3s, and core services are all phases of reaching the same target —
a working, protected lab on 3 Proxmox machines — not independently useful destinations on their
own. A lab owner never wants "just cluster join" or "just core services" as a standalone thing to
target with `./uis platform init`; splitting them into sibling platforms would just mean more
`config.sh` files describing the same 3 machines. One platform, numbered phases internally, matches
the convention `azure-aks` and `rancher-desktop` already use — name the substrate, not an
implementation detail of how it got built.
