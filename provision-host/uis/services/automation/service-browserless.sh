#!/bin/bash
# service-browserless.sh - browserless service metadata
#
# A pool of headless Chromium instances the platform can drive: parallel,
# stateless, token-authenticated. Two consumers, two protocols:
#
#   Playwright server  ws://browserless.browser:3000/chromium/playwright?token=…
#                      ← Uptime Kuma's `real-browser` monitor connects here
#   CDP                http://browserless.browser:3000
#                      ← @playwright/mcp and other agent tooling connect here
#
# ⚠️ WHY THIS IS A UIS SERVICE AND NOT A NICE-TO-HAVE
# UIS already ships Uptime Kuma, whose `real-browser` monitor type calls
# `chromium.connect(remoteBrowser.url)` and needs either a Chrome binary in its
# own container or a remote browser URL. The image UIS deploys has neither, so
# that monitor type is unusable in every installation today. browserless is the
# missing piece.

# === Service Metadata (Required) ===
SCRIPT_ID="browserless"
SCRIPT_NAME="Browserless"
SCRIPT_DESCRIPTION="Headless Chromium pool for synthetic checks and agent tooling"
SCRIPT_CATEGORY="AUTOMATION"

# === Deployment (Required) ===
SCRIPT_PLAYBOOK="400-setup-browserless.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n browser -l app=browserless --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="400-remove-browserless.yml"
SCRIPT_REQUIRES=""
SCRIPT_PRIORITY="25"

# === Deployment Details (Optional) ===
SCRIPT_NAMESPACE="browser"

# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team
SCRIPT_PROVIDES_APIS="browserless-cdp"
SCRIPT_CONSUMES_APIS=""

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="A pool of headless Chromium browsers for browser-based checks and page automation"
SCRIPT_LOGO="browserless-logo.svg"
SCRIPT_WEBSITE="https://www.browserless.io/"
SCRIPT_TAGS="automation,browser,chromium,headless,playwright,synthetic-monitoring,scraping,testing"
SCRIPT_SUMMARY="browserless runs a pool of headless Chromium instances that anything in the cluster can drive over a websocket - many isolated browsers in parallel, each starting blank. It is what lets Uptime Kuma run a real-browser monitor (log in, assert the dashboard renders) rather than only checking that an HTTP endpoint returns 200, and what lets an agent read a page that only exists after JavaScript runs. It exposes two protocols on one port: Playwright's server protocol for tools that speak connect(), and CDP for tools that speak connectOverCDP() - which are different endpoints, and picking the wrong one is the usual first mistake."
SCRIPT_DOCS="/docs/services/automation/browserless"
