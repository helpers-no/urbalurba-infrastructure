#!/bin/bash
# template.sh — UIS template command: fetch registry, browse, install UIS stack templates
#
# Fetches template-registry.json from TMP (helpers-no/dev-templates), filters by
# context: uis, and installs stack templates by deploying services and applying
# init files.
#
# See: helpers-no/dev-templates INVESTIGATE-unified-template-system.md
# See: PLAN-002-uis-template-command.md

UIS_BASE="${UIS_BASE:-/mnt/urbalurbadisk}"
# Overridable so unit tests can point at a fixture. UIS_BASE above already
# respects an existing value; these two did not, which made every assertion
# about service metadata depend on the live generated file — so a metadata
# change elsewhere could turn a passing test red for reasons unrelated to it.
SERVICES_JSON="${SERVICES_JSON:-${UIS_BASE}/website/src/data/services.json}"
STACKS_JSON="${STACKS_JSON:-${UIS_BASE}/website/src/data/stacks.json}"

# Registry and template source.
#
# ⚠️ Overridable, so a template can be exercised BEFORE it is published. These
# were plain assignments, and combined with _fetch_template_folder's `rm -rf` of
# the cache directory there was no supported way to supply a fixture at all —
# only editing this file, which changes the code under test. imac hit that
# testing templates-001 (urb-agents#335) and could not take it end to end,
# because the one published template uses none of the new vocabulary.
#
# Same shape as SERVICES_JSON above and UIS_BASE in the launcher: default to the
# real thing, let a caller point elsewhere.
#
#   TEMPLATE_REPO=/path/to/local/checkout ./uis template install my-fixture
#
# ⚠️ The variable is TEMPLATE_REPO. This comment said URB_TEMPLATE_REPO when
# the override shipped in 1.6.9 — a documented command that could not work,
# in the commit whose whole purpose was making the override usable. It must
# also be listed in UIS_FORWARDED_ENV in the launcher, or it never reaches
# the container: `docker exec` does not inherit the caller's environment.
REGISTRY_URL_PRIMARY="${REGISTRY_URL_PRIMARY:-https://raw.githubusercontent.com/helpers-no/dev-templates/main/website/src/data/template-registry.json}"
REGISTRY_URL_FALLBACK="${REGISTRY_URL_FALLBACK:-https://tmp.sovereignsky.no/data/template-registry.json}"
REGISTRY_CACHE="/tmp/uis-template-registry.json"
REGISTRY_CACHE_TTL=3600  # 1 hour

# Template fetch config
TEMPLATE_REPO="${TEMPLATE_REPO:-https://github.com/helpers-no/dev-templates.git}"
TEMPLATE_CACHE_DIR="${TEMPLATE_CACHE_DIR:-/tmp/uis-templates}"

# ─── The allowlist ────────────────────────────────────────────────────────────
#
# An application's install definition is an OCI artifact UIS pulls and then
# feeds to `configure --init-file`, which applies it as the database owner. So
# the set of registries UIS will pull from is a security boundary, not a
# convenience: a merged typo in the catalogue must not be able to point a
# platform at a stranger's SQL (urb-agents#361, and the spec's own §4).
#
# Defaults live here; an installation may extend them in
# `.uis.extend/template-allowlist.conf` — one glob per line, `#` comments. That
# file is installation config, the same relationship as
# dagster-code-locations.yaml: the product ships a default, the installation
# decides what it trusts.
TEMPLATE_ALLOWLIST_DEFAULT="ghcr.io/helpers-no/* ghcr.io/terchris/*"

# Read the effective allowlist: the defaults plus anything the installation adds.
_template_allowlist() {
    local extend_file
    extend_file="$(_uis_extend_dir 2>/dev/null || echo "")/template-allowlist.conf"
    printf '%s\n' $TEMPLATE_ALLOWLIST_DEFAULT
    if [[ -n "$extend_file" && -f "$extend_file" ]]; then
        grep -vE '^\s*(#|$)' "$extend_file" | tr -d '\r'
    fi
}

# Where .uis.extend lives. paths.sh defines EXTEND_DIR when sourced; fall back so
# this lib is usable in a unit test that has not sourced it.
_uis_extend_dir() {
    if [[ -n "${EXTEND_DIR:-}" ]]; then echo "$EXTEND_DIR"; return 0; fi
    if [[ -d "/mnt/urbalurbadisk/.uis.extend" ]]; then echo "/mnt/urbalurbadisk/.uis.extend"; return 0; fi
    echo "${UIS_BASE}/.uis.extend"
}

# Is this artifact reference inside the allowlist?
# Compares against the repository part only — a tag or digest cannot widen it.
_template_source_allowed() {
    local artifact="$1" pattern
    [[ -n "$artifact" ]] || return 1
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # shellcheck disable=SC2053  # glob match is the point
        [[ "$artifact" == $pattern ]] && return 0
    done < <(_template_allowlist)
    return 1
}

# ⚠️ A tag is NOT a pin. Tags are mutable at a registry; digests are not, which
# is why the catalogue records both and UIS pulls the digest (Terje, #361).
# `latest` and bare branch-looking refs are refused outright, so a catalogue
# entry cannot smuggle in a moving target even if the build let it through.
_template_pin_is_immutable() {
    local tag="$1" digest="$2"
    if [[ -z "$digest" ]]; then
        log_error "No digest recorded for this entry — refusing."
        echo "  A tag alone is not a pin: tags are mutable at a registry." >&2
        echo "  The catalogue build must resolve the tag to a digest and record both." >&2
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        log_error "Digest '$digest' is not a sha256 digest — refusing."
        return 1
    fi
    case "${tag,,}" in
        latest|main|master|head|"")
            log_error "Tag '$tag' is not immutable — refusing."
            echo "  Use an immutable tag such as v20260909-abc1234." >&2
            echo "  Same rule UIS already applies to Dagster code-location images." >&2
            return 1
            ;;
    esac
    return 0
}

# Check if registry cache is fresh
_registry_cache_fresh() {
    if [[ ! -f "$REGISTRY_CACHE" ]]; then
        return 1
    fi
    local age
    age=$(($(date +%s) - $(stat -c %Y "$REGISTRY_CACHE" 2>/dev/null || echo 0)))
    [[ "$age" -lt "$REGISTRY_CACHE_TTL" ]]
}

# Fetch registry from primary or fallback URL
_fetch_registry() {
    if _registry_cache_fresh; then
        return 0
    fi

    echo "Fetching template registry..." >&2

    if curl -sfL "$REGISTRY_URL_PRIMARY" -o "$REGISTRY_CACHE" 2>/dev/null; then
        return 0
    fi

    echo "Primary URL failed, trying fallback..." >&2
    if curl -sfL "$REGISTRY_URL_FALLBACK" -o "$REGISTRY_CACHE" 2>/dev/null; then
        return 0
    fi

    log_error "Could not fetch template registry from either URL"
    return 1
}

# List UIS templates (context: uis) from the registry
_list_uis_templates() {
    _fetch_registry || return 1
    jq -r '.templates[] | select((.folder // "") | startswith("uis-")) | "\(.id)|\(.name)|\(.description)"' "$REGISTRY_CACHE"
}

# Get UIS categories from the registry
_list_uis_categories() {
    _fetch_registry || return 1
    jq -r '.categories[] | select(.context == "uis") | "\(.id)|\(.name)|\(.emoji)"' "$REGISTRY_CACHE"
}

# Get template details by ID
_get_template() {
    local template_id="$1"
    _fetch_registry || return 1
    jq -r --arg id "$template_id" '.templates[] | select(.id == $id)' "$REGISTRY_CACHE"
}

# Command: uis template list
cmd_template_list() {
    _fetch_registry || return 1

    local templates
    templates=$(_list_uis_templates)

    if [[ -z "$templates" ]]; then
        log_info "No UIS templates found in the registry yet."
        echo "UIS templates will appear when they are added to helpers-no/dev-templates." >&2
        return 0
    fi

    print_section "Available UIS Templates"
    printf "%-25s %-35s %s\n" "ID" "NAME" "DESCRIPTION"
    printf "%-25s %-35s %s\n" "─────────────────────────" "───────────────────────────────────" "──────────────────────────────────"
    echo "$templates" | while IFS='|' read -r id name description; do
        printf "%-25s %-35s %s\n" "$id" "$name" "$description"
    done
    echo ""
    echo "Use 'uis template info <id>' for details"
    echo "Use 'uis template install <id>' to install"
}

# Command: uis template info <id>
cmd_template_info() {
    local template_id="${1:-}"

    if [[ -z "$template_id" ]]; then
        log_error "Usage: uis template info <id>"
        return 1
    fi

    _fetch_registry || return 1

    local template
    template=$(_get_template "$template_id")

    if [[ -z "$template" || "$template" == "null" ]]; then
        log_error "Template '$template_id' not found in registry"
        echo "Run 'uis template list' to see available templates" >&2
        return 1
    fi

    print_section "Template: $template_id"
    echo "$template" | jq -r '
        "Name:        \(.name)",
        "Version:     \(.version)",
        "Category:    \(.category)",
        "Description: \(.description)",
        "",
        "Abstract:",
        "  \(.abstract // "N/A")",
        "",
        "Summary:",
        "  \(.summary // "N/A")",
        "",
        "Tags: \(if (.tags | type) == "array" then (.tags | join(", ")) else .tags end)",
        "Docs: \(.docs // "")"
    '
}

# Sparse-checkout a template folder from the TMP repo
_fetch_template_folder() {
    local folder="$1"
    local target_dir="$TEMPLATE_CACHE_DIR/$folder"

    # Remove any stale checkout
    rm -rf "$TEMPLATE_CACHE_DIR"
    mkdir -p "$TEMPLATE_CACHE_DIR"

    echo "Fetching template folder: $folder" >&2
    (
        cd "$TEMPLATE_CACHE_DIR" || return 1
        git init -q
        git remote add origin "$TEMPLATE_REPO"
        git config core.sparseCheckout true
        echo "$folder" > .git/info/sparse-checkout
        git pull -q --depth=1 origin main
    ) 2>&1 | grep -v "^From \|^ \* " >&2

    if [[ ! -d "$target_dir" ]]; then
        log_error "Failed to fetch template folder: $folder"
        return 1
    fi

    echo "$target_dir"
}

# ─── Resolving an application's install definition ────────────────────────────
#
# The definition is its own small OCI artifact beside the application's image
# (Terje, urb-agents#361) — `<image>/uis` at the same tag. So resolving it is
# `oras pull`, not a docker pull of a whole image and not a pod: a pod would be
# a fetch through a scheduler, and everything the scheduler can do wrong would
# become a way for `template install` to fail before installing anything.
#
# Public artifacts pull anonymously: the platform's token is never touched for
# something the whole world can read.
_oras_available() {
    if ! command -v oras >/dev/null 2>&1; then
        log_error "oras is not installed on this provision host."
        echo "  Installing an application needs a provision host built after oras" >&2
        echo "  was added (UIS 1.6.16). Run './uis pull' to update, then retry." >&2
        echo "  This is not a missing application — it is a missing tool." >&2
        return 1
    fi
    return 0
}

# Log in to ghcr for a private artifact, using the credential the installation
# already holds. Same pair that becomes the `ghcr-credentials` pull secret, so
# there is no second credential path to keep in step.
_oras_login_if_private() {
    local visibility="$1" artifact="$2"
    [[ "$visibility" != "private" ]] && return 0

    local registry="${artifact%%/*}"
    local user="${GITHUB_USERNAME:-}" token="${GITHUB_ACCESS_TOKEN:-}"

    if [[ -z "$user" || -z "$token" ]]; then
        # ⚠️ Name the SECRET, not the URL. An operator who sees a 401 against a
        # ghcr path starts debugging the registry; what is actually missing is a
        # value in their own secrets file.
        log_error "This application's artifact is private and no package credential is configured."
        echo "  Set GITHUB_USERNAME and GITHUB_ACCESS_TOKEN in" >&2
        echo "    .uis.secrets/00-common-values.env" >&2
        echo "  then run './uis secrets generate && ./uis secrets apply'." >&2
        echo "  (The same pair becomes the ghcr-credentials pull secret.)" >&2
        return 1
    fi

    if ! printf '%s' "$token" | oras login "$registry" --username "$user" --password-stdin >/dev/null 2>&1; then
        log_error "oras login to $registry failed for user '$user'."
        echo "  The credential is present but was rejected. Check that the token" >&2
        echo "  has read:packages scope and has not expired." >&2
        return 1
    fi
    return 0
}

# Pull an install definition to a cache directory and echo the path.
#
# ⚠️ The cache is keyed by DIGEST, so two pins cannot collide and a re-install at
# the same pin is a cache hit rather than a re-fetch. And it removes only its OWN
# directory: the previous code `rm -rf`'d the shared parent before every fetch,
# which made two concurrent installs clobber each other (imac, #335).
_resolve_definition() {
    local id="$1" artifact="$2" tag="$3" digest="$4" visibility="${5:-public}"

    _oras_available || return 1
    if ! _template_source_allowed "$artifact"; then
        log_error "Artifact '$artifact' is not in the allowlist — refusing to pull."
        echo "  Allowed:" >&2
        _template_allowlist | sed 's/^/    /' >&2
        echo "  An installation may extend this in .uis.extend/template-allowlist.conf." >&2
        return 1
    fi
    _template_pin_is_immutable "$tag" "$digest" || return 1

    local dest="$TEMPLATE_CACHE_DIR/$id/${digest#sha256:}"
    if [[ -f "$dest/template-info.yaml" ]]; then
        echo "Using cached definition for '$id' at $digest" >&2
        echo "$dest"
        return 0
    fi

    _oras_login_if_private "$visibility" "$artifact" || return 1

    rm -rf "$dest"
    mkdir -p "$dest" || { log_error "Could not create cache dir $dest"; return 1; }

    echo "Pulling install definition: ${artifact}@${digest}" >&2
    echo "  (tag ${tag} — the digest is what is pulled)" >&2

    # ⚠️ UIS_ORAS_OCI_LAYOUT exists so the unit tests can pull from an OCI layout
    # on disk: no network, no registry, no cluster. It is test surface and it is
    # named as such rather than hidden, because the alternative is a resolution
    # path that only a cluster can exercise — and this week proved what happens
    # to code no test can reach.
    local oras_args=(pull "${artifact}@${digest}" --output "$dest")
    [[ -n "${UIS_ORAS_OCI_LAYOUT:-}" ]] && oras_args=(pull --oci-layout "${artifact}@${digest}" --output "$dest")

    if ! oras "${oras_args[@]}" >&2; then
        log_error "oras pull failed for ${artifact}@${digest}"
        echo "  If the artifact is private, this installation needs a package credential." >&2
        rm -rf "$dest"
        return 1
    fi

    if [[ ! -f "$dest/template-info.yaml" ]]; then
        log_error "The artifact contains no template-info.yaml."
        echo "  Pulled ${artifact}@${digest} and found:" >&2
        ls -1 "$dest" 2>/dev/null | sed 's/^/    /' >&2
        echo "  An application's definition artifact must carry template-info.yaml at its root." >&2
        rm -rf "$dest"
        return 1
    fi

    echo "$dest"
}

# Read the source fields from a registry entry.
#
# ⚠️ These do not exist in template-registry.json yet — the generator change is
# dev-templates' half of this and is not merged. Rather than guessing, an entry
# missing them fails naming the field and whose job it is, so the error is
# actionable instead of a null dereference three functions later.
_template_source_field() {
    local template="$1" field="$2"
    echo "$template" | jq -r --arg f "$field" '.source[$f] // empty' 2>/dev/null
}

_require_source_fields() {
    local template="$1" id="$2"
    local missing=()
    local a t d
    a=$(_template_source_field "$template" artifact)
    t=$(_template_source_field "$template" tag)
    d=$(_template_source_field "$template" digest)
    [[ -z "$a" ]] && missing+=("source.artifact")
    [[ -z "$t" ]] && missing+=("source.tag")
    [[ -z "$d" ]] && missing+=("source.digest")
    if (( ${#missing[@]} )); then
        log_error "Catalogue entry '$id' is missing: ${missing[*]}"
        echo "  An application entry needs source.artifact, source.tag and source.digest." >&2
        echo "  The catalogue build resolves the tag to a digest and records both;" >&2
        echo "  if this entry predates that, the registry generator needs updating." >&2
        return 1
    fi
    return 0
}

# Parse template-info.yaml field using yq
_yaml_field() {
    local file="$1"
    local path="$2"
    yq -r "$path // \"\"" "$file" 2>/dev/null
}

# Validate template-info.yaml
_validate_template_info() {
    local info_file="$1"
    local template_dir="$2"

    if [[ ! -f "$info_file" ]]; then
        log_error "template-info.yaml not found in template folder"
        return 1
    fi

    local install_type
    install_type=$(_yaml_field "$info_file" ".install_type")
    if [[ "$install_type" != "stack" ]]; then
        log_error "Expected install_type: stack, got: $install_type"
        return 1
    fi

    # Check provides is present
    local has_provides
    has_provides=$(yq -r 'has("provides")' "$info_file" 2>/dev/null)
    if [[ "$has_provides" != "true" ]]; then
        log_error "template-info.yaml missing 'provides' field"
        return 1
    fi

    return 0
}

# The `config:` keys a provides entry may set. Anything else is a typo and is
# rejected: a silently-ignored `url-prefix` is the failure mode this whole
# investigation exists to document.
TEMPLATE_CONFIG_KEYS="database init schemas url_prefix namespace secret_name_prefix code_location"

# `code_location` is a MAPPING, not a scalar, and its subfields are flattened
# into the conf file as code_location_<field>. That keeps the conf file flat —
# D1's design — and is why the plan predicted this would drop in without
# touching the executor's parsing.
TEMPLATE_CODE_LOCATION_KEYS="name image tag module why env_secrets"

# Write one service's config to $plan_dir/<service_id>.conf as key=value lines.
#
# ⚠️ The plan line carries only <priority>|<service_id>; configuration lives in
# these files. Four fields fitted on a pipe-delimited line, nine do not — and
# `IFS='|' read -r` mis-binds silently the first time a value contains a pipe.
# Files also keep this bash 3.x-safe (macOS default: no associative arrays) and
# leave something greppable behind when an install goes wrong.
_write_service_conf() {
    local plan_dir="$1" info_file="$2" idx="$3" svc="$4"
    local conf="$plan_dir/${svc}.conf"
    : > "$conf"

    # Reject unknown config keys before reading any of them.
    local keys k
    keys=$(yq -r ".provides.services[$idx].config // {} | keys | .[]" "$info_file" 2>/dev/null)
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        case " $TEMPLATE_CONFIG_KEYS " in
            *" $k "*) ;;
            *)  log_error "Unknown config key '$k' for service '$svc'."
                echo "Supported keys: $TEMPLATE_CONFIG_KEYS" >&2
                return 1 ;;
        esac
    done <<< "$keys"

    local v
    for k in $TEMPLATE_CONFIG_KEYS; do
        [[ "$k" == "code_location" ]] && continue
        v=$(yq -r ".provides.services[$idx].config.$k // \"\"" "$info_file" 2>/dev/null)
        [[ -n "$v" ]] && printf '%s=%s\n' "$k" "$v" >> "$conf"
    done

    # code_location, flattened. env_secrets is a list and is stored
    # comma-joined; the writer splits it again.
    if [[ "$(yq -r ".provides.services[$idx].config | has(\"code_location\")" "$info_file" 2>/dev/null)" == "true" ]]; then
        local ck
        for ck in $TEMPLATE_CODE_LOCATION_KEYS; do
            if [[ "$ck" == "env_secrets" ]]; then
                v=$(yq -r ".provides.services[$idx].config.code_location.env_secrets // [] | join(\",\")" "$info_file" 2>/dev/null)
            else
                v=$(yq -r ".provides.services[$idx].config.code_location.$ck // \"\"" "$info_file" 2>/dev/null)
            fi
            [[ -n "$v" ]] && printf 'code_location_%s=%s\n' "$ck" "$v" >> "$conf"
        done
        # Required by the Dagster playbook's own validator (360-setup-dagster.yml:277),
        # so refuse here where the message can name the declaration rather than
        # failing inside Ansible with less context.
        local ckk
        for ckk in name image tag module why; do
            if [[ -z "$(_conf_get "$conf" "code_location_$ckk")" ]]; then
                log_error "Service '$svc': config.code_location is missing '$ckk'."
                echo "  A Dagster code location needs name, image, tag, module and why." >&2
                echo "  'why' is required for the same reason prometheus-targets.yaml requires it:" >&2
                echo "  a tenant nobody can justify is one nobody maintains." >&2
                return 1
            fi
        done
        if [[ "$(_conf_get "$conf" code_location_tag)" == "latest" ]]; then
            log_error "Service '$svc': code_location tag 'latest' is refused."
            echo "  Helm rolls the code-location pod only when the image field CHANGES," >&2
            echo "  so 'latest' silently keeps serving old code after a successful deploy." >&2
            return 1
        fi
    fi

    # `configure.sh` requires --namespace and --secret-name-prefix together.
    # Catch it here, where we can say which one is missing, rather than letting
    # configure reject it later with less context.
    local ns sp
    ns=$(_conf_get "$conf" namespace); sp=$(_conf_get "$conf" secret_name_prefix)
    if [[ -n "$ns" && -z "$sp" ]]; then
        log_error "Service '$svc': config.namespace requires config.secret_name_prefix."
        return 1
    fi
    if [[ -n "$sp" && -z "$ns" ]]; then
        log_error "Service '$svc': config.secret_name_prefix requires config.namespace."
        return 1
    fi
    return 0
}

# Read one key from a conf file. Empty output when absent.
_conf_get() {
    local conf="$1" key="$2"
    [[ -f "$conf" ]] || return 0
    sed -n "s/^${key}=//p" "$conf" | head -1
}

# Resolve `provides` into an ordered deployment plan.
#
# Outputs one entry per line: <priority>|<service_id>
# Per-service configuration is written to $plan_dir/<service_id>.conf.
_resolve_provides() {
    local info_file="$1"
    local template_dir="$2"
    local plan_dir="$3"

    mkdir -p "$plan_dir" || return 1

    # Collect services from provides.stacks (expand via stacks.json). These are
    # deploy-only: a stack names services, not per-app configuration.
    local stack_services=""
    local stacks
    stacks=$(yq -r '.provides.stacks[]? // empty' "$info_file" 2>/dev/null)
    while IFS= read -r stack_id; do
        [[ -z "$stack_id" ]] && continue
        local svcs
        svcs=$(jq -r --arg id "$stack_id" '.itemListElement[] | select(.identifier == $id) | .components[].service' "$STACKS_JSON" 2>/dev/null)
        stack_services+="$svcs"$'\n'
    done <<< "$stacks"

    # provides.services — plain strings (deploy only) and objects (with config).
    local direct_services=""
    local service_count
    service_count=$(yq -r '.provides.services // [] | length' "$info_file" 2>/dev/null)
    local i
    for ((i=0; i<service_count; i++)); do
        local entry_type svc
        entry_type=$(yq -r ".provides.services[$i] | type" "$info_file" 2>/dev/null)
        if [[ "$entry_type" == "!!str" ]]; then
            svc=$(yq -r ".provides.services[$i]" "$info_file" 2>/dev/null)
            : > "$plan_dir/${svc}.conf"
        else
            svc=$(yq -r ".provides.services[$i].service" "$info_file" 2>/dev/null)
            if [[ -z "$svc" || "$svc" == "null" ]]; then
                log_error "provides.services[$i] has no 'service' field"
                return 1
            fi
            _write_service_conf "$plan_dir" "$info_file" "$i" "$svc" || return 1
        fi
        direct_services+="${svc}"$'\n'
    done

    # Stack services first, direct services after, so direct entries win.
    local all_services=""
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        [[ -f "$plan_dir/${svc}.conf" ]] || : > "$plan_dir/${svc}.conf"
        all_services+="${svc}"$'\n'
    done <<< "$stack_services"
    all_services+="$direct_services"

    # Deduplicate by service id, keeping the LAST occurrence (direct wins),
    # by walking the list in reverse and keeping the first one seen.
    local dedup="" seen="" reversed
    reversed=$(echo "$all_services" | tac)
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if [[ ",$seen," != *",$svc,"* ]]; then
            seen="$seen,$svc"
            local priority
            priority=$(jq -r --arg id "$svc" '.services[] | select(.id == $id) | .priority // 999' "$SERVICES_JSON" 2>/dev/null)
            dedup+="${priority}|${svc}"$'\n'
        fi
    done <<< "$reversed"

    echo "$dedup" | grep -v '^$' | sort -t'|' -k1,1n
}

# ─── Contributing a Dagster code location ─────────────────────────────────────
#
# TPL-F5, and the answer to TPL-Q1/Q2 the plan deferred to this phase.
#
# ⚠️ THIS IS A CODE-LOCATION WRITER, NOT A GENERIC "contribute to another
# service's extend file" MECHANISM — deliberately.
#
# Two other files would qualify for the generic form (prometheus-targets.yaml,
# monitors.yaml) and the temptation is real. Rejected because the generic form
# has to answer questions this one does not: what a list key is called in an
# arbitrary file, what identity means for de-duplication, and what removal does
# when two applications contributed to the same file. The spec needs one
# consumer, and one consumer does not tell you the shape of three. Build the
# generic version when a second one exists and can argue for its own syntax —
# the same reasoning that deferred the `Application` type and the ordering work.
#
# TPL-Q2 (who owns idempotency and removal) is answered by construction below:
# the write is filter-then-append keyed on `name`, so it converges, and removal
# is the same filter without the append — which `template remove` will use in
# phase 4 rather than needing its own logic.

# Where the code-location declaration lives. Installation config, not product
# config — the same relationship as prometheus-targets.yaml.
_code_locations_file() {
    echo "$(_uis_extend_dir)/dagster-code-locations.yaml"
}

# Add or replace one code location, then leave it to the caller to deploy.
#
# Idempotent by construction: entries with the same `name` are filtered out and
# the new one appended, so re-running at the same pin produces a byte-identical
# file and a new pin changes exactly the image field — which is what Helm needs
# in order to roll the pod at all.
_write_code_location() {
    local cl_name="$1" cl_image="$2" cl_tag="$3" cl_module="$4" cl_why="$5" cl_env_secrets="${6:-}"
    local file
    file="$(_code_locations_file)"

    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is required to write $file and is not installed."
        return 1
    fi

    mkdir -p "$(dirname "$file")" || return 1
    if [[ ! -f "$file" ]]; then
        printf '# Written by `uis template install`. Hand edits are preserved for\n' > "$file"
        printf '# entries this file already has; an install replaces only its own.\n' >> "$file"
        printf 'code_locations: []\n' >> "$file"
    fi

    # ⚠️ Values go through strenv(), never string interpolation. These come from
    # a third party's declaration, and interpolating them into a yq expression
    # would let a crafted `name` rewrite the whole document.
    local expr='.code_locations = ((.code_locations // [])
        | map(select(.name != strenv(cl_name)))
        + [{
            "name":   strenv(cl_name),
            "image":  strenv(cl_image),
            "tag":    strenv(cl_tag),
            "module": strenv(cl_module),
            "why":    strenv(cl_why)
          }])'

    if ! cl_name="$cl_name" cl_image="$cl_image" cl_tag="$cl_tag"          cl_module="$cl_module" cl_why="$cl_why"          yq -i "$expr" "$file"; then
        log_error "Failed to write the code location '$cl_name' into $file"
        return 1
    fi

    if [[ -n "$cl_env_secrets" ]]; then
        local sec_expr='(.code_locations[] | select(.name == strenv(cl_name)) | .env_secrets)
            = (strenv(cl_env_secrets) | split(","))'
        if ! cl_name="$cl_name" cl_env_secrets="$cl_env_secrets" yq -i "$sec_expr" "$file"; then
            log_error "Failed to write env_secrets for '$cl_name'"
            return 1
        fi
    fi

    echo "Code location '$cl_name' written to $file" >&2
    echo "  image: ${cl_image}:${cl_tag}" >&2
    return 0
}

# Remove one code location. Phase 4's `template remove` uses this; it is the
# same filter as the write, without the append.
_remove_code_location() {
    local cl_name="$1" file
    file="$(_code_locations_file)"
    [[ -f "$file" ]] || return 0
    cl_name="$cl_name" yq -i '.code_locations = ((.code_locations // []) | map(select(.name != strenv(cl_name))))' "$file"
}

# Is this service multi-instance? Drives whether `uis deploy` gets --app.
# Read from services.json rather than a hardcoded list, so a future
# multi-instance service needs no edit here.
_service_is_multi_instance() {
    local svc="$1"
    [[ "$(jq -r --arg id "$svc" '.services[] | select(.id == $id) | .multiInstance // false' "$SERVICES_JSON" 2>/dev/null)" == "true" ]]
}

# Resolve an `init:` value to SQL on stdout. Accepts a single file or a
# directory of *.sql applied in LC_ALL=C sort order.
#
# ⚠️ Order is part of the contract, not a convenience. Tenants number their
# migrations (001_, 050_) precisely because DDL is order-dependent, and a
# partial apply is what configure-postgresql's rollback exists to undo — so the
# ordered list is printed before anything is applied and stays in the log.
_collect_init_sql() {
    local path="$1"
    if [[ -f "$path" ]]; then
        echo "Init file: $(basename "$path")" >&2
        cat "$path"
        return 0
    fi
    if [[ -d "$path" ]]; then
        local files
        files=$(LC_ALL=C find "$path" -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort)
        if [[ -z "$files" ]]; then
            log_error "Init directory '$path' contains no .sql files."
            return 1
        fi
        local n
        n=$(printf '%s\n' "$files" | grep -c .)
        echo "Init directory: $n .sql file(s), applied in this order:" >&2
        printf '%s\n' "$files" | while IFS= read -r f; do echo "    $(basename "$f")" >&2; done

        # ⚠️ Lexicographic order is the contract, and it INVERTS on un-padded
        # numeric prefixes: 9_, 10_, 100_ sort as 100_, 10_, 9_. Zero-padded
        # names (001_, 026_, 050_) are immune, which is why the convention
        # exists — but `1_, 2_, ... 10_` is a common way to number migrations,
        # and the result is out-of-order DDL that SUCCEEDS and leaves the wrong
        # schema. That is precisely the silent failure this feature exists to
        # prevent, reached from the one direction the contract does not cover.
        # Found by imac on urb-agents#335.
        #
        # A warning rather than an error: lexicographic is documented and
        # deliberate, and a tenant may have meant it. But it must not pass
        # unremarked, because nothing downstream can tell a wrong order from an
        # intended one.
        local numeric_sorted lexical_sorted
        lexical_sorted=$(printf '%s\n' "$files" | while IFS= read -r f; do basename "$f"; done)
        numeric_sorted=$(printf '%s\n' "$lexical_sorted" | LC_ALL=C sort -t'_' -k1,1n -s)
        if [ "$lexical_sorted" != "$numeric_sorted" ]; then
            echo "" >&2
            log_warn "Apply order is lexicographic and differs from numeric order."
            echo "    These names are not zero-padded, so e.g. 10_ sorts before 9_." >&2
            echo "    Numeric order would be:" >&2
            printf '%s\n' "$numeric_sorted" | while IFS= read -r f; do echo "      $f" >&2; done
            echo "    If that is what you meant, pad the numbers: 001_, 002_, ... 010_." >&2
            echo "    Applying in the LEXICOGRAPHIC order listed above." >&2
            echo "" >&2
        fi
        printf '%s\n' "$files" | while IFS= read -r f; do
            printf -- '-- >>> %s\n' "$(basename "$f")"
            cat "$f"
            printf '\n'
        done
        return 0
    fi
    log_error "Init path '$path' is neither a file nor a directory."
    return 1
}

# Substitute {{ params.* }} references using a params file (key=value lines)
_substitute_params() {
    local text="$1"
    local params_file="$2"

    [[ ! -f "$params_file" ]] && { echo "$text"; return 0; }

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        # Substitute both {{ params.key }} and {{params.key}}
        text="${text//\{\{ params.$key \}\}/$value}"
        text="${text//\{\{params.$key\}\}/$value}"
    done < "$params_file"

    echo "$text"
}

# Build effective params from YAML defaults + CLI overrides
# Outputs key=value lines to stdout
_build_effective_params() {
    local info_file="$1"
    # yq to emit params as key=value lines
    yq -r '.params // {} | to_entries | .[] | "\(.key)=\(.value)"' "$info_file" 2>/dev/null
}

# Command: uis template install <id>
cmd_template_install() {
    local template_id="${1:-}"
    shift || true

    if [[ -z "$template_id" ]]; then
        log_error "Usage: uis template install <id> [--dry-run] [--param key=value]..."
        return 1
    fi

    # Parse flags. ⚠️ An unknown flag is REFUSED, not shifted past: the old loop
    # silently ignored anything it did not recognise, so `--dryrun` would have
    # installed for real. Same reasoning as rejecting an unknown `config:` key.
    declare -A cli_params
    local dry_run=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            --param)
                if [[ -z "${2:-}" ]]; then
                    log_error "--param needs key=value"
                    return 1
                fi
                local kv="$2"
                local k="${kv%%=*}"
                local v="${kv#*=}"
                cli_params["$k"]="$v"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Usage: uis template install <id> [--dry-run] [--param key=value]..." >&2
                return 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                return 1
                ;;
        esac
    done

    _fetch_registry || return 1

    local template
    template=$(_get_template "$template_id")
    if [[ -z "$template" || "$template" == "null" ]]; then
        log_error "Template '$template_id' not found in registry"
        echo "Run 'uis template list' to see available templates" >&2
        return 1
    fi

    local folder
    folder=$(echo "$template" | jq -r '.folder // empty')
    if [[ -z "$folder" ]]; then
        log_error "Template '$template_id' has no folder field in registry"
        return 1
    fi

    # Fetch the template folder
    local template_dir
    template_dir=$(_fetch_template_folder "$folder")
    if [[ -z "$template_dir" || ! -d "$template_dir" ]]; then
        log_error "Failed to fetch template folder"
        return 1
    fi

    local info_file="$template_dir/template-info.yaml"

    # Validate
    if ! _validate_template_info "$info_file" "$template_dir"; then
        return 1
    fi

    # Build effective params file (YAML defaults + CLI overrides)
    local params_file="$template_dir/.effective-params"
    _build_effective_params "$info_file" > "$params_file"
    # Apply CLI overrides — remove existing entry, add new
    if [[ ${#cli_params[@]} -gt 0 ]]; then
        for key in "${!cli_params[@]}"; do
            # Remove old entry
            sed -i "/^${key}=/d" "$params_file"
            # Add new entry
            echo "${key}=${cli_params[$key]}" >> "$params_file"
        done
    fi

    log_info "Effective params:"
    sed 's/^/  /' "$params_file" >&2

    # Resolve provides into a deployment plan. Per-service configuration lands
    # in $plan_dir/<service_id>.conf; the plan itself is <priority>|<service_id>.
    local plan_dir="$template_dir/.plan"
    local plan
    plan=$(_resolve_provides "$info_file" "$template_dir" "$plan_dir") || return 1

    if [[ -z "$plan" ]]; then
        log_error "Deployment plan is empty — no services in provides"
        return 1
    fi

    print_section "Installing Template: $template_id"
    echo "Template folder: $folder"
    echo ""
    echo "Deployment plan (in priority order):"
    # The preview states the ORDER, because it is per-service and a reader who
    # sees only "deploy + configure" cannot tell which way round it runs.
    echo "$plan" | while IFS='|' read -r priority svc; do
        local action
        if _service_is_multi_instance "$svc"; then
            action="configure, then deploy --app (per-app instance)"
        elif [[ -s "$plan_dir/${svc}.conf" ]]; then
            action="deploy, then configure"
        else
            action="deploy"
        fi
        echo "  [$priority] $svc — $action"
    done
    echo ""

    # Get app name param from effective params file
    local app_name
    app_name=$(grep '^app_name=' "$params_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
    [[ -z "$app_name" ]] && app_name="$template_id"

    # ─── --dry-run ────────────────────────────────────────────────────────────
    #
    # Print every command the install would run, in order, with params resolved,
    # and run nothing. The affordance every write tool on this platform now has.
    #
    # ⚠️ It is a dry run of the INSTALL, not of the FETCH. Resolving the pointer
    # has already happened by this point — that is how we know what the plan is —
    # so a `--dry-run` has pulled the definition artifact and written nothing
    # else. Said in the output, because "dry run" otherwise implies untouched.
    if [[ "$dry_run" == true ]]; then
        print_section "Dry run: $template_id"
        echo "Commands that would run, in order:"
        echo ""
        local n=0
        while IFS='|' read -r priority svc; do
            [[ -z "$svc" ]] && continue
            local conf="$plan_dir/${svc}.conf"
            local args=() first=false
            _service_is_multi_instance "$svc" && first=true

            # Same argument construction as the executor below, so the dry run
            # cannot drift from what actually happens. Any change there belongs
            # here too — and the falsification for this phase is that they agree.
            if [[ -s "$conf" ]]; then
                args=("$svc" "--app" "$app_name")
                local v
                v=$(_substitute_params "$(_conf_get "$conf" database)" "$params_file");            [[ -n "$v" ]] && args+=(--database "$v")
                v=$(_substitute_params "$(_conf_get "$conf" schemas)" "$params_file");             [[ -n "$v" ]] && args+=(--schemas "$v")
                v=$(_substitute_params "$(_conf_get "$conf" url_prefix)" "$params_file");          [[ -n "$v" ]] && args+=(--url-prefix "$v")
                v=$(_substitute_params "$(_conf_get "$conf" namespace)" "$params_file");           [[ -n "$v" ]] && args+=(--namespace "$v")
                v=$(_substitute_params "$(_conf_get "$conf" secret_name_prefix)" "$params_file");  [[ -n "$v" ]] && args+=(--secret-name-prefix "$v")
                local init
                init=$(_substitute_params "$(_conf_get "$conf" init)" "$params_file")
                [[ -n "$init" ]] && args+=(--init-file -)
            fi

            local deploy_args=("$svc")
            _service_is_multi_instance "$svc" && deploy_args+=(--app "$app_name")

            if [[ -n "$(_conf_get "$conf" code_location_name)" ]]; then
                n=$((n+1)); echo "  $n. uis deploy $svc"
                n=$((n+1)); echo "  $n. (write code location '$(_substitute_params "$(_conf_get "$conf" code_location_name)" "$params_file")' to $(_code_locations_file))"
                n=$((n+1)); echo "  $n. uis deploy $svc          # again, so the overlay picks it up"
                continue
            fi
            if [[ "$first" == true ]]; then
                n=$((n+1)); echo "  $n. uis configure ${args[*]}"
                n=$((n+1)); echo "  $n. uis deploy ${deploy_args[*]}"
            else
                n=$((n+1)); echo "  $n. uis deploy ${deploy_args[*]}"
                if [[ -s "$conf" ]]; then
                    n=$((n+1)); echo "  $n. uis configure ${args[*]}"
                fi
            fi
            if [[ -n "${init:-}" ]]; then
                echo "       (stdin: $(_collect_init_sql "$template_dir/$init" 2>/dev/null | grep -c '' || echo 0) lines from '$init')"
            fi
            unset init
        done <<< "$plan"
        echo ""
        echo "Nothing was installed. ⚠️ The definition artifact WAS pulled — that is"
        echo "how the plan above is known — but no service was deployed or configured."
        return 0
    fi

    # Execute plan
    local results=""
    while IFS='|' read -r priority svc; do
        [[ -z "$svc" ]] && continue
        local conf="$plan_dir/${svc}.conf"

        # ⚠️ WHICH COMES FIRST, deploy or configure, IS PER-SERVICE.
        #
        # It follows from what multi-instance means, rather than from one
        # example:
        #
        #   single-instance — the service is shared and already running, and
        #       configure adds per-app resources INSIDE it. `configure
        #       postgresql` execs into the running pod, so it needs the deploy
        #       to have happened.  =>  deploy, then configure.
        #
        #   multi-instance — `deploy --app` CREATES the per-app instance, and
        #       that instance consumes what configure produced.
        #       088-setup-postgrest.yml fails outright without the per-app
        #       secret and says so: "The configure step must run before deploy."
        #       configure cannot want the instance running, because the instance
        #       does not exist yet.  =>  configure, then deploy.
        #
        # Found by imac end-to-end on urb-agents#335, after the --app fix. TPL-F3
        # said "no multi-instance service could be installed from a template at
        # all" — that stayed true with the flag corrected, because the symptom had
        # two causes and I had only found one. The install failed on a missing
        # secret instead of a missing flag.
        local configure_first=false
        _service_is_multi_instance "$svc" && configure_first=true

        local deploy_args=("$svc")
        if _service_is_multi_instance "$svc"; then
            deploy_args+=(--app "$app_name")
        fi

        if [[ "$configure_first" == false ]]; then
            log_info "Deploying ${deploy_args[*]}..."
            if ! uis deploy "${deploy_args[@]}" >&2; then
                log_error "Deploy failed for $svc"
                return 1
            fi
        fi

        # ─── a code-location contribution ────────────────────────────────────
        #
        # ⚠️ NOT a `configure` call. `dagster` has no configure handler and is
        # not SCRIPT_CONFIGURABLE, so `uis configure dagster` would fail. A code
        # location is contributed by writing the extend file and DEPLOYING AGAIN
        # — which is why the spec's falsification expects "dagster deploy ×2
        # with the extend entry written between".
        #
        # The second deploy is not belt-and-braces: the first one may have
        # installed Dagster for the first time, and the Helm values overlay is
        # rendered from the extend file at deploy time, so an entry written after
        # a deploy is invisible until the next one.
        if [[ -n "$(_conf_get "$conf" code_location_name)" ]]; then
            local cl_n cl_i cl_t cl_m cl_w cl_s
            cl_n=$(_substitute_params "$(_conf_get "$conf" code_location_name)" "$params_file")
            cl_i=$(_substitute_params "$(_conf_get "$conf" code_location_image)" "$params_file")
            cl_t=$(_substitute_params "$(_conf_get "$conf" code_location_tag)" "$params_file")
            cl_m=$(_substitute_params "$(_conf_get "$conf" code_location_module)" "$params_file")
            cl_w=$(_substitute_params "$(_conf_get "$conf" code_location_why)" "$params_file")
            cl_s=$(_substitute_params "$(_conf_get "$conf" code_location_env_secrets)" "$params_file")

            _write_code_location "$cl_n" "$cl_i" "$cl_t" "$cl_m" "$cl_w" "$cl_s" || return 1

            log_info "Redeploying $svc so it picks up the code location..."
            if ! uis deploy "$svc" >&2; then
                log_error "Deploy failed for $svc after writing the code location"
                echo "  The entry IS written to $(_code_locations_file)." >&2
                echo "  Fix the cause and re-run './uis deploy $svc' — the entry is idempotent." >&2
                return 1
            fi
            results+="$svc: code location '$cl_n' registered"$'\n'
            continue
        fi

        # Configure if this service has any config at all.
        if [[ -s "$conf" ]]; then
            local resolved_db resolved_init resolved_schemas resolved_prefix
            local resolved_ns resolved_secret_prefix
            resolved_db=$(_substitute_params "$(_conf_get "$conf" database)" "$params_file")
            resolved_init=$(_substitute_params "$(_conf_get "$conf" init)" "$params_file")
            resolved_schemas=$(_substitute_params "$(_conf_get "$conf" schemas)" "$params_file")
            resolved_prefix=$(_substitute_params "$(_conf_get "$conf" url_prefix)" "$params_file")
            resolved_ns=$(_substitute_params "$(_conf_get "$conf" namespace)" "$params_file")
            resolved_secret_prefix=$(_substitute_params "$(_conf_get "$conf" secret_name_prefix)" "$params_file")

            # --app is unconditional here and that is deliberate: a
            # single-instance service can still hold per-app resources, which is
            # exactly what `configure postgresql --app` creates.
            local configure_args=("$svc" "--app" "$app_name" "--json")
            [[ -n "$resolved_db" ]] && configure_args+=(--database "$resolved_db")
            [[ -n "$resolved_schemas" ]] && configure_args+=(--schemas "$resolved_schemas")
            [[ -n "$resolved_prefix" ]] && configure_args+=(--url-prefix "$resolved_prefix")
            [[ -n "$resolved_ns" ]] && configure_args+=(--namespace "$resolved_ns")
            [[ -n "$resolved_secret_prefix" ]] && configure_args+=(--secret-name-prefix "$resolved_secret_prefix")

            log_info "Configuring $svc (args: ${configure_args[*]})..."
            local result configure_exit
            if [[ -n "$resolved_init" ]]; then
                # A file or a directory of ordered *.sql — see _collect_init_sql.
                local init_path="$template_dir/$resolved_init"
                local init_content
                init_content=$(_collect_init_sql "$init_path") || return 1
                init_content=$(_substitute_params "$init_content" "$params_file")
                configure_args+=(--init-file -)
                log_info "Configuring $svc with init from '$resolved_init' ($(wc -l <<< "$init_content") lines)"
                # ⚠️ `|| configure_exit=$?`, not a bare assignment. uis-cli.sh:9 sets
                # `set -e`, so `result=$(uis configure ...)` ABORTS the function the
                # moment configure exits non-zero — before configure_exit is read
                # and long before the status handling below. Every configure failure
                # in a template install was therefore silent: imac hit a one-line
                # usage error and got a 135-line log whose last line was
                # "Dependency 'postgresql' is running." (urb-agents#335).
                configure_exit=0
                result=$(echo "$init_content" | uis configure "${configure_args[@]}") || configure_exit=$?
            else
                configure_exit=0
                result=$(uis configure "${configure_args[@]}") || configure_exit=$?
            fi

            # Show the raw result for debugging
            if [[ -z "$result" ]]; then
                log_error "Configure produced no output for $svc (exit code: $configure_exit)"
                echo "Command was: uis configure ${configure_args[*]}" >&2
                return 1
            fi

            # Check result status
            local status
            status=$(echo "$result" | jq -r '.status' 2>/dev/null)
            case "$status" in
                ok|already_configured)
                    results+="$svc: $status"$'\n'
                    if [[ "$status" == "ok" ]]; then
                        echo "$result" | jq '.' >&2
                    else
                        log_info "$svc: already configured"
                    fi
                    ;;
                *)
                    log_error "Configure failed for $svc (exit: $configure_exit)"
                    # configure emits a JSON error with a `detail` that is usually
                    # the whole answer — surface it rather than making a reader
                    # parse raw output.
                    local detail
                    detail=$(echo "$result" | jq -r '.detail // empty' 2>/dev/null || true)
                    [[ -n "$detail" ]] && echo "  $detail" >&2
                    echo "Raw output: $result" >&2
                    return 1
                    ;;
            esac
        elif [[ "$configure_first" == true ]]; then
            # A multi-instance service with no config: `deploy --app` would have
            # nothing to consume. Refuse rather than fail inside the playbook.
            log_error "Service '$svc' is multi-instance but the template declares no config for it."
            echo "A per-app instance needs configure to run first, and there is nothing to configure." >&2
            return 1
        else
            results+="$svc: deployed"$'\n'
        fi

        # The multi-instance half of the per-service ordering above: the per-app
        # instance is created only now that configure has produced its inputs.
        if [[ "$configure_first" == true ]]; then
            log_info "Deploying ${deploy_args[*]}..."
            if ! uis deploy "${deploy_args[@]}" >&2; then
                log_error "Deploy failed for $svc"
                return 1
            fi
            results+="$svc: configured + deployed"$'\n'
        fi
    done <<< "$plan"

    print_section "Template Installation Complete"
    echo "$results"

    # Print README if available
    local readme_file
    readme_file=$(_yaml_field "$info_file" ".readme")
    if [[ -n "$readme_file" && -f "$template_dir/$readme_file" ]]; then
        echo ""
        echo "For usage details, see: $template_dir/$readme_file"
    fi
}

# Main template command dispatcher
run_template() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        list)
            cmd_template_list
            ;;
        info)
            cmd_template_info "$@"
            ;;
        install)
            cmd_template_install "$@"
            ;;
        ""|help|--help|-h)
            echo "Usage: uis template <command> [args]"
            echo ""
            echo "Commands:"
            echo "  list              List available UIS templates"
            echo "  info <id>         Show template details"
            echo "  install <id>      Install a template (deploy + configure services)"
            echo ""
            echo "Examples:"
            echo "  uis template list"
            echo "  uis template info postgresql-demo"
            echo "  uis template install postgresql-demo"
            return 0
            ;;
        *)
            log_error "Unknown template command: $subcmd"
            echo "Run 'uis template' for usage" >&2
            return 1
            ;;
    esac
}
