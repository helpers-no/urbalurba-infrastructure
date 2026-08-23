---
title: Automation
sidebar_label: Automation
description: Browser automation, synthetic checks, and agent tooling
---

# Automation

The automation package provides **a browser as a cluster service**. Anything that
needs to drive a real Chromium — render a page, scrape a site that only works
with JavaScript, run a synthetic check against a login flow, let an agent click
through a UI — talks to it over the network instead of shipping its own browser.

## Why this is a platform service

A browser is the single heaviest dependency an application can carry. Bundled
into each service it means a ~400 MB image layer, a matching set of system
libraries, a `/dev/shm` that must be sized correctly, and a Chromium version to
keep patched — repeated per service, and got wrong independently in each one.

Run once as a shared pool, that cost is paid a single time and every consumer
becomes a thin client that opens a websocket.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
| [browserless](./browserless.md) | Headless Chromium pool, spoken to over Playwright or CDP | `./uis deploy browserless` |

## Quick Start

```bash
./uis deploy browserless
./uis verify browserless
```

No dependencies — browserless needs no database and no other UIS service.

## Access control

browserless is reachable by any pod in the cluster and **the token is the whole
of its access control**. It will fetch whatever URL it is handed, so an
unauthenticated pool is an open proxy with a JavaScript engine attached. It is
deliberately **not** exposed outside the cluster.
