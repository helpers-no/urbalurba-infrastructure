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

⚠️ **Sibling, recorded not fixed:** `provision-host-03-net.sh:89` makes the
same unauthenticated call for `cloudflared`. It is **not** run during the
container build — the build runs 00, 01, 02 and 04 — so it cannot turn the
build red. It can still fail a user's network setup against a rate limit.
Deliberately left while the build was down rather than expanding a red-build
fix; it is the next thing this plan should take.


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
| `helm` | install script | ❌ none |
| `k9s` | 🔴 **`releases/latest`, resolved at build time** (`provision-host-02-kubetools.sh:231`) | ❌ none |
| `oras` | ✅ pinned `1.3.4` | ✅ upstream `checksums.txt` |
| `yq` | ✅ pinned `v4.44.1` — **in `Dockerfile.uis-provision-host`, not this script** | ❌ none |

⚠️ **Corrected 2026-09-09**: an earlier draft of this plan implied nothing was
pinned. `yq` is, and it lives in the Dockerfile rather than
`provision-host-02-kubetools.sh` — so a scope that says "this script" misses it.
The static test in 1.4 must cover **both** places, or it will pass while the
Dockerfile's `wget` stays unverified.

`grep -rniE 'sha256sum|shasum|checksum'` across `provision-host/*.sh` returns
**nothing** but the `oras` block added today.

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
