# Plan: pin and verify the binaries the image installs

## 🔴 The argument changed on 2026-09-10: an unpinned binary made the build red

This plan was written about **drift** — an unpinned tool silently becoming a
different tool. That is real, and it is the weaker half.

`install_k9s` asked `api.github.com` for the latest release. That call is
**unauthenticated and rate-limited to 60/hour per IP**, and both architecture
builds run concurrently from the same GitHub Actions runner. On 1.6.41 amd64
got an answer and arm64 did not: `LATEST_VERSION` came back empty, the function
returned 1, and **the whole image build failed on a commit that touched two
Ansible playbooks and nothing else.**

⚠️ So the cost of not pinning is not only "you might get a different binary".
It is **a build that fails against somebody else's rate limit, on a change
unrelated to the binary** — and it blocked a tester who had been told to wait
for that image. Pinned in 1.6.42 with upstream checksums, no API call.

## 🔴 And a third failure mode, worse than both — imac, 2026-09-10

An unpinned network dependency can **silently substitute a different artifact
and report success**. imac hit this on their own machine within the hour, on a
different tool, while I was fixing the k9s one:

```
10:20:41.259Z  updateCache: error: Error: net::ERR_CONNECTION_RESET
10:21:12.924Z  Ensuring images available for K3s 1.25.16
```

`rdctl start --kubernetes.version 1.36.3` was **accepted**, settings showed
`1.36.3`, the version-list fetch failed one second later, and Rancher Desktop
fell back to its bundled default and built a **1.25.16** cluster — eleven minor
versions behind what was asked for. **`rdctl start` exited 0.**

The three modes, which is the useful form of this plan's argument:

| | k9s (ours) | `updateCache` (imac's) | `update.k3s.io` (imac's, #646) |
|---|---|---|---|
| trigger | unauthenticated API, rate-limited | version-list fetch, connection reset | endpoint **up** and serving an **invalid TLS certificate** |
| duration | until the window resets | seconds | 🔴 **hours, and counting** |
| result | **build red** | **wrong version, exit 0** | **wrong version, exit 0** |
| who notices | immediately, CI | **nobody**, unless something asserts | **nobody**, unless something asserts |
| does a retry help | yes | yes | 🔴 **no** |

⚠️ **The fourth trigger is the one that limits this plan's reach, so it belongs
here rather than in a footnote.** On 2026-09-10 `update.k3s.io` served a Traefik
default certificate *to the whole world* — confirmed from a network path outside
the house entirely, and `ops` eliminated every Traefik on our own network by
certificate serial. Rancher Desktop's version-list fetch failed, it fell back to
its bundled default, and `rdctl start` exited 0 having built **1.25.16** instead
of the pinned **1.36.3** (imac, `urb-agents#646`, #641).

🔴 **Nothing in this plan would have prevented it.** The unpinned fetch was
*Rancher Desktop's*, not ours. Pinning every artifact UIS downloads does not
help when a tool UIS depends on does its own unpinned fetch from a third party
that is up and lying. What saved imac was the **assertion**, not any pin: their
reset script compared the running version against the requested one and refused
to bless the environment.

**So the plan's own conclusion sharpens.** Pinning is the cheaper half and the
one we control. **The half that actually catches the silent case is asserting
that what arrived is what was asked for** — and that half works regardless of
whose fetch broke. Where a pin is impossible, the assertion is not optional.

🔴 **The fix differs for the silent case.** Pinning helps, but what makes the
failure *visible* is an assertion downstream that compares what you got against
what you asked for. imac only caught it because of a phase-5 check comparing
the running node version to the requested one — which exists because of an
earlier disk-size-poisoning bug on the same script where rejected flags also
produced `exit 0`.

**So this plan gains a second half:** pin the fetch, *and* assert the result.
Every place UIS installs a versioned tool should end by checking the installed
version equals the pinned one — `install_oras` and now `install_k9s` both
report a version, but neither compares it to the constant it was told to
install.

⚠️ **Sibling, recorded not fixed:** `provision-host-03-net.sh:89` makes the
same unauthenticated call for `cloudflared`. It is **not** run during the
container build — the build runs 00, 01, 02 and 04 — so it cannot turn the
build red. Deliberately left while the build was down rather than expanding a
red-build fix; it is the next thing this plan should take.

⚠️ **By the table above it is the SILENT kind, not the loud one.** A rate-limited
`cloudflared` lookup gives a user a broken network setup and no red build —
which makes it more dangerous than the k9s case, not less, and means the fix
needs the assertion as well as the pin. imac has offered to exercise it with a
factory reset plus `uis network up cloudflare` when we get to it.


> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: Every binary `uis-provision-host` installs is pinned to an exact version
and verified against a checksum the upstream project published, so two builds of
the same commit produce the same image.

**Found**: 2026-09-09, while adding `oras` for the application catalogue
(`urb-agents#361`). Terje's answer to "match the surrounding style or pin it?" was
**pin it** — which leaves `oras` correct and its three neighbours not.

**Related**: [INVESTIGATE-system-version-pinning](./INVESTIGATE-system-version-pinning.md)
— the same argument one layer down. That investigation exists because 16
Helm-based services took whatever the chart repo served that day; this is the
same defect in binaries baked into the product image.
[PLAN-ci-third-party-download-fails-the-whole-image-build](./PLAN-ci-third-party-download-fails-the-whole-image-build.md)
is its failure mode.

---

## What is true today

| tool | version | checksum |
|---|---|---|
| `kubectl` | fetched from `k8s.io` | ❌ none |
| `helm` | 🔴 install script fetched from **`main`** and **piped into `bash`** — `provision-host-04-helmrepo.sh:47,64` | ❌ none |
| `cloudflared` | 🔴 **`api.github.com/.../releases/latest`** (`provision-host-03-net.sh:89`) — the exact call removed from the k9s path on 2026-09-10, still live here | ❌ none |
| `k9s` | ✅ pinned `v0.51.0` — the `releases/latest` call is **deleted** (1.6.45) | ✅ per-arch `sha256` from upstream `checksums.txt` |
| `oras` | ✅ pinned `1.3.4` | ✅ upstream `checksums.txt` |
| `yq` | ✅ pinned `v4.44.1` — **in `Dockerfile.uis-provision-host`, not this script** | ❌ none |

⚠️ **Table filled in 2026-09-10.** Two rows were thinner than the plan's own
prose: `cloudflared` was discussed in detail above but absent from the
inventory, and `helm` was described only as "install script" — task 1.2 already
knew it "resolves its own version". **What was genuinely missing anywhere is the
shape of the helm fetch**: the script comes from **`main`**, a moving branch, and
is piped straight into `bash` at two sites. That is arbitrary code execution from
a third party's default branch, which is a stronger statement than "unpinned".

🔴 **And I nearly wrote that this plan had missed `cloudflared` entirely.** It
had not; I had read the table and not the two paragraphs above it. Recording the
near-miss because it is the third time today I have started to assert something
about a document from a partial read of it — the failure `ops-dev` named as
*"two readings both available, and I took the one reachable from where I was
standing."*

⚠️ **Corrected 2026-09-09**: an earlier draft of this plan implied nothing was
pinned. `yq` is, and it lives in the Dockerfile rather than
`provision-host-02-kubetools.sh` — so a scope that says "this script" misses it.
The static test in 1.4 must cover **both** places, or it will pass while the
Dockerfile's `wget` stays unverified.

⚠️ **And the `k9s` row was stale in the other direction** — it still described
the defect that was fixed the same day it was written. A table that is wrong
about what is *already done* costs the next reader a duplicate fix, which is
the mirror of the rows that were wrong about what is *not* done.

`grep -rniE 'sha256sum|shasum|checksum'` across `provision-host/*.sh` now
returns the `oras` and `k9s` blocks. **Three of six rows remain unverified:**
`kubectl`, `helm` and `cloudflared`.

## Why it matters, in the order the arguments actually bite

1. **The image is not reproducible.** `k9s` resolves `latest` *during the build*, so
   the same commit built twice can ship different tools. Every "works on my
   provision host" comparison is weaker than it looks, and `./uis version`
   identifies the image but not what is in it.
2. **An unverified download is a supply-chain gap in a privileged container.** The
   provision host runs `--privileged --network host` with cluster credentials
   mounted. A substituted binary there is not a small problem.
3. ⚠️ **It is a plausible contributor to the flake.** All three instances of
   `PLAN-ci-third-party-download-fails-the-whole-image-build` were in this one
   script, and one of them was a GitHub *API* call away from the failure I
   diagnosed as an Ubuntu mirror. A pinned URL removes an API round trip per
   build; it does not remove the network, but it removes a moving part.

## What this is not

**Not a rewrite.** The `oras` block added today is the shape: a version constant,
a per-architecture checksum constant, refuse-on-mismatch, and a comment saying
where to get the sums when bumping. Three tools to bring to it.

⚠️ **And not "compute the sum once and paste it".** A sum computed from what a
build happened to receive attests to nothing. Each must come from the project's
own published checksums file — `oras` publishes `oras_<v>_checksums.txt`,
`kubectl` publishes `<binary>.sha256`, `helm` publishes a checksum per release
asset. If a tool publishes none, that is worth saying out loud in the comment
rather than inventing one.

## Tasks

- [ ] 1.1 `kubectl` — pin the version, verify against `dl.k8s.io/.../kubectl.sha256`
- [ ] 1.2 `helm` — pin the version and verify. ⚠️ It currently uses the upstream
      *install script*, which resolves its own version; pinning means either
      passing `--version` **and** verifying the script itself, or fetching the
      release tarball directly. The second is simpler and matches the others
- [ ] 1.3 `k9s` — pin the version, verify, and **delete the `releases/latest` API
      call**. Note in the comment that unpinning it was how the image stopped
      being reproducible
- [ ] 1.4 A static test asserting every download in `provision-host/*.sh` is
      followed by a checksum comparison. ⚠️ **The signature is the point**: this
      is the one part a lint can see, and the convention already drifted once
      because nothing checked it
- [ ] 1.5 A documented bump procedure: where each project publishes its sums, so
      bumping is mechanical rather than research
- [ ] 1.6 Version bump; `provision-host/**` ships, so the guard requires it

## Acceptance

- no download in `provision-host/*.sh` is unverified
- no tool resolves its own version at build time
- the static test fails if either regresses
- two builds of the same commit install the same tool versions — which cannot be
  asserted in CI, so it is stated as the property the change buys rather than as
  a test

## Out of scope

- the `apt` layer. Pinning distribution packages is a different problem with a
  different answer (a snapshot mirror), and the third flake instance was `apt`
  rather than a release download — so this plan does **not** claim to fix that
  flake, only to remove one moving part from its neighbourhood.
