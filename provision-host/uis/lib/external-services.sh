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
# Returns: 0 if declared, 1 otherwise
is_external_service() {
    local service_id="$1"
    local file; file="$(_external_services_file)"
    [[ -f "$file" ]] || return 1
    command -v yq >/dev/null 2>&1 || return 1
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

    [[ -z "$port" || "$port" == "null" ]] && port="$default_port"
    if [[ -z "$port" ]]; then
        log_error "external-services.yaml: '$service_id' has no port and no default"
        return 1
    fi

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
