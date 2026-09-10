#!/bin/bash
# external-services.sh - services this installation provides outside the cluster
#
# Reads .uis.extend/external-services.yaml and answers one question for the
# deploy path: "is this service provided externally here, and at what address?"
#
# Absent file, empty file, or no entry for the service => not external, and the
# caller deploys in-cluster exactly as before. That silence is deliberate: a
# stock laptop install must never learn this feature exists.

[[ -n "${_UIS_EXTERNAL_SERVICES_LOADED:-}" ]] && return 0
_UIS_EXTERNAL_SERVICES_LOADED=1

_external_services_file() {
    echo "${EXTEND_DIR:-/mnt/urbalurbadisk/.uis.extend}/external-services.yaml"
}

# Is this service declared as externally provided?
# Usage: is_external_service postgresql
#
# 🔴 THREE ANSWERS, NOT TWO. 0 = declared external. 1 = not declared. 2 = CANNOT
# TELL, and the caller must refuse rather than pick one.
#
# This used to return 1 — "not external", which means "deploy the real thing
# in-cluster" — for four different situations: the file is absent, `yq` is not
# installed, the service has no entry, and THE FILE DOES NOT PARSE. Only the
# first and third are answers. The other two are the absence of an answer, and
# treating them as "in-cluster" is fail-open on the one gate standing between
# `uis deploy postgresql` and a database that may be shared by every other
# service on the installation: the deploy would delete the proxy, restore the
# Service selector and roll out a StatefulSet, logging ordinary progress the
# whole way (ops, urb-agents#600, on a host where that database serves seven
# tenants).
#
# ⚠️ An absent file and an entry-less file stay "not declared". That is the
# stock laptop and the overwhelmingly common case; making it noisy would be
# fixing the wrong thing. Only *unreadable* is escalated.
is_external_service() {
    local service_id="$1"
    local file; file="$(_external_services_file)"

    # No file at all: this installation has never declared anything. Answer.
    [[ -f "$file" ]] || return 1

    # A file exists and we cannot read it. NOT an answer.
    if ! command -v yq >/dev/null 2>&1; then
        log_error "external-services.yaml exists but yq is not installed, so this"
        log_error "  installation's topology cannot be read. Refusing to assume"
        log_error "  '$service_id' is in-cluster: $file"
        return 2
    fi
    # ⚠️ NO `-e`. The shipped file is comments only, which is a valid YAML
    # document evaluating to null; `-e` would call every stock installation
    # unparseable and refuse every deploy on it. Plain evaluation fails on a
    # syntax error and succeeds on an empty document, which is the distinction
    # that matters here.
    if ! yq '.' "$file" >/dev/null 2>&1; then
        log_error "external-services.yaml exists and does not parse, so this"
        log_error "  installation's topology cannot be read. Refusing to assume"
        log_error "  '$service_id' is in-cluster: $file"
        return 2
    fi

    local host
    host="$(yq -r ".\"${service_id}\".host // \"\"" "$file" 2>/dev/null)"
    [[ -n "$host" && "$host" != "null" ]]
}

# Echo "host port why" for a declared service. Fails loudly on a bad entry
# rather than silently deploying the wrong topology.
# Usage: external_service_get postgresql 5432
external_service_get() {
    local service_id="$1" default_port="${2:-}"
    local file; file="$(_external_services_file)"

    local host port why
    host="$(yq -r ".\"${service_id}\".host // \"\"" "$file" 2>/dev/null)"
    port="$(yq -r ".\"${service_id}\".port // \"\"" "$file" 2>/dev/null)"
    why="$(yq -r ".\"${service_id}\".why  // \"\"" "$file" 2>/dev/null)"

    if [[ -z "$host" || "$host" == "null" ]]; then
        log_error "external-services.yaml: '$service_id' has no host"
        return 1
    fi

    # `why:` is required. An external dependency nobody can justify is one nobody
    # maintains - the same rule the uptime-kuma monitor definitions already hold.
    if [[ -z "$why" || "$why" == "null" ]]; then
        log_error "external-services.yaml: '$service_id' has no 'why:'"
        log_error "  Every external dependency must say why it is external."
        log_error "  When it breaks, that note is the first thing anyone reads."
        return 1
    fi

    # ⚠️ AN OMITTED PORT MEANS "the service's normal port", AND ONLY THE PROXY
    # TEMPLATE KNOWS WHAT THAT IS.
    #
    # This used to fall back to the caller's SCRIPT_EXPOSE_PORT, which is the
    # HOST-side forwarded port by convention - 35432 for postgres, 37017 for
    # mongo, 36379 for redis. Declaring a database external without an explicit
    # `port:` therefore pointed socat at :35432 on the far host, where nothing
    # listens, while the shipped external-services.yaml comment promised the
    # port "defaults to the service's normal port". The documentation was right
    # about the intent and the code did something else.
    #
    # So an absent port is now reported as the sentinel `-`, and the caller omits
    # the extra-var entirely; the template applies its own default, which is the
    # only place that legitimately knows a postgres proxy speaks 5432.
    [[ -z "$port" || "$port" == "null" ]] && port="$default_port"
    [[ -z "$port" ]] && port="-"

    echo "$host" "$port" "$why"
}

# The proxy template shipped alongside a service's setup playbook, by convention
# <NNN>-<id>-external-proxy.yml.j2 - the same numeric prefix the playbook uses.
# Usage: external_service_template postgresql 040-database-postgresql.yml
external_service_template() {
    local service_id="$1" playbook="$2"
    local prefix="${playbook%%-*}"
    echo "${prefix}-${service_id}-external-proxy.yml.j2"
}
