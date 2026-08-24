#!/bin/bash
# service-neko.sh — UIS service metadata for neko.
#
# METADATA ONLY. No logic. The playbook does the work.
#
# ⚠️ neko is an OPT-IN ADD-ON and is deliberately in no stack. `uis stack
# install` can never start it; only an explicit `./uis deploy neko` can. It
# holds live logged-in browser sessions and exposes UNAUTHENTICATED full browser
# control over CDP, so it must never come up as a side effect of installing
# something else.

SCRIPT_ID="neko"
SCRIPT_NAME="Neko"
SCRIPT_DESCRIPTION="Shared browser a human and an agent drive together, with a persistent login"
SCRIPT_CATEGORY="AUTOMATION"

SCRIPT_PLAYBOOK="410-setup-neko.yml"
SCRIPT_MANIFEST=""
SCRIPT_CHECK_COMMAND="kubectl get pods -n browser -l app=neko --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE_PLAYBOOK="410-remove-neko.yml"
SCRIPT_REQUIRES=""
# After browserless (25). Ordering only matters for `deploy` runs that name both.
SCRIPT_PRIORITY="95"

SCRIPT_NAMESPACE="browser"

SCRIPT_KIND="Component"
SCRIPT_TYPE="service"
SCRIPT_OWNER="platform-team"
SCRIPT_PROVIDES_APIS="neko-cdp"
SCRIPT_CONSUMES_APIS=""

SCRIPT_ABSTRACT="One browser that a human and an agent share, keeping its logins between sessions"
SCRIPT_LOGO="neko-logo.svg"
SCRIPT_WEBSITE="https://neko.m1k1o.net/"
SCRIPT_TAGS="automation,browser,chromium,cdp,webrtc,remote-desktop,agent,mcp"
SCRIPT_SUMMARY="neko runs a single real Chromium desktop that two kinds of driver share: a human watching it over WebRTC in a browser tab, and an agent driving the same tabs over CDP. Because the profile is persistent, a human can log in by hand once - including through 2FA - and an agent can then act as that logged-in user without ever holding the password. That is the opposite trade to browserless, which gives many blank throwaway browsers in parallel and no identity at all. Reach for neko only when a task needs the human's own session; reach for browserless for everything else, because neko is a single shared session and two drivers on one login collide."
SCRIPT_DOCS="/docs/services/automation/neko"
