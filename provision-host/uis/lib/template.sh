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
# 🔴 The cache is keyed by the URL, and `file://` is never cached.
#
# It used to be one fixed path for whatever registry was fetched last, with a
# one-hour TTL and no override — so switching REGISTRY_URL_PRIMARY, the
# DOCUMENTED way to test a template before it reaches the catalogue, silently
# served the previous registry for up to an hour. Editing your own local
# registry and re-running did the same. The install then resolved a pin the
# operator had not asked for and printed it, which is the only reason this was
# caught at all.
#
# Two changes, both needed:
#   - the path is derived from the URL, so two registries cannot collide
#   - a file:// URL is read every time. Reading a local file is free, and
#     caching it is exactly what makes editing it confusing.
REGISTRY_CACHE_TTL="${REGISTRY_CACHE_TTL:-3600}"  # 1 hour

# Where this URL's registry is cached. Overridable, like every neighbour above.
_registry_cache_path() {
    if [[ -n "${REGISTRY_CACHE:-}" ]]; then echo "$REGISTRY_CACHE"; return 0; fi
    local key
    key=$(printf '%s' "$REGISTRY_URL_PRIMARY" | sha256sum 2>/dev/null | cut -c1-16)
    [[ -z "$key" ]] && key="default"
    echo "/tmp/uis-template-registry-${key}.json"
}

# Is this registry source cached at all? A local file never is.
_registry_is_cacheable() {
    [[ "$REGISTRY_URL_PRIMARY" != file://* ]]
}

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
    _registry_is_cacheable || return 1
    local cache
    cache="$(_registry_cache_path)"
    if [[ ! -f "$cache" ]]; then
        return 1
    fi
    local age
    age=$(($(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0)))
    [[ "$age" -lt "$REGISTRY_CACHE_TTL" ]]
}

# Fetch registry from primary or fallback URL
_fetch_registry() {
    # Every reader goes through this, so resolving the path here means no
    # caller has to know the cache is URL-keyed.
    REGISTRY_CACHE="$(_registry_cache_path)"

    if _registry_cache_fresh; then
        return 0
    fi

    echo "Fetching template registry..." >&2

    if curl -sfL "$REGISTRY_URL_PRIMARY" -o "$REGISTRY_CACHE" 2>/dev/null; then
        return 0
    fi

    # ⚠️ A file:// primary must NOT silently fall back to the network registry.
    # The whole point of pointing at a local file is to test THAT file; falling
    # through to the catalogue would resolve a different entry entirely and
    # report success — the same shape as the defect this function just fixed.
    if [[ "$REGISTRY_URL_PRIMARY" == file://* ]]; then
        log_error "Could not read the local registry: ${REGISTRY_URL_PRIMARY#file://}"
        echo "  Refusing to fall back to the catalogue: you asked for that file." >&2
        return 1
    fi

    echo "Primary URL failed, trying fallback..." >&2
    if curl -sfL "$REGISTRY_URL_FALLBACK" -o "$REGISTRY_CACHE" 2>/dev/null; then
        return 0
    fi

    log_error "Could not fetch template registry from either URL"
    return 1
}

# List UIS templates (context: uis) from the registry.
#
# 🔴 This used to filter on `.folder | startswith("uis-")`, which made every
# APPLICATION entry invisible to `uis template list`: an application has no
# `folder` — it has a `source` — so `(.folder // "")` was "" and never matched.
# `info` and `install` were unaffected (they go through `_get_template` on the
# id), so atlas would have been installable only by someone who already knew
# its id, and absent from the list a person browses. Found by injecting an
# application entry into the live registry rather than by reading the filter.
#
# The registry already carries the field that answers this question: each
# category has a `context` of `uis` or `dct`, and `_list_uis_categories` below
# reads exactly that. The folder prefix was a proxy that correlated with it for
# the one template the catalogue had. Join on the category instead.
#
# ⚠️ Bind the category value before the pipe. `$uis_categories | index(.category)`
# rebinds `.` to the ARRAY, so `.category` indexes an array and jq errors —
# which the fixture test below caught on the first run, because it is a real
# registry rather than an assertion about one.
#
# `templateKind: application` is accepted as well, independent of the category,
# because an application entry is a UIS install target by construction — an OCI
# install definition has no other consumer. That keeps a miscategorised
# application visible rather than silently absent, which is the failure this
# comment exists to prevent recurring.
_list_uis_templates() {
    _fetch_registry || return 1
    jq -r '
        [.categories[] | select(.context == "uis") | .id] as $uis_categories
        | .templates[]
        | select(
            ((.category // "") as $c | $uis_categories | index($c)) != null
            or ((.templateKind // .kind // "") == "application")
          )
        | "\(.id)|\(.name)|\(.description)"
    ' "$REGISTRY_CACHE"
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

    # ⚠️ `summary` and `docs` used to be printed here and NO registry entry has
    # ever carried either — every template showed "Summary: N/A" and an empty
    # "Docs:". Reading fields nothing writes, the cosmetic cousin of the
    # `requires` defect in 1.6.24. Dropped rather than left looking like
    # missing data.
    echo "$template" | jq -r '
        "Name:        \(.name)",
        "Version:     \(.version)",
        "Category:    \(.category)",
        "Description: \(.description)",
        "",
        "Abstract:",
        "  \(.abstract // "N/A")",
        "",
        "Tags: \(if (.tags | type) == "array" then (.tags | join(", ")) else .tags end)"
    '

    # An application's pin is the most important thing about it and `info` did
    # not show it, so the only way to see what an install would fetch was to
    # run the install.
    local kind
    kind="$(_json_field "$template" '.templateKind // .kind')"
    if [[ "$kind" == "application" ]]; then
        echo ""
        echo "Kind:     application"
        echo "Artifact: $(_template_source_field "$template" artifact)"
        echo "Tag:      $(_template_source_field "$template" tag)"
        echo "Pin:      $(_template_source_field "$template" digest)"
        local vis
        vis="$(_json_field "$template" '.visibility')"
        echo "Visible:  ${vis:-public}"

        # 🔴 RENDER THE APPLICATION'S OWN OPERATIONAL BLOCK.
        #
        # atlas publishes `operational:` in its artifact — what installing
        # deploys, whether anything runs afterwards, how to load the data, the
        # schedule, which external services it will contact. It answers the
        # question a novice actually has, and **nothing rendered it**: zero
        # matches across 677 lines of install output and nothing in `info`
        # (imac, urb-agents#530).
        #
        # I told atlas on #499 that this field was legal and that I would
        # surface it once they published. They published; I had not.
        #
        # ⚠️ It lives in the ARTIFACT, not the registry, so this pulls the
        # definition — which is the right home for it (version-locked to the
        # code it describes) and the reason `info` now does a digest-pinned
        # fetch. `_resolve_definition` caches by digest, so a repeated `info`
        # costs nothing. A failure here must NOT fail `info`: the registry
        # half above is still useful, and a fetch problem is not a reason to
        # tell an operator nothing.
        _template_info_operational "$template_id" "$template"
    fi
}

# Print the `operational:` block from an application's definition, if it has
# one. Silent when it does not — most applications will not, and an empty
# heading is worse than no heading.
_template_info_operational() {
    local template_id="$1" template="$2"
    command -v yq >/dev/null 2>&1 || return 0
    _oras_available >/dev/null 2>&1 || return 0

    local artifact tag digest vis dir
    artifact="$(_template_source_field "$template" artifact)"
    tag="$(_template_source_field "$template" tag)"
    digest="$(_template_source_field "$template" digest)"
    vis="$(_json_field "$template" '.visibility')"; vis="${vis:-public}"
    [[ -n "$artifact" && -n "$digest" ]] || return 0

    dir=$(_resolve_definition "$template_id" "$artifact" "$tag" "$digest" "$vis" 2>/dev/null) || {
        echo ""
        echo "  (operational detail needs the definition artifact; it could not be fetched)"
        return 0
    }
    local info="$dir/template-info.yaml"
    [[ -f "$info" ]] || return 0
    [[ "$(yq -r 'has("operational")' "$info" 2>/dev/null)" == "true" ]] || return 0

    local v
    print_subsection "What installing this does" 2>/dev/null || { echo ""; echo "What installing this does"; }

    v=$(yq -r '.operational.install.deploys // [] | join(", ")' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  deploys      $v"
    v=$(yq -r '.operational.install.takes // ""' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  takes        $v"

    # The single most important line for an operator: does anything RUN?
    v=$(yq -r '.operational.automation // ""' "$info" 2>/dev/null)
    [[ -n "$v" ]] && { echo ""; echo "  automation   $v"; }

    v=$(yq -r '.operational.install.note // ""' "$info" 2>/dev/null)
    [[ -n "$v" ]] && { echo ""; echo "  note         $v"; }

    # ⚠️ The gap that costs a novice days: enabling the schedules does not
    # backfill, so a fresh install stays empty until the next cron fire.
    if [[ "$(yq -r '.operational | has("first_data")' "$info" 2>/dev/null)" == "true" ]]; then
        echo ""
        echo "Getting data in (the schedules do NOT backfill):"
        v=$(yq -r '.operational.first_data.why // ""' "$info" 2>/dev/null)
        [[ -n "$v" ]] && echo "  why          $v"
        v=$(yq -r '.operational.first_data.how // ""' "$info" 2>/dev/null)
        [[ -n "$v" ]] && echo "  how          $v"
        v=$(yq -r '.operational.first_data.jobs // [] | join(" -> ")' "$info" 2>/dev/null)
        [[ -n "$v" ]] && echo "  jobs         $v"
        v=$(yq -r '.operational.first_data.takes // ""' "$info" 2>/dev/null)
        [[ -n "$v" ]] && echo "  takes        $v"
    fi

    if [[ "$(yq -r '.operational | has("cadence")' "$info" 2>/dev/null)" == "true" ]]; then
        echo ""
        echo "Once the schedules are enabled ($(yq -r '.operational.timezone // "UTC"' "$info" 2>/dev/null)):"
        yq -r '.operational.cadence[] | "  " + (.cron // "?") + "   " + (.what // "")' "$info" 2>/dev/null
    fi

    v=$(yq -r '.operational.external_services // [] | join(", ")' "$info" 2>/dev/null)
    [[ -n "$v" ]] && { echo ""; echo "  contacts     $v"; }
    v=$(yq -r '.operational.unscheduled // [] | join(", ")' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  never runs   $v (no schedule)"
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
    local template="$1" field="$2" out
    out=$(printf '%s' "$template" | jq -r --arg f "$field" '.source[$f] // empty' 2>/dev/null) || out=""
    printf '%s' "$out"
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

    # ⚠️ TPL-Q5, answered by running it: `install_type: stack` is NOT the right
    # discriminator for an application, and requiring it rejected the first
    # fixture I wrote from the spec's own §5 shape — which declares
    # `kind: application` and no install_type.
    #
    # So both are accepted, and they mean different things:
    #   install_type: stack   Terje's April format, a catalogue-resident template
    #   kind: application     an application shipping its own definition (#361)
    #
    # Not collapsed into one field: the two are resolved differently (folder
    # checkout vs oras pull) and a reader needs to be able to tell which kind of
    # thing they are looking at from the file itself, without the registry.
    #
    # `install_type: application` is accepted as a third spelling, because the
    # catalogue's own stub for an application authors exactly that field
    # (dev-templates, urb-agents#479 — `templateKind` is DERIVED there, so
    # `install_type` is the only field a human writes). A tenant who mirrors the
    # catalogue stub in their artifact should not be refused for it.
    local install_type kind
    install_type=$(_yaml_field "$info_file" ".install_type")
    kind=$(_yaml_field "$info_file" ".kind")
    if [[ "$install_type" != "stack" && "$install_type" != "application" && "$kind" != "application" ]]; then
        log_error "A definition needs 'install_type: stack', 'install_type: application' or 'kind: application'."
        echo "  Got install_type='$install_type' kind='$kind'." >&2
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
                # 🔴 A SCALAR IS LEGAL AND USED TO BE SILENTLY DISCARDED.
                #
                # This read only handled the list form: `"a-string" | join(",")`
                # errors in yq, `2>/dev/null` swallowed it, `v` came back empty
                # and the line was never written. atlas declares a scalar —
                # because MY OWN example on urb-agents#480 showed a scalar —
                # while the fixture uses a list, so every fixture round passed
                # and the first real application lost the field.
                #
                # The consequence was invisible until a clean-slate install:
                # the code location came up with no `envFrom`, so a freshly
                # installed atlas could not reach the database UIS had just
                # created for it. Four rounds missed it because a hand-written
                # pre-catalogue entry on that cluster was supplying the secret
                # (imac, urb-agents#491).
                # `[x] | flatten | join(",")` accepts a scalar AND a list:
                # ["s"] -> "s", [["a","b"]] -> "a,b", [""] -> "". mikefarah yq
                # has no `if`, and a type switch in bash would be a second
                # place for the two forms to disagree.
                v=$(yq -r "[.provides.services[$idx].config.code_location.env_secrets // \"\"] | flatten | join(\",\")" "$info_file" 2>/dev/null)
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

# Read one field from a JSON string, safely under `set -e`.
#
# ⚠️ `x=$(echo "$j" | jq -r '.f')` ABORTS the function when $j is not JSON: jq
# exits 4, the assignment inherits it, and `set -e` kills the caller before any
# branch that would have handled it. That is how `template remove --purge`
# dropped the roles correctly, printed none of its reporting, skipped
# _forget_application, and exited 4 (imac, urb-agents#367).
#
# The failure was *inside the guard written to stop the previous one*: the
# INCOMPLETE branch existed to keep a failure from being rounded up to success,
# and could never run. So the guard is a function now, with a test, rather than
# a line repeated at six call sites.
#
# Returns empty and succeeds when the input is not JSON or the field is absent.
# A caller that needs to tell those apart should test the value, not the status.
_json_field() {
    local json="$1" path="$2" out
    out=$(printf '%s' "$json" | jq -r "$path // empty" 2>/dev/null) || out=""
    printf '%s' "$out"
}

# ─── The installed-applications record ────────────────────────────────────────
#
# `.uis.extend/applications.yaml` — installation config, not product config, the
# same relationship as dagster-code-locations.yaml. It answers three questions
# nothing else can: what is installed, at which pin, and what each application
# exports for a dependant to read.
#
# ⚠️ It is also what makes `requires:` a refusal rather than a guess. Without a
# record, "is atlas installed?" could only be answered by probing the cluster
# for symptoms — a database here, a code location there — and a probe that
# infers presence is a probe that eventually infers it wrongly.
_applications_file() {
    echo "$(_uis_extend_dir)/applications.yaml"
}

_applications_init() {
    local file
    file="$(_applications_file)"
    mkdir -p "$(dirname "$file")" || return 1
    if [[ ! -f "$file" ]]; then
        printf '# Applications installed on THIS installation, written by\n' > "$file"
        printf '# `uis template install`. Installation config, not product config.\n' >> "$file"
        printf 'applications: []\n' >> "$file"
    fi
    return 0
}

# How many tenants of this template id are recorded?
# More than one means `remove <id>` and `requires: <id>` are both ambiguous.
_application_count() {
    local id="$1" file
    file="$(_applications_file)"
    [[ -f "$file" ]] || { printf '0'; return 0; }
    app_id="$id" yq -r '[.applications[] | select(.id == strenv(app_id))] | length' "$file" 2>/dev/null
}

# The app_names recorded for this template id, newline separated.
_application_app_names() {
    local id="$1" file
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 0
    app_id="$id" yq -r '.applications[] | select(.id == strenv(app_id)) | .app_name // ""' "$file" 2>/dev/null
}

# Is an application installed here?
_application_installed() {
    local id="$1" file
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 1
    # AT LEAST one — a template may now have several tenants. Callers that
    # cannot tolerate ambiguity check _application_count themselves.
    [[ "$(app_id="$id" yq -r '[.applications[] | select(.id == strenv(app_id))] | length' "$file" 2>/dev/null)" -ge 1 ]]
}

# Read one export of an installed application.
_application_export() {
    local id="$1" key="$2" file
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 0
    app_id="$id" exp_key="$key" yq -r \
        '.applications[] | select(.id == strenv(app_id)) | .exports[strenv(exp_key)] // ""' \
        "$file" 2>/dev/null
}

# Record an installed application. Filter-then-append on `id`, the same shape as
# the code-location writer, so a re-install converges rather than duplicating.
# Values go through strenv() for the same reason.
#
# 🔴 `app_name` is recorded because REMOVAL DERIVES EVERY PER-APP NAME FROM IT.
# It used to derive them from the record `id`, which is the same string only
# when `--param app_name=` was not used. When they differ, `remove` targeted a
# DIFFERENT TENANT: on imac's cluster the plan for removing `atlas` (installed
# as `atlast`) listed `postgrest --app atlas` — the live tenant serving 13
# views — and named the live database in its "will NOT remove" notice. Only the
# confirmation prompt stood between that and an outage (urb-agents#481).
#
# ⚠️ The fixture rounds could not find it: `uisfix`'s template id and its
# app_name were the same string, so the two could not diverge. imac's note is
# worth keeping — a fixture whose id and app_name DIFFER would have caught this
# on Tuesday. Storing the resolved value rather than reconstructing it is the
# same lesson as the code-location name, one field further along.
_record_application() {
    local app_id="$1" artifact="$2" tag="$3" digest="$4" services="$5" code_locations="$6" exports_json="${7:-{\}}" requires_csv="${8:-}" app_name="${9:-}"
    local file
    file="$(_applications_file)"
    _applications_init || return 1

    # ⚠️ Refuse an empty app_name. The filter below removes every entry whose
    # app_name differs from this one, so recording with "" would wipe every
    # record written before 1.6.29 — those carry no app_name at all. A missing
    # app_name means the params file lost it: a bug worth stopping on, not a
    # value worth writing.
    if [[ -z "$app_name" ]]; then
        log_error "Refusing to record '$app_id' with no app_name."
        echo "  The record is keyed on app_name; an empty one would collide with" >&2
        echo "  every record that predates 1.6.29." >&2
        return 1
    fi

    # 🔴 KEYED ON app_name, NOT id. Two installs of one template with different
    # `--param app_name` are two tenants, and keying on the template id made the
    # second SILENTLY REPLACE the first's record — leaving the first deployed,
    # healthy, serving traffic and unremovable by the tool that installed it
    # (imac, urb-agents#492, reproduced on a clean cluster).
    #
    # That is the direct consequence of `--param app_name` existing, and it is
    # the workflow this project recommends: a live tenant plus a test one.
    local expr='.applications = ((.applications // [])
        | map(select(.app_name != strenv(app_name)))
        + [{
            "id":        strenv(app_id),
            "artifact":  strenv(artifact),
            "tag":       strenv(tag),
            "pin":       strenv(digest),
            "installed": strenv(installed_at),
            "services":       (strenv(services)       | split(",") | map(select(. != ""))),
            "code_locations": (strenv(code_locations) | split(",") | map(select(. != ""))),
            "requires":       (strenv(requires_csv)   | split(",") | map(select(. != ""))),
            "app_name":  strenv(app_name),
            "exports":   (strenv(exports_json) | from_json)
          }])'

    if ! app_id="$app_id" artifact="$artifact" tag="$tag" digest="$digest" \
         installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         services="$services" code_locations="$code_locations" \
         requires_csv="$requires_csv" \
         app_name="$app_name" \
         exports_json="$exports_json" \
         yq -i "$expr" "$file"; then
        log_error "Failed to record application '$app_id' in $file"
        return 1
    fi
    echo "Recorded '$app_id' at $digest in $file" >&2
    return 0
}

# Forget ONE tenant, by app_name — not every tenant of a template id.
_forget_application() {
    local app_name="$1" file
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 0
    app_name="$app_name" yq -i '.applications = ((.applications // []) | map(select(.app_name != strenv(app_name))))' "$file"
}

# Which installed applications declare a requires on <id>?
# Used by `template remove` to refuse while a dependant is still installed.
#
# 🔴 This reads `.requires` from the RECORD, so `_record_application` must write
# it. It did not, for two shipped versions: the field was read by a refusal that
# could therefore never fire, while the CLI reference documented the refusal as
# real. Fifth instance of the class in `PLAN-system-error-paths-audit` — a guard
# whose input nothing produces — and the reason the tests below assert the
# round trip (record it, then read it back) rather than only the reader.
_applications_requiring() {
    local id="$1" file
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 0
    # ⚠️ NOT `contains([strenv(app_id)])`. In jq and yq alike, `contains` does
    # SUBSTRING matching on string elements: ["atlas-data"] | contains(["atlas"])
    # is true. So removing `atlas` would have been blocked by an application that
    # requires `atlas-data`, naming a dependant that does not depend on it — and
    # `atlas-data` itself would not have been protected from `atlas`'s requires,
    # because the substring relation runs one way only. Exact membership.
    app_id="$id" yq -r \
        '[.applications[]
          | select([.requires // [] | .[] | select(. == strenv(app_id))] | length > 0)
          | .id] | join(", ")' \
        "$file" 2>/dev/null
}

# ⚠️ requires: REFUSES, it never auto-installs. Installing an application must
# not silently install another: the second one's schemas:-type decisions are a
# person's, and #350 is what that looks like when taken seriously.
_check_requires() {
    local info_file="$1" template_id="$2"
    local n i dep_id dep_provides missing=0
    n=$(yq -r '.requires // [] | length' "$info_file" 2>/dev/null)
    [[ -z "$n" || "$n" == "0" ]] && return 0

    for ((i=0; i<n; i++)); do
        dep_id=$(yq -r ".requires[$i].application // \"\"" "$info_file" 2>/dev/null)
        dep_provides=$(yq -r ".requires[$i].provides // \"\"" "$info_file" 2>/dev/null)
        [[ -z "$dep_id" ]] && continue

        # ⚠️ An id with several tenants cannot answer "which api-url?".
        # Refuse rather than pick one — picking is what made a tenant
        # unmanageable on urb-agents#492.
        local dep_n
        dep_n="$(_application_count "$dep_id")"
        if [[ "${dep_n:-0}" -gt 1 ]]; then
            log_error "'$template_id' requires '$dep_id', which has $dep_n installed tenants."
            echo "  Their exports differ, and nothing here can say which one you mean:" >&2
            _application_app_names "$dep_id" | sed 's/^/    /' >&2
            echo "  Remove the tenants you do not want, or give the dependency its own id." >&2
            return 1
        fi

        if ! _application_installed "$dep_id"; then
            log_error "'$template_id' requires the application '$dep_id', which is not installed here."
            echo "  Install it first:" >&2
            echo "    ./uis template install $dep_id" >&2
            echo "  Not installed automatically on purpose: an application's own" >&2
            echo "  exposure decisions are a person's to make." >&2
            missing=1
            continue
        fi
        if [[ -n "$dep_provides" ]]; then
            if [[ -z "$(_application_export "$dep_id" "$dep_provides")" ]]; then
                log_error "'$template_id' needs '$dep_provides' from '$dep_id', which records no such export."
                echo "  '$dep_id' is installed but exports:" >&2
                app_id="$dep_id" yq -r '.applications[] | select(.id == strenv(app_id)) | .exports | keys | .[]' \
                    "$(_applications_file)" 2>/dev/null | sed 's/^/    /' >&2
                echo "  Re-installing '$dep_id' at a newer pin may add it." >&2
                missing=1
            fi
        fi
    done
    [[ "$missing" -eq 0 ]]
}

# Substitute {{ requires.<id>.<key> }} from the recorded exports.
_substitute_requires() {
    local text="$1"
    local token id key val
    while [[ "$text" =~ \{\{[[:space:]]*requires\.([a-zA-Z0-9_-]+)\.([a-zA-Z0-9_-]+)[[:space:]]*\}\} ]]; do
        id="${BASH_REMATCH[1]}"; key="${BASH_REMATCH[2]}"
        token="${BASH_REMATCH[0]}"
        val="$(_application_export "$id" "$key")"
        text="${text//"$token"/$val}"
    done
    echo "$text"
}

# ─── The configure argument list — ONE construction, two callers ──────────────
#
# 🔴 The dry-run printer and the executor each built this list by hand, with a
# comment on the printer saying "same argument construction as the executor
# below … the falsification for this phase is that they agree." They did not
# agree, and nothing ran the comparison.
#
# 1.6.31 fixed the `--database` fallback in the printer and left the executor
# without it — I put the `plan_database` computation INSIDE the
# `if [[ "$dry_run" == true ]]` branch, so a real install never computed it.
# The printed plan said `configure postgrest --app atlas-t --database atlas-t`
# and the run executed the same command WITHOUT `--database` (imac,
# urb-agents#481 round 3).
#
# ⚠️ imac's point is the one that matters, and it is not about the hyphen:
# `--dry-run` is the instrument an operator uses to decide whether an install
# will touch a live tenant. Before the fix, plan and execution agreed and the
# install failed honestly. After it, the plan was a description of something
# that did not happen — which makes the safety check unsound, and is strictly
# worse than the bug it replaced.
#
# So: not two lists and a test that they match. ONE list. Divergence is now
# unrepresentable rather than merely asserted against.
#
# Emits one argument per line, so a caller reads it with `mapfile`.
_build_configure_args() {
    local svc="$1" conf="$2" params_file="$3" app_name="$4" plan_database="$5" want_json="${6:-}"

    printf '%s\n' "$svc" "--app" "$app_name"
    [[ -n "$want_json" ]] && printf '%s\n' "--json"

    local v
    v=$(_substitute_params "$(_conf_get "$conf" database)" "$params_file")
    # This service's own `database:` wins; otherwise it is told the plan's, so
    # no handler has to infer a name the plan already holds.
    v="${v:-$plan_database}"
    [[ -n "$v" ]] && printf '%s\n' "--database" "$v"
    v=$(_substitute_params "$(_conf_get "$conf" schemas)" "$params_file")
    [[ -n "$v" ]] && printf '%s\n' "--schemas" "$v"
    v=$(_substitute_params "$(_conf_get "$conf" url_prefix)" "$params_file")
    [[ -n "$v" ]] && printf '%s\n' "--url-prefix" "$v"
    v=$(_substitute_params "$(_conf_get "$conf" namespace)" "$params_file")
    [[ -n "$v" ]] && printf '%s\n' "--namespace" "$v"
    v=$(_substitute_params "$(_conf_get "$conf" secret_name_prefix)" "$params_file")
    [[ -n "$v" ]] && printf '%s\n' "--secret-name-prefix" "$v"
    v=$(_substitute_params "$(_conf_get "$conf" init)" "$params_file")
    [[ -n "$v" ]] && printf '%s\n' "--init-file" "-"
    return 0
}

# The Secret THIS INSTALL creates, if any: `<secret_name_prefix>-db`.
#
# 🔴 UIS wires it into the code location itself rather than asking the
# definition to name it. The name is UIS's own construction — `configure
# postgresql --secret-name-prefix p` writes `p-db` — so requiring the artifact
# to repeat it is the two-places-must-agree shape behind the last four defects,
# and a definition that hard-codes it is wrong the moment someone installs with
# `--param app_name`. imac's argument on urb-agents#491, and it is right.
#
# An explicit `env_secrets:` still works and is added alongside: an application
# may need secrets this install did not create.
_plan_env_secret() {
    local plan_dir="$1" params_file="$2" f prefix
    for f in "$plan_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        prefix=$(_substitute_params "$(_conf_get "$f" secret_name_prefix)" "$params_file")
        if [[ -n "$prefix" ]]; then printf '%s-db' "$prefix"; return 0; fi
    done
    return 0
}

# The plan's database: whichever service declares one, that is THE database for
# the whole install. Computed once, at function scope — putting this inside the
# dry-run branch is precisely what made the printer and the executor disagree.
_plan_database() {
    local plan_dir="$1" params_file="$2" f db
    for f in "$plan_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        db=$(_substitute_params "$(_conf_get "$f" database)" "$params_file")
        if [[ -n "$db" ]]; then printf '%s' "$db"; return 0; fi
    done
    return 0
}

# Read one key out of the effective-params file (key=value lines).
# Used to record `app_name`, which removal depends on — see _record_application.
_conf_param() {
    local params_file="$1" key="$2"
    [[ -f "$params_file" ]] || return 0
    sed -n "s/^${key}=//p" "$params_file" | head -1
}

# Resolve the definition's `exports:` into a JSON object for the record.
# Values may reference {{ params.* }} and {{ requires.*.* }}; _substitute_params
# does both.
_collect_exports() {
    local info_file="$1" params_file="$2"
    local keys k v out="{}"
    keys=$(yq -r '.exports // {} | keys | .[]' "$info_file" 2>/dev/null)
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        v=$(yq -r ".exports.\"$k\" // \"\"" "$info_file" 2>/dev/null)
        v=$(_substitute_params "$v" "$params_file")
        out=$(exp_k="$k" exp_v="$v" echo "$out" | exp_k="$k" exp_v="$v" yq -o=json -I0 '.[strenv(exp_k)] = strenv(exp_v)' 2>/dev/null || echo "$out")
    done <<< "$keys"
    echo "$out"
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

# Substitute {{ params.* }} references using a params file (key=value lines),
# and {{ requires.<id>.<key> }} from the recorded exports of installed
# applications. One function so every field gets both — the alternative is
# remembering which call sites need which, which is how `schemas` and
# `url_prefix` went unsubstituted in the first version of templates-001.
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

    _substitute_requires "$text"
}

# Build effective params from YAML defaults + CLI overrides
# Outputs key=value lines to stdout
_build_effective_params() {
    local info_file="$1"
    # yq to emit params as key=value lines
    yq -r '.params // {} | to_entries | .[] | "\(.key)=\(.value)"' "$info_file" 2>/dev/null
}

# Command: uis template remove <id> [--purge] [--yes]
#
# The inverse of install, and deliberately NOT symmetrical about data.
#
# UIS already draws this line: `undeploy` removes Kubernetes objects and leaves
# roles, secrets and databases; `configure --purge` is the destructive one you
# ask for. `template remove` follows it, because an application's database is
# the one thing that cannot be reconstructed by reinstalling.
#
# So by default this removes what the install ADDED and nothing that the
# application PRODUCED:
#   - the code-location entries, then redeploy dagster
#   - per-app instances of multi-instance services (undeploy <svc> --app <id>)
#   - the application record
# and leaves databases, roles and secrets, saying so.
#
# ⚠️ Single-instance services are never undeployed. `postgresql` is shared; an
# application does not own it and removing an application must not take the
# platform's database with it.
cmd_template_remove() {
    # Flags in any order, id anywhere — the same loop shape `configure` uses
    # (configure.sh:90-140), where the first bare word is the subject. The
    # positional-first version rejected `remove --yes uisfix` with "Unexpected
    # argument", which is a confusing way to say "wrong order" for something the
    # rest of the CLI accepts.
    local template_id="" purge=false assume_yes=false want_app=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=true; shift ;;
            --app) want_app="${2:-}"; shift 2 ;;
            --yes|-y) assume_yes=true; shift ;;
            -*) log_error "Unknown option: $1"; return 1 ;;
            *)
                if [[ -z "$template_id" ]]; then
                    template_id="$1"
                else
                    log_error "Unexpected argument: $1 (application id already given as '$template_id')"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$template_id" ]]; then
        log_error "Usage: uis template remove <id> [--app <name>] [--purge] [--yes]"
        return 1
    fi
    if ! command -v yq >/dev/null 2>&1; then
        log_error "yq is required to read the application record and is not installed."
        return 1
    fi
    if ! _application_installed "$template_id"; then
        log_error "'$template_id' is not recorded as installed on this installation."
        echo "  Installed applications:" >&2
        yq -r '.applications[].id' "$(_applications_file)" 2>/dev/null | sed 's/^/    /' >&2
        return 1
    fi

    # Refuse while a dependant is installed.
    local dependants
    dependants="$(_applications_requiring "$template_id")"
    if [[ -n "$dependants" ]]; then
        log_error "Cannot remove '$template_id': still required by $dependants."
        echo "  Remove the dependant first:" >&2
        echo "    ./uis template remove ${dependants%%,*}" >&2
        return 1
    fi

    # 🔴 Every per-app name below comes from the RECORDED app_name, never from
    # the record id. They are the same string only when `--param app_name=` was
    # not used; when they differ, deriving from the id targets a DIFFERENT
    # TENANT. imac hit exactly that: removing `atlas` (installed as `atlast`)
    # planned to undeploy `postgrest --app atlas`, the live instance serving 13
    # views, and named the live database in its own "will NOT remove" notice.
    local file svcs cls app_name
    file="$(_applications_file)"
    # 🔴 One template id may now have SEVERAL tenants (`--param app_name`).
    # Removing by id alone is ambiguous the moment it does, and guessing is how
    # the first tenant became unremovable in the first place.
    local n_tenants
    n_tenants="$(_application_count "$template_id")"
    if [[ "${n_tenants:-0}" -gt 1 && -z "$want_app" ]]; then
        log_error "'$template_id' has $n_tenants installed tenants — say which one."
        echo "  Installed as:" >&2
        _application_app_names "$template_id" | sed 's/^/    --app /' >&2
        echo "  e.g. ./uis template remove $template_id --app $(_application_app_names "$template_id" | head -1)" >&2
        return 1
    fi

    if [[ -n "$want_app" ]]; then
        app_name="$want_app"
        if ! app_name="$want_app" app_id="$template_id" yq -e \
             '[.applications[] | select(.id == strenv(app_id) and .app_name == strenv(app_name))] | length == 1' \
             "$file" >/dev/null 2>&1; then
            log_error "No installed tenant of '$template_id' with app_name '$want_app'."
            echo "  Installed as:" >&2
            _application_app_names "$template_id" | sed 's/^/    /' >&2
            return 1
        fi
    else
        app_name=$(app_id="$template_id" yq -r \
            '.applications[] | select(.id == strenv(app_id)) | .app_name // ""' "$file" 2>/dev/null)
    fi

    if [[ -z "$app_name" ]]; then
        # A record written before 1.6.29 carries no app_name and there is no way
        # to recover it — the definition is not fetched on the remove path. The
        # id is the best guess and it is the guess that caused the defect, so it
        # is used only with the operator looking at it.
        log_warn "This record predates app_name and does not carry one."
        echo "  Falling back to the application id '$template_id' for every per-app" >&2
        echo "  name below. If this application was installed with --param app_name=," >&2
        echo "  THOSE NAMES BELONG TO A DIFFERENT TENANT — check the plan before" >&2
        echo "  confirming, and remove by hand if it names something you did not install." >&2
        app_name="$template_id"
        if [[ "$assume_yes" == true ]]; then
            log_error "Refusing --yes on a record with no app_name."
            echo "  The plan below cannot be verified against what was installed, and" >&2
            echo "  the failure mode is undeploying somebody else's instance. Re-run" >&2
            echo "  without --yes and read it." >&2
            return 1
        fi
    fi
    # Newline-separated and read line-wise: a name is a Kubernetes name and
    # should never contain a space, but word-splitting a recorded value is
    # exactly how the raw-template bug turned one entry into three tokens.
    # Selected by app_name, so a second tenant's services and code locations are
    # never read for the one being removed.
    svcs=$(app_name="$app_name" yq -r '.applications[] | select(.app_name == strenv(app_name)) | (.services // []) | .[]' "$file" 2>/dev/null)
    cls=$(app_name="$app_name" yq -r '.applications[] | select(.app_name == strenv(app_name)) | (.code_locations // []) | .[]' "$file" 2>/dev/null)

    print_section "Removing application: $template_id"
    echo "Will remove:"
    local svc
    while IFS= read -r svc; do [[ -n "$svc" ]] && echo "  code location  $svc"; done <<< "$cls"
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && _service_is_multi_instance "$svc" && echo "  instance       $svc --app $app_name"
    done <<< "$svcs"
    echo "  the application record"
    if [[ "$purge" == true ]]; then
        while IFS= read -r svc; do
            [[ -n "$svc" ]] && _service_is_multi_instance "$svc" \
                && echo "  ⚠️ $svc per-app Postgres roles and its Secret (--purge)"
        done <<< "$svcs"
    fi
    echo ""
    echo "Will NOT remove (an application's data outlives its install):"
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && ! _service_is_multi_instance "$svc" && echo "  $svc — shared, single-instance"
    done <<< "$svcs"

    # ⚠️ Enumerate what --purge CANNOT reach, by name, before the prompt.
    #
    # `configure postgresql` has no --purge at all, so the application's own
    # database, its owning role, and the Secret written by
    # `--namespace/--secret-name-prefix` cannot be dropped by any UIS command
    # today. An earlier version announced "per-app Postgres roles and secrets
    # WILL be dropped" and dropped none of it — exit 0, twice-announced, nothing
    # done (imac, urb-agents#367).
    #
    # That was the third announced-action-no-action in this feature. The lesson
    # I am applying: derive the message from what is actually callable, and name
    # the gap rather than rounding it off.
    local app_user="${app_name//-/_}"
    echo "  the '$app_name' database and its owning role '$app_user'"
    echo "  any Secret written by configure postgresql --secret-name-prefix"
    if [[ "$purge" == true ]]; then
        echo ""
        echo "⚠️ --purge does NOT cover those: configure postgresql has no purge."
        echo "   To finish by hand afterwards:"
        echo "     ./uis connect postgresql   then:  DROP DATABASE \"$app_name\"; DROP ROLE $app_user;"
        echo "     kubectl delete secret <prefix>-db -n <namespace>"
        echo "   Tracked as PLAN-cli-configure-postgresql-purge."
    fi
    echo ""

    if [[ "$assume_yes" != true ]]; then
        local reply
        read -r -p "Proceed? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }
    fi

    local had_cl=false
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        _remove_code_location "$svc" && had_cl=true
        echo "Removed code location '$svc'" >&2
    done <<< "$cls"
    if [[ "$had_cl" == true ]]; then
        log_info "Redeploying dagster so the removal takes effect..."
        uis deploy dagster >&2 || log_warn "dagster redeploy failed; the entry IS removed — run './uis deploy dagster' when ready"
    fi

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if _service_is_multi_instance "$svc"; then
            log_info "Undeploying $svc --app $app_name..."
            if ! uis undeploy "$svc" --app "$app_name" --yes >&2; then
                log_warn "undeploy $svc --app $app_name failed; continuing"
            fi

            # ⚠️ `configure --purge`, NOT `undeploy --purge`.
            #
            # undeploy removes Kubernetes objects and LEAVES the Postgres roles
            # and the Secret — it says so in its own output, and the non-purge
            # path prints `configure <svc> --app <name> --purge` as the hint for
            # removing them. So the code already knew the right verb and called
            # the other one: --purge announced the drop twice and performed
            # none, exit 0 (imac, urb-agents#367).
            #
            # Reported from the handler's own JSON rather than assumed, because
            # the whole defect was assuming a call did what its name suggested.
            if [[ "$purge" == true ]]; then
                log_info "Purging per-app roles and Secret for $svc..."
                # ⚠️ NO `2>&1`. `configure --purge --json` writes a human line to
                # stderr before the JSON, so merging the streams made $purge_out
                # not-JSON — which is what tripped the parse. stderr is captured
                # separately so the failure branch can still show it.
                local purge_out purge_err purge_rc=0
                purge_err="$(mktemp)"
                purge_out=$(uis configure "$svc" --app "$app_name" --purge --json 2>"$purge_err") || purge_rc=$?
                local purge_status
                purge_status="$(_json_field "$purge_out" '.status')"
                case "$purge_status" in
                    purged)
                        echo "  dropped: $(_json_field "$purge_out" '(.roles_dropped // []) | join(", ")')" >&2
                        echo "  removed: $(_json_field "$purge_out" '.secret_removed')" >&2
                        results+="$svc: purged"$'\n'
                        ;;
                    *)
                        log_warn "Purge of $svc did not report success (exit $purge_rc)."
                        [[ -n "$purge_out" ]] && echo "  stdout: $purge_out" >&2
                        [[ -s "$purge_err" ]] && echo "  stderr: $(cat "$purge_err")" >&2
                        echo "  Roles and Secret for '$app_name' may still exist. To finish:" >&2
                        echo "    ./uis configure $svc --app $app_name --purge" >&2
                        results+="$svc: purge INCOMPLETE"$'\n'
                        ;;
                esac
                rm -f "$purge_err"
            fi
        fi
    done <<< "$svcs"

    _forget_application "$app_name"
    print_section "Removed: $template_id"
    if [[ "$purge" != true ]]; then
        echo "Per-app roles, Secrets and databases were left in place. To drop them:"
        while IFS= read -r svc; do
            [[ -n "$svc" ]] && _service_is_multi_instance "$svc" && echo "  ./uis configure $svc --app $app_name --purge"
        done <<< "$svcs"
        echo "  and by hand, the database and owning role — see PLAN-cli-configure-postgresql-purge"
    else
        echo "The '$app_name' database and its owning role were NOT dropped."
        echo "No UIS command does that yet; see PLAN-cli-configure-postgresql-purge."
    fi
    return 0
}

# Command: uis template install <id># Command: uis template install <id>
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

    # ─── resolve the definition ───────────────────────────────────────────────
    #
    # Two kinds of entry, and the discriminator is `templateKind`:
    #
    #   application  — ships its definition as its OWN OCI artifact beside its
    #                  image; resolved with `oras pull` at a digest (#361).
    #   stack        — Terje's April-format templates that live in the catalogue
    #                  repository itself (e.g. postgresql-demo); resolved by a
    #                  sparse checkout of `folder`.
    #
    # The git form was dropped for APPLICATIONS, not for these: a stack template
    # has no artifact to point at, and removing its path would break the one
    # template the catalogue currently has.
    local template_dir template_kind
    template_kind="$(_json_field "$template" '.templateKind // .kind')"

    if [[ "$template_kind" == "application" ]]; then
        _require_source_fields "$template" "$template_id" || return 1
        SOURCE_ARTIFACT=$(_template_source_field "$template" artifact)
        SOURCE_TAG=$(_template_source_field "$template" tag)
        SOURCE_DIGEST=$(_template_source_field "$template" digest)
        local visibility
        visibility="$(_json_field "$template" '.visibility')"; visibility="${visibility:-public}"

        template_dir=$(_resolve_definition "$template_id" \
            "$SOURCE_ARTIFACT" "$SOURCE_TAG" "$SOURCE_DIGEST" "$visibility") || return 1
        if [[ -z "$template_dir" || ! -d "$template_dir" ]]; then
            log_error "Failed to resolve the install definition for '$template_id'"
            return 1
        fi
    else
        local folder
        folder="$(_json_field "$template" '.folder')"
        if [[ -z "$folder" ]]; then
            log_error "Template '$template_id' is not an application and has no folder field."
            echo "  An application entry needs templateKind: application and a source;" >&2
            echo "  a stack template needs a folder in the catalogue repository." >&2
            return 1
        fi
        template_dir=$(_fetch_template_folder "$folder")
        if [[ -z "$template_dir" || ! -d "$template_dir" ]]; then
            log_error "Failed to fetch template folder"
            return 1
        fi
    fi

    local info_file="$template_dir/template-info.yaml"

    # Validate
    if ! _validate_template_info "$info_file" "$template_dir"; then
        return 1
    fi

    # ⚠️ The artifact must agree with the catalogue about what it is.
    #
    # Nothing compared these before: a registry entry `atlas` pointing at an
    # artifact whose definition says `id: something-else` installed anyway and
    # was RECORDED as atlas — so `applications.yaml`, `requires:` and `remove`
    # would all have been reasoning about an identity the artifact never
    # claimed. Two sides of a seam disagreeing in silence.
    #
    # An absent `id:` is tolerated (the field is not required by
    # _validate_template_info and a fixture may omit it); a CONFLICTING one is
    # refused, naming both, because a mismatch is either a mis-generated
    # catalogue entry or a pointer at the wrong artifact and the operator
    # cannot tell which from a success.
    local definition_id
    definition_id=$(_yaml_field "$info_file" ".id")
    if [[ -n "$definition_id" && "$definition_id" != "$template_id" ]]; then
        log_error "Identity mismatch: the catalogue entry is '$template_id' but the artifact says '$definition_id'."
        echo "  Artifact: ${SOURCE_ARTIFACT:-<local>}@${SOURCE_DIGEST:-<none>}" >&2
        echo "  Either the catalogue entry points at the wrong artifact, or the" >&2
        echo "  artifact was published under the wrong id. Refusing rather than" >&2
        echo "  recording '$template_id' for a definition that calls itself" >&2
        echo "  '$definition_id'." >&2
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

    # ⚠️ requires: is checked BEFORE anything is deployed. A refusal after the
    # first service has landed is worse than one before, because the operator is
    # then holding a half-installed application and a message about a different
    # one.
    _check_requires "$info_file" "$template_id" || return 1

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
    # An application has no folder — it has an artifact and a pin. Printing an
    # empty "Template folder:" was the first thing the fixture run showed.
    if [[ "$template_kind" == "application" ]]; then
        echo "Artifact: ${SOURCE_ARTIFACT}"
        echo "Pin:      ${SOURCE_DIGEST}  (tag ${SOURCE_TAG})"
    else
        echo "Template folder: ${folder:-<none>}"
    fi
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
    # 🔴 FUNCTION SCOPE, not inside the dry-run branch. Declaring it in there is
    # the exact mistake that made the printed plan differ from the executed one.
    local plan_database
    plan_database="$(_plan_database "$plan_dir" "$params_file")"

    if [[ "$dry_run" == true ]]; then
        print_section "Dry run: $template_id"
        echo "Commands that would run, in order:"
    # 🔴 ONE APPLICATION, ONE DATABASE — and the plan already knows its name.
    #
    # Each handler used to derive it independently when its own `config:` did
    # not carry `database:`, and they derive it DIFFERENTLY: postgresql keeps
    # what it is told, postgrest falls back to `app_name` with `-` -> `_`. So
    # `--param app_name=atlas-t` created the database `atlas-t` in step 2 and
    # then looked for `atlas_t` in step 3, one step later than the hyphen defect
    # 1.6.29 fixed (imac, urb-agents#481).
    #
    # They agreed for every earlier install only because no app_name had ever
    # contained a hyphen. Two derivations that happen to match are one bug
    # waiting for an input.
    #
    # So: whichever service in this plan declares `database:`, that is THE
    # database, and every other configurable service is told it rather than
    # guessing. Same rule as app_name in 1.6.29 — pass the resolved value, never
    # re-derive it.
        echo ""
        local n=0
        while IFS='|' read -r priority svc; do
            [[ -z "$svc" ]] && continue
            local conf="$plan_dir/${svc}.conf"
            local args=() first=false
            _service_is_multi_instance "$svc" && first=true

            # ⚠️ THE SAME FUNCTION THE EXECUTOR CALLS. Not "the same
            # construction" — the same code. `--json` is omitted here only
            # because it is noise in a plan a human reads; every other argument
            # is byte-identical by construction.
            local init
            if [[ -s "$conf" ]]; then
                mapfile -t args < <(_build_configure_args "$svc" "$conf" "$params_file" "$app_name" "$plan_database")
                init=$(_substitute_params "$(_conf_get "$conf" init)" "$params_file")
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

            # 🔴 Wire the Secret THIS INSTALL created, without being asked to.
            #
            # `configure postgresql --namespace <ns> --secret-name-prefix <p>`
            # wrote `<p>-db`, and the code location needs it or the application
            # comes up unable to reach the database UIS just made for it — a
            # clean install that reports EXIT=0 and cannot run its own ETL
            # (imac, urb-agents#491). The definition should not have to restate
            # a name UIS constructed; that is the two-places-must-agree shape,
            # and it breaks under `--param app_name`.
            #
            # Added only if not already listed, so an explicit declaration is
            # neither duplicated nor overridden.
            local plan_secret
            plan_secret="$(_plan_env_secret "$plan_dir" "$params_file")"
            if [[ -n "$plan_secret" && ",$cl_s," != *",$plan_secret,"* ]]; then
                cl_s="${cl_s:+$cl_s,}$plan_secret"
                log_info "Wiring the Secret this install created into '$cl_n': $plan_secret"
            fi

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

            # ⚠️ THE SAME FUNCTION THE DRY-RUN PRINTER CALLS. --app is
            # unconditional and that is deliberate: a single-instance service
            # can still hold per-app resources, which is exactly what
            # `configure postgresql --app` creates.
            local configure_args
            mapfile -t configure_args < <(_build_configure_args "$svc" "$conf" "$params_file" "$app_name" "$plan_database" json)

            log_info "Configuring $svc (args: ${configure_args[*]})..."
            local result configure_exit
            if [[ -n "$resolved_init" ]]; then
                # A file or a directory of ordered *.sql — see _collect_init_sql.
                local init_path="$template_dir/$resolved_init"
                local init_content
                init_content=$(_collect_init_sql "$init_path") || return 1
                init_content=$(_substitute_params "$init_content" "$params_file")
                # ⚠️ NOT appended here — _build_configure_args already emitted
                # `--init-file -` from the conf. Appending it again produced
                # `--init-file - --init-file -` on the executed command and NOT
                # on the printed one, which the plan-equals-execution test
                # caught within seconds of being written. This branch's job is
                # to produce the STDIN, not to add the flag.
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
            status="$(_json_field "$result" '.status')"
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
                    detail="$(_json_field "$result" '.detail')"
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

    # Record what was installed, at which pin, with its exports resolved.
    local inst_services inst_cls exports_json inst_requires
    inst_services=$(echo "$plan" | awk -F'|' 'NF>1{printf "%s%s", sep, $2; sep=","}')
    # ⚠️ SUBSTITUTED, not raw. The conf file holds the declaration verbatim —
    # `{{ params.app_name }}-data` — and recording that meant `template remove`
    # read a template instead of a name, word-split it into three tokens, and
    # reported removing three code locations that never existed while the real
    # one survived. A green removal with a live code location is worse than a
    # failure. imac, urb-agents#367.
    #
    # Fixed here rather than in remove: install already substitutes when it
    # WRITES the entry, so recording the same value keeps one source of truth
    # instead of two places that must agree.
    inst_cls=$(for f in "$plan_dir"/*.conf; do
                   [[ -f "$f" ]] || continue
                   n=$(_conf_get "$f" code_location_name)
                   [[ -n "$n" ]] && _substitute_params "$n" "$params_file"
               done | paste -sd, -)
    exports_json=$(_collect_exports "$info_file" "$params_file")
    # What this application requires, recorded so `remove` can refuse to take a
    # dependency out from under it. Read from the definition, never inferred.
    inst_requires=$(yq -r '[.requires // [] | .[] | .application // ""] | map(select(. != "")) | join(",")' \
                       "$info_file" 2>/dev/null) || inst_requires=""

    if [[ -n "${SOURCE_ARTIFACT:-}" ]]; then
        _record_application "$template_id" "$SOURCE_ARTIFACT" "$SOURCE_TAG" "$SOURCE_DIGEST" \
            "$inst_services" "$inst_cls" "$exports_json" "$inst_requires" \
            "$(_conf_param "$params_file" app_name)" || return 1
    else
        # A catalogue-less install (a local fixture, or a stack template that is
        # not an application) has no pin to record. Say so rather than writing a
        # record with empty fields that a later `requires` check would trust.
        echo "Note: no artifact pin for '$template_id', so no application record written." >&2
        echo "      A dependant's `requires: $template_id` will not see it." >&2
    fi

    print_section "Template Installation Complete"
    echo "$results"

    # 🔴 SAY WHERE IT IS. A successful install used to end without the URL
    # anywhere a user could find it: not in this summary, not in `uis status`,
    # not in `uis list`, and not even in `uis verify postgrest --app <id>`,
    # which makes the request and prints PASS without the address it used. The
    # URL existed once, at line 475 of a 701-line log, inside an Ansible debug
    # envelope — scroll past it and it is unrecoverable from the product
    # (imac, urb-agents#506, grading Atlas as a novice would).
    #
    # ⚠️ And it is not guessable. The route matches on HOSTNAME
    # (`HostRegexp('api-atlas\..+')`) while the only string a user has seen is
    # `--url-prefix api-atlas`, which suggests http://localhost/api-atlas/ —
    # a bare Traefik 404. Measured: http://api-atlas.localhost/ is 200.
    #
    # The definition already declares this, and the record already stores it:
    # `exports:` is where an application says what it published. Nothing new is
    # computed here — it is printed because it was already known.
    # ⚠️ A plain loop over a captured list, not `while read < <(…)`.
    # The process-substitution form yielded nothing here while the same
    # `_json_field` call returned the key correctly one line above it —
    # measured, not assumed. Not worth diagnosing bash for a six-line
    # summary block when a `for` over a captured string is clearer anyway.
    local _keys _ek _ev
    _keys="$(_json_field "$exports_json" 'keys | .[]')"
    if [[ -n "$_keys" ]]; then
        echo ""
        echo "Endpoints:"
        for _ek in $_keys; do
            _ev="$(_json_field "$exports_json" ".\"$_ek\"")"
            printf '  %-14s %s\n' "$_ek" "$_ev"
        done
    fi

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
        remove|uninstall)
            # ⚠️ NO `shift` here. run_template already shifted the subcommand off,
            # and the second shift ate an argument — which broke every documented
            # form: `remove uisfix --yes` passed only `--yes`, so the command
            # reported that '--yes' was not installed. imac, urb-agents#367.
            # Note that no sibling case shifts; this one was the odd one out.
            cmd_template_remove "$@"
            ;;
        ""|help|--help|-h)
            echo "Usage: uis template <command> [args]"
            echo ""
            echo "Commands:"
            echo "  list              List available UIS templates"
            echo "  info <id>         Show template details"
            echo "  install <id>      Install a template (deploy + configure services)"
            echo "  remove <id>       Remove an installed application (data is kept unless --purge)"
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
