# Plan: this repository is public and names one installation's private network

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: Decide what a public repository may say about the installation it was
developed on, and make the answer mechanical rather than remembered.

**Found**: 2026-09-10, answering a topology question (`ops`, `urb-agents#600`).
The shipped `external-services.yaml` default, both external-proxy templates and
the proxy playbook's usage line named a backplane address, a container id, a
hypervisor bridge and a document that does not exist in this repository.

---

## Done in 1.6.50, and not up for debate

Everything under `provision-host/` and `ansible/` is **the product**: baked into
the image, copied onto every machine that installs UIS. An example in a shipped
comment is read by strangers. Those five files now use RFC 5737 documentation
addresses, and `tests/static/test-no-internal-detail-in-product.sh` fails the
build if a lab address, container id, bridge name or the absent doc reappears
there. That lint carries four positive controls, because an empty grep result
proves nothing about the grep.

## 🔴 What is NOT done, and needs a decision rather than a patch

Two populations remain, and they are different questions:

### 1. `hosts/<name>/` — an installation's own manifests

`hosts/asgard/` holds real addresses, container ids and bridge names, correctly:
they are that installation's configuration, and a proxy manifest without an
address is not a manifest. The question is not whether the values are right. It
is **whether one installation's private topology belongs in a public repository
at all.**

Options, none free:

- **Leave it.** The addresses are RFC 1918 and reachable only from inside; the
  exposure is a map, not a key. Cheapest, and it is a map of a network that
  holds the vault.
- **Move `hosts/` to a private repository** and have UIS read it from there.
  Correct, and it splits the thing whose whole value is being one checkout.
- **Templatise it** — values from `.uis.secrets/`, manifests shipped with
  placeholders. Keeps one repository, adds a layer to the least-loved files.

### 2. The plan and investigation documents

`website/docs/ai-developer/plans/` records the same addresses in about a dozen
places, including completed plans that exist precisely as a record of what was
measured. ⚠️ **Rewriting history to remove them is its own harm**: an acceptance
record whose evidence has been redacted is no longer evidence. Whatever is
decided for `hosts/`, this population probably wants a different answer.

## What needs deciding

1. Which of the three options for `hosts/`, or a fourth
2. Whether historical plan documents are scrubbed, left, or moved
3. Whether the lint's scope widens once 1 and 2 are answered — it deliberately
   covers only `provision-host/` and `ansible/` today, because a lint that
   fails on files nobody has decided about is a lint people learn to skip

## Tasks

- [x] 1.1 Scrub the shipping surface (1.6.50)
- [x] 1.2 Lint it, with positive controls (1.6.50)
- [ ] 1.3 Decide question 1 — 🔴 Terje's call, not mine: it is his network
- [ ] 1.4 Decide question 2
- [ ] 1.5 Widen or leave the lint per 1.3/1.4
- [ ] 1.6 Version bump if anything ships

## Acceptance

- no file that reaches a user's machine names a real host, address, container
  id or bridge from any installation
- the decision on `hosts/` is **recorded**, whichever way it goes, so the next
  person to notice does not re-open it from scratch

## The lesson this plan carries

The leak was written by someone documenting a real example so the next reader
would understand — which is exactly the instinct you want, pointed at the wrong
repository. **A rule that lives only in a contributor's memory is one that
fails the moment the contributor is being helpful**, so the half that could be
made mechanical was, and the half that needs judgement is written down as
needing it.
