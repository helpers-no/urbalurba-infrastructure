# Self-hosted GitHub Actions runner

How to stand up a Linux machine that runs this project's GitHub Actions jobs on
your own hardware instead of GitHub's.

⚠️ **This repository's own CI does not need one.** It is public, and GitHub does
not bill standard runners in public repositories — see
[the readiness plan](../../ai-developer/plans/backlog/PLAN-system-ci-self-hosted-runner-readiness.md)
for the three properties that would have to be fixed first. This guide exists
because **private** repositories are billed, and because a machine that can
build the provision-host image is useful independently of who is paying.

## Before you start: is a runner the right answer?

🔴 **A self-hosted runner is a machine that executes code from a repository.**
That is the whole point and it is also the whole risk. Three questions decide
the shape of everything below:

1. **What triggers the workflows?** A runner serving only `push` and
   `pull_request` sees code from people who can already push. A runner serving
   `issue_comment` or `issues` executes on **anything anyone can type into an
   issue**. Those are not the same machine.
2. **What credentials do the jobs hold?** A job that deploys somewhere holds a
   credential that deploys somewhere, for the length of the job, on this
   machine. Workload-identity federation (OIDC) is much better than a stored
   key — the token is short-lived and minted per job — but it still exists on
   the runner while the job runs.
3. **Does anything it builds get consumed elsewhere?** A machine that builds a
   container image other people run is a supply-chain position, not a build box.

⚠️ **If the answers put "arbitrary issue text" and "deploys to production" on
the same machine, use two machines.** No amount of RAM fixes that, and one
shared runner label silently undoes the separation however many machines exist.

## Machine

| | |
|---|---|
| form | **a VM, not a container**, if it will build images — a shared kernel is a weaker boundary, and Docker inside an unprivileged container fights `buildx` |
| OS | Debian 13 (trixie) |
| vCPU | 4 for image builds; 2 is enough for lint-and-test workflows |
| RAM | 8 GiB for image builds — and see the warning below |
| disk | 80 GB if building multi-arch images; 20 GB otherwise |
| network | outbound HTTPS; **no inbound** — the runner polls GitHub |

🔴 **If the VM has a memory balloon, pin it.** A balloon that can squeeze the
guest below its nominal RAM will OOM `buildx` part-way through a layer, and
that does not look like memory pressure — **it looks like a flaky build**, on a
machine nobody is watching, intermittently. Set minimum = maximum, or disable
ballooning for this guest.

⚠️ **A CPU cap is a fine trade; a memory cap is not.** Slow builds cost minutes.
Intermittent OOM costs somebody a day on `buildx`.

## Packages

```bash
apt-get update
apt-get install -y curl git jq ca-certificates
# plus whatever the workflows actually use — read them, do not guess
```

For image builds, additionally Docker CE with `buildx`, and `binfmt` handlers if
building for a foreign architecture.

🔴 **`docker/setup-qemu-action` registers binfmt handlers system-wide and they
outlive the job.** On GitHub's disposable VMs that is invisible. On a machine
that persists it is a lasting change to the host's binary-format registry, made
by a CI job. Know that it happens; it is not a reason to avoid it.

## A user that owns nothing else

```bash
adduser --disabled-password --gecos "" ghrunner
```

The runner must not run as root, and must not share a home directory with
anything holding a credential.

## Install and register

```bash
sudo -u ghrunner -i
mkdir actions-runner && cd actions-runner
# Use the version and checksum from the repository's
# Settings > Actions > Runners page — do not copy them from a guide.
curl -o actions-runner-linux-x64.tar.gz -L <url>
echo "<sha256>  actions-runner-linux-x64.tar.gz" | shasum -a 256 -c
tar xzf actions-runner-linux-x64.tar.gz
./config.sh --url https://github.com/<owner>/<repo> \
            --token <registration token> \
            --labels self-hosted,linux,<purpose> \
            --unattended
```

🔴 **The registration token is short-lived and repository-scoped. Do not store
it anywhere.** If it lands in a file, a log or a chat message, remove the runner
and register again.

⚠️ **Choose the purpose label deliberately.** Labels are the isolation boundary,
not just names: they are what stops a job triggered by an issue comment from
landing on the machine that holds deploy credentials. A label that describes the
wrong thing is worse than no label, because people trust it.

## Survive reboot

```bash
cd /home/ghrunner/actions-runner
sudo ./svc.sh install ghrunner
sudo ./svc.sh start
```

⚠️ **Verify by rebooting.** `systemctl is-enabled` says a unit is *supposed* to
start. It does not say it *will*.

## Workspace hygiene

The runner reuses its working directory between jobs. Unless each workflow says
otherwise, state leaks from one job to the next:

```yaml
- uses: actions/checkout@v4
  with:
    clean: true
    fetch-depth: 0    # a check that reads `git log -- <file>` compares the
                      # wrong commit under a shallow checkout
```

## Verify — this is the part that matters

1. **Prove it with a manually dispatched job first.** `workflow_dispatch` takes
   no external input, so you are testing the runner rather than exposing it.
   Point the externally-triggered workflows at it afterwards.
2. 🔴 **Confirm the run's log names your runner.** A job that quietly stayed on
   `ubuntu-latest` looks *identical* in a green tick.
3. **Reboot the host and run it again.**
4. **Run two jobs at once**, if any workflow can overlap. Tools that create
   named resources — `kind` clusters, fixed host ports — collide on a shared
   runner where GitHub would have given each job its own VM. A collision is a
   race, and a race does not appear in a diff.
5. **Check that the hosted minutes actually stopped.** The point of the exercise
   is the bill; read it rather than inferring it from a job succeeding.

## Administrative access

If the machine is firewalled to no inbound, it needs another way in before that
rule is applied — otherwise the isolation locks out the people who operate it.

🔴 **An overlay network such as Tailscale gives an admin path *in* and also
gives the runner reach *out* across the whole overlay.** On a machine that
executes repository code, that can be a wider surface than the rule you were
closing. Restrict it with ACLs so the runner is **reachable but not reaching**;
if that cannot be expressed, keep the narrower inbound rule instead.

## Ephemeral runners

Every isolation problem above — persistent credentials, binfmt handlers that
outlive the job, workspace leaking between jobs, concurrent jobs colliding — is
a property of the runner **persisting**. A runner created for one job and
destroyed afterwards removes most of them.

That is more moving parts than a single machine, and it is the right end state.
Get one persistent runner working first, then decide.
