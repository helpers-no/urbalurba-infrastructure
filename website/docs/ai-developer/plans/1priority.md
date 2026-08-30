---
title: Current Priority
sidebar_position: 0
agent: tor-agent
updated: 2026-08-30T08:40:51Z
state: blocked
priority:
  title: Get the topology shim-contract round graded by imac, then merge it
  file: talk/for-ops-topology-shim-contract-testable.md
  why: It is WIP=1 and declared; nothing else starts until it closes, and it has sat ungraded for three days
blocked_on:
  - what: imac's verdict on branch topology-shim-contract @ d8d2aab — nine criteria, five are red cases
    who: imac
    since: 2026-08-27
    asked: talk/for-ops-topology-shim-contract-testable.md
  - what: accept or refuse my proposal to exercise the proxy topology on its cluster — outcomes 2 and 3 cannot close without it
    who: imac
    since: 2026-08-27
    asked: talk/for-ops-topology-shim-contract-testable.md
  - what: disclosure call on internal addresses in this PUBLIC repo — sanitise, keep private, or accept and record. Not a mechanism question, so not mine to decide
    who: terje
    since: 2026-08-27
    asked: talk/for-tor-agent-ops-internal-addresses-in-public-repo.md
next:
  - INVESTIGATE launcher/image version drift — mechanism already traced, needs writing up
  - Bump actions/*@v4 to @v5 across all four workflows before the deprecation turns fatal
  - Investigate vulnerability scanning for running images (the pods half; the code half is already tracked)
plans:
  active: 0
  backlog: 78
  completed: 123
  path: website/docs/ai-developer
---

# Current priority — tor-agent

**What this file is.** The machine-readable answer to ops's status poll, and the honest
statement of what I am working on. Not to be confused with
[`backlog/1PRIORITY.md`](backlog/1PRIORITY.md), which is a *triage view of the INVESTIGATE
backlog* — it decides what to investigate next. This file says what is being done now.

## Why `state: blocked` and `active: 0`

Both are accurate, and neither is a gap to be embarrassed about.

`active/` is empty because the two uptime-kuma plans that lived there had not moved since
9 and 10 August, with open tasks in both. Per the poll's own rule they were not active, so
they are in `backlog/` with what parks them stated. Inventing a third to look busy would
make this file worse.

I am blocked because I build and **imac proves** — I do not grade my own work. One round is
declared and ungraded since 27 August. That is exactly the silence this poll was created to
surface, so it is worth naming plainly: **imac and I were both quiet for three days, and my
work was waiting on imac the whole time.** Had this file existed on 27 August, the wait would
have been visible on day one.

## What shipped since taking over UIS code on 2026-08-27

Two rounds, both graded PASS by imac and both merged **fast-forward**, so the commit imac
graded is byte-for-byte the commit on `main`:

| | Change | Verdict |
|---|---|---|
| `9e79334` | Broken links, anchors and markdown links now **fail** the docs build; the one existing broken anchor fixed; the local build written down as a required pre-flight | PASS, 6/6 + a third setting imac graded unasked |
| `4ebee23` | The gate now runs on **pull requests**, so a broken link reds the PR instead of `main`; a PR build holds `Contents: read` only and cannot publish the site | PASS, 7/7 |

Declared and awaiting grading: `topology-shim-contract` @ `d8d2aab` — guards the
external-services shim contract for **every** proxy-eligible service rather than postgres
alone.

## Two corrections to things I have said

**1. I was wrong about Dependabot.** I told ops that this repo's dependency findings were
unread. They are not. `backlog/1PRIORITY.md` records website vulnerabilities driven **99 → 2**
via 26 Dependabot PRs plus npm `overrides` for two transitive roots Dependabot cannot reach —
and I confirmed both overrides are present in `website/package.json`. The remaining two are
`image-size`, which has no published patch: **a floor, not a backlog item.** So the *code* half
of the vulnerability-scanning requirement is already tracked, and only the *pods* half
(46 unscanned running images) is genuinely open. That is a smaller job than I described.

**2. Three queue items reached me as open when they were already done** — `./uis pull`, the
`uis verify target_host` defect, and the grep-level shim check this requirement asked for.
Evidence for each is in `talk/for-ops-tor-agent-queue-audit.md`. The common cause is worth
recording: these are append-only records, so the **oldest verdict in a file is the one most
likely to be stale**, and each miss came from reading a file's first verdict rather than its
last.

## Standing constraints

- **WIP=1.** Effective is not the same as parallel.
- **I build; imac proves.** Declared in `talk/for-ops-<topic>-testable.md`; I do not grade my
  own work, and I do not run my own red cases.
- **This repo is PUBLIC.** No internal addresses, hostnames or credentials in commits. One
  pre-existing instance is flagged above and awaiting Terje.
- `ops` states outcomes; mechanism **and ordering** are mine.

## If imac stays silent

I will not sit idle a second time. If no verdict arrives, I will start the
launcher/image version-drift INVESTIGATE — it is write-up work needing no tester — and say so
here rather than quietly changing what I am doing.
