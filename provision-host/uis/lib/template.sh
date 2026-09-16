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
# Apply `--version <tag>@<digest>`: install a version the catalogue does not
# point at, so a nominee can be verified BEFORE it is advertised to everyone.
#
# 🔴 THE DIGEST IS REQUIRED AND A BARE TAG IS REFUSED. Resolving the tag here
# would be the one place it must not happen: an off-catalogue install is exactly
# the case where nobody has pinned anything, so the tag is at its most likely to
# move — and a tag that moved between nomination and verification means
# verifying something else and reporting success. That is the dispatch race this
# project has already paid for once, and every nomination carries both values.
#
# ⚠️ THE ARTIFACT STILL COMES FROM THE CATALOGUE. This overrides WHICH VERSION,
# never WHERE FROM: the id must exist, and the allowlist still applies. A flag
# that could also redirect the source would be a different and much larger hole.
_apply_off_catalogue_version() {
    local template_id="$1" spec="${OFF_CATALOGUE_SPEC:-}"
    local tag="${spec%%@*}" digest="${spec#*@}"

    if [[ "$spec" != *"@"* || -z "$tag" || -z "$digest" ]]; then
        log_error "--version needs <tag>@<digest>, and '$spec' is not that."
        echo "  A tag alone is not accepted here, on purpose. Off-catalogue is" >&2
        echo "  precisely where nothing has pinned the tag, so it is where a tag" >&2
        echo "  is most likely to have moved since it was nominated — and" >&2
        echo "  verifying a different artifact than the one under discussion, and" >&2
        echo "  reporting success, is worse than not verifying at all." >&2
        echo "" >&2
        echo "  A nomination carries both. For example:" >&2
        echo "    ./uis template install $template_id --version v20260914-1fa7961@sha256:<64 hex>" >&2
        return 1
    fi

    # Reuses the catalogue's own rule: digest shape, and no moving tag.
    _template_pin_is_immutable "$tag" "$digest" || return 1

    SOURCE_TAG="$tag"
    SOURCE_DIGEST="$digest"

    # 🔴 OFF-CATALOGUE IS A COMPARISON, NOT A FLAG-PRESENCE TEST.
    #
    # 1.6.88 set the marker whenever `--version` was used. imac passed the pin
    # the catalogue itself advertises — byte-identical tag AND digest — and got
    # "this is not what the catalogue points at" printed directly above the
    # catalogue pointer it had just matched (ops-dev, #987).
    #
    # ⚠️ And it was worse than a contradiction in the output. The flag exists to
    # verify a NOMINEE, and a nominee is normally the pin about to BECOME the
    # catalogue pin — so the ordinary intended use left a false "not current"
    # claim on the verification host, retractable only by a plain reinstall.
    # "Is this host current?" is the question actually being asked about that
    # host, and the marker made the honest answer read as no.
    if [[ "$tag" == "$CATALOGUE_TAG" && "$digest" == "$CATALOGUE_DIGEST" ]]; then
        OFF_CATALOGUE=0
        log_info "--version names exactly what the catalogue points at — installing normally."
        echo "    ${tag}  ${digest}" >&2
        return 0
    fi

    OFF_CATALOGUE=1

    # ⚠️ LOUD, because the whole risk of this flag is that it stops looking
    # unusual. The operator is told what the catalogue says as well as what they
    # asked for, so "is this host current?" is answerable from the output.
    echo "" >&2
    log_warn "OFF-CATALOGUE INSTALL — this is not what the catalogue points at."
    echo "    catalogue: ${CATALOGUE_TAG}  ${CATALOGUE_DIGEST}" >&2
    echo "    installing: ${SOURCE_TAG}  ${SOURCE_DIGEST}" >&2
    echo "" >&2
    echo "  This is recorded. It clears itself once the catalogue points here —" >&2
    echo "  'uis template info $template_id' compares against the catalogue as it" >&2
    echo "  stands, so no reinstall is needed to retract the claim." >&2
    echo "" >&2
    return 0
}

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

# Age of the cache file in seconds, or FAILURE if that cannot be established.
#
# ⚠️ This used to be `$(stat -c %Y "$cache" 2>/dev/null || echo 0)` inline, which
# turns a failed stat into the epoch — an age of ~29 million minutes, reported as
# a number rather than as an error. A value we could not measure must not come
# back looking like a value we did measure (imac, #719).
_registry_cache_age_sec() {
    local cache="$1" mtime
    mtime=$(stat -c %Y "$cache" 2>/dev/null) || return 1
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    echo $(( $(date +%s) - mtime ))
}

# Check if registry cache is fresh.
# Sets REGISTRY_CACHE_AGE_SEC on success so the caller does not stat a second
# time and reach a different answer than the one this decision was made on.
_registry_cache_fresh() {
    _registry_is_cacheable || return 1
    local cache
    cache="$(_registry_cache_path)"
    if [[ ! -f "$cache" ]]; then
        return 1
    fi
    local age
    age=$(_registry_cache_age_sec "$cache") || return 1
    REGISTRY_CACHE_AGE_SEC="$age"
    [[ "$age" -lt "$REGISTRY_CACHE_TTL" ]]
}

# 🔴 Say "this may be a stale cache" AT THE MOMENT the wrong conclusion is drawn.
#
# "Not found in registry" and "published an hour ago and you have a cached copy"
# are the same sentence to a reader, and the remediation we printed made it
# worse: `uis template list` reads the SAME cache, so it confirms the absence.
# ⚠️ Takes the id as an ARGUMENT. It used to read `$template_id` out of the
# caller's scope, which works in bash only for as long as every caller happens
# to name its local the same thing — and the line it appears in is the
# remediation someone is about to type.
#
# 🔴 SILENT UNDER A MINUTE, on purpose. A copy fetched seconds ago cannot be the
# hour-old-cache failure this hint exists for, and warning there is worse than
# saying nothing: it fires immediately after `--refresh`, so it cries wolf about
# the one read we know is current. "A warning that cries wolf on fresh data is
# one people learn to skip" — imac, #719 — and being skipped is the single
# outcome this fix cannot afford.
_registry_staleness_hint() {
    local template_id="${1:-<id>}"
    [[ "${REGISTRY_FROM_CACHE:-false}" == true ]] || return 0
    [[ "${REGISTRY_CACHE_AGE_SEC:-0}" -ge 60 ]] || return 0
    echo "" >&2
    echo "⚠️  The registry was read from a ${REGISTRY_CACHE_AGE_MIN}-minute-old cache, not the network." >&2
    echo "    If this application was published recently it will not be in that copy," >&2
    echo "    and 'uis template list' reads the same file — so it will agree, wrongly." >&2
    echo "    Re-read the registry:  uis template install $template_id --refresh" >&2
}

# Fetch registry from primary or fallback URL
#
# 🔴 A CACHED READ USED TO BE COMPLETELY SILENT, and that silence cost imac two
# rounds and produced one confident wrong report.
#
# The registry is read from `main` with a one-hour TTL. A provision host that
# fetched within the hour does not see a new pin — and the symptom is NOT "your
# cache is stale", it is **"the application has not been published yet"**. So the
# natural next move is to go and ask the publisher why they are slow, which is a
# round trip to the wrong agent. On one occasion it made imac's own report quote
# a template description dev-templates had already replaced (ops-dev, #716).
#
# ⚠️ The fix is NOT a shorter TTL. A cache on a file read at every install is
# reasonable, and a narrower window would make the failure rarer and therefore
# harder to recognise. **Say what we actually know instead**: whether this answer
# came from the network or from a file, and how old the file is.
#
# Sets REGISTRY_FROM_CACHE and REGISTRY_CACHE_AGE_MIN so the not-found path can
# name the cache at the moment the wrong conclusion would otherwise be drawn.
# 🔴 ONE REGISTRY READ PER COMMAND. `cmd_template_list` calls this and then
# `_list_uis_templates` calls it again; `info` does the same through
# `_get_template`. That printed the "Registry:" line twice on every invocation
# and, on a COLD cache, performed two network fetches for one command — found by
# imac reading the output rather than by anyone reading this function (#719).
#
# The outer call in each command is the load-bearing one: the inner readers run
# inside `$(...)`, so variables they set die with the subshell and the not-found
# hint would have nothing to report. Memoising here keeps both callers correct
# and makes the second call free.
#
# A FAILED fetch is memoised too. One command must not hammer the network once
# per reader, and "could not fetch" is an answer, not a reason to try again.
_fetch_registry() {
    if [[ "${_REGISTRY_FETCHED:-false}" == true ]]; then
        return "${_REGISTRY_FETCH_RC:-0}"
    fi
    _fetch_registry_uncached
    _REGISTRY_FETCH_RC=$?
    _REGISTRY_FETCHED=true
    return "$_REGISTRY_FETCH_RC"
}

_fetch_registry_uncached() {
    # Every reader goes through this, so resolving the path here means no
    # caller has to know the cache is URL-keyed.
    REGISTRY_CACHE="$(_registry_cache_path)"
    REGISTRY_FROM_CACHE=false
    REGISTRY_CACHE_AGE_MIN=0
    REGISTRY_CACHE_AGE_SEC=0

    # `--refresh` on any reader lands here. Deleting beats an in-memory bypass:
    # the next command in the same session gets the fresh copy too, which is what
    # someone re-running an install after a publish actually wants.
    if [[ "${REGISTRY_REFRESH:-false}" == true && -f "$REGISTRY_CACHE" ]]; then
        rm -f "$REGISTRY_CACHE"
        echo "Registry: cache discarded (--refresh)" >&2
    fi

    # _registry_cache_fresh has already measured the age; re-statting here would
    # be a second measurement reported as if it were the one we decided on.
    if _registry_cache_fresh; then
        REGISTRY_FROM_CACHE=true
        REGISTRY_CACHE_AGE_MIN=$(( REGISTRY_CACHE_AGE_SEC / 60 ))
        if [[ "$REGISTRY_CACHE_AGE_SEC" -lt 60 ]]; then
            echo "Registry: cached, read ${REGISTRY_CACHE_AGE_SEC}s ago — fresh" >&2
        else
            echo "Registry: cached, read ${REGISTRY_CACHE_AGE_MIN} min ago (--refresh to re-read)" >&2
        fi
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
    echo "Use 'uis template install <id> --dry-run' to see exactly what it would do"
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
        _registry_staleness_hint "$template_id"
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

        # 🔴 SAY SO IF THIS HOST IS NOT ON THE CATALOGUE'S PIN. `--version`
        # exists so a nominee can be verified before it is advertised, and the
        # whole risk of that flag is a host drifting off-catalogue with the only
        # record in a chat thread. The pin above answers "what would install";
        # this answers "what IS installed", which is a different question and
        # the one that goes stale.
        _report_off_catalogue "$template_id" "$(_template_source_field "$template" digest)"

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

    # ⚠️ The most useful thing about an application is a command nothing
    # advertised. `--dry-run` pulls the definition and prints the numbered plan
    # without installing anything — ops called it "the clearest description of
    # atlas that exists anywhere" and found it only because it is in the
    # install usage line (atlas, urb-agents#629). A capability nobody is told
    # about is one nobody has.
    echo ""
    echo "See exactly what installing this would do, without doing it:"
    echo "  uis template install $template_id --dry-run"
}

# The short form, for the END of an install — where attention actually is.
#
# 🔴 `template info` renders the full block, and a user who runs `install`
# without `info` never sees any of it. `uis template list` invites exactly
# that: it prints "use info for details" and "use install to install" as two
# EQUAL options, with nothing marking info as a prerequisite. And even a user
# who did read `info` met these four job names nine minutes and 677 lines
# earlier (imac, urb-agents#537).
#
# ⚠️ The `Endpoints:` block added in 1.6.38 worked as a fix for exactly this
# reason — the end of the output is the part that gets read. This is the same
# move for the same reason.
#
# Takes the info file directly: the install already pulled the artifact, so
# unlike `template info` this needs no fetch.
# Every `operational.*` key UIS renders on ANY surface. Dotted where the field
# is nested one level.
#
# 🔴 THIS LIST EXISTS BECAUSE THE GUARD COULD NOT SEE THE FOURTH INSTANCE.
#
# `test-operational-fields-reach-install.sh` compares the two renderers and
# requires a field read by one to be read by the other or named exempt. It
# cannot see a field read by NEITHER: absent from both is symmetric, so the
# comparison passes while the content reaches nobody. `operational.troubleshooting`
# was exactly that — atlas moved an upgrade remedy INTO it on instruction, and it
# went from a place the operator would not look to a place the operator could not
# look (ops-dev, #789).
#
# ⚠️ A static list has the opposite failure: it cannot know about a key invented
# next month. So this is not the guard — `_warn_unrendered_operational` below
# compares the list against what the DEFINITION actually declares, at install, on
# the real file. The list is what "UIS renders this" means; the definition is the
# evidence of what someone wrote.
TEMPLATE_OPERATIONAL_KEYS="automation timezone cadence external_services unscheduled manual_only troubleshooting install.note install.takes install.deploys install.first_load first_data.why first_data.how first_data.jobs first_data.takes"

# Warn about operational content that reaches no surface at all.
#
# The reader who needs this is the APPLICATION AUTHOR: they wrote a sentence, it
# is published, and nothing displays it. Nobody can tell from the outside — the
# install is green and the text is simply absent.
# Every operational key the definition declares that UIS has no designed layout
# for. Echoes them, one per line; silent when there are none.
_operational_unknown_keys() {
    local info="$1"
    [[ -f "$info" ]] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    [[ "$(yq -r 'has("operational")' "$info" 2>/dev/null)" == "true" ]] || return 0

    local declared unknown="" k
    # Top-level keys, plus one level inside the two container keys. A NEW
    # container invented later shows up at the top level and is still reported.
    declared=$(yq -r '.operational | keys | .[]' "$info" 2>/dev/null)
    local sub
    for sub in install first_data; do
        [[ "$(yq -r ".operational.$sub | type" "$info" 2>/dev/null)" == "!!map" ]] || continue
        declared+=$'\n'"$(yq -r ".operational.$sub | keys | .[] | \"$sub.\" + ." "$info" 2>/dev/null)"
        # the container itself is accounted for by its children
        declared=$(printf '%s\n' "$declared" | grep -vx "$sub")
    done

    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        [[ " $TEMPLATE_OPERATIONAL_KEYS " == *" $k "* ]] || unknown+="$k "
    done <<< "$declared"

    [[ -n "$unknown" ]] && printf '%s\n' ${unknown% }
    return 0
}

# 🔴 A WHITELIST WAS THE WRONG INSTRUMENT FOR `info`, and atlas's question is what
# showed it (#791). They asked whether a key they had invented was in the
# rendered set. It was not — and neither was a second one they had not thought
# to ask about.
#
# UIS's own contract says it "reads nothing from `operational` and validates
# nothing in it: the application owns the content, the platform only displays
# it." ⚠️ A platform that only displays content has no business deciding which of
# it is displayable. The known-key list should govern LAYOUT and the install
# surface — not whether someone's words exist anywhere.
#
# So `info` shows everything. Known keys keep their designed layout; the rest
# appear here verbatim. No operational content can be invisible on every surface
# again by construction, rather than by me remembering to add a key.
_template_info_operational_rest() {
    local info="$1" unknown k
    unknown="$(_operational_unknown_keys "$info")"
    [[ -n "$unknown" ]] || return 0
    echo ""
    echo "  also declared (no designed layout — shown as written):"
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        echo "    $k:"
        yq -r ".operational.$k" "$info" 2>/dev/null | sed 's/^/      /'
    done <<< "$unknown"
    return 0
}

# The install cannot show everything — it is read once, by someone who has just
# finished, and its job is to be short enough to be read. So it NAMES what is
# only in `info`, rather than silently deciding for the author.
_warn_unrendered_operational() {
    local info="$1" unknown
    unknown="$(_operational_unknown_keys "$info")"
    [[ -n "$unknown" ]] || return 0
    echo "" >&2
    echo "⚠️  This application declares operational content with no designed layout:" >&2
    echo "      $(printf '%s\n' $unknown | paste -sd' ' -)" >&2
    echo "    It IS shown, verbatim, by 'uis template info' — but nothing here" >&2
    echo "    presents it, and whoever wrote it may have expected otherwise." >&2
    echo "    Ask for a layout if it deserves one." >&2
    return 0
}

_install_summary_operational() {
    local info="$1" _tid="${2:-}"
    [[ -f "$info" ]] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    [[ "$(yq -r 'has("operational")' "$info" 2>/dev/null)" == "true" ]] || return 0

    local note jobs takes automation unscheduled troubleshooting manual_only
    note=$(yq -r '.operational.install.note // ""' "$info" 2>/dev/null)
    manual_only=$(yq -r '[.operational.manual_only // ""] | flatten | join(", ")' "$info" 2>/dev/null)
    troubleshooting=$(yq -r '.operational.troubleshooting // ""' "$info" 2>/dev/null)
    jobs=$(yq -r '.operational.first_data.jobs // [] | join(" -> ")' "$info" 2>/dev/null)
    takes=$(yq -r '.operational.first_data.takes // ""' "$info" 2>/dev/null)
    automation=$(yq -r '.operational.automation // ""' "$info" 2>/dev/null)
    unscheduled=$(yq -r '.operational.unscheduled // [] | join(", ")' "$info" 2>/dev/null)

    [[ -z "$note" && -z "$jobs" && -z "$automation" ]] && return 0
    echo ""
    [[ -n "$note" ]] && echo "$note"
    if [[ -n "$jobs" ]]; then
        echo "To load data${takes:+ ($takes)}, run these in Dagster, in order:"
        echo "  $jobs"
    fi
    # 🔴 Next to the job list, because this is the moment it means something.
    # `manual_only` is the claim that a job must run ONCE, by hand, and then
    # never again — not the same as `unscheduled`, which means it cannot run at
    # all. An operator reading the list above needs to know which of those they
    # are expected to launch themselves and never see fire on its own.
    [[ -n "$manual_only" ]] && \
        echo "  Run ONCE by hand — nothing will ever trigger it: $manual_only"

    # 🔴 THE JOB LIST ABOVE READS AS A FINISHED INSTALL, AND THAT IS THE DEFECT.
    #
    # It answers "why is my API empty" and hands over an ordered list. An
    # operator runs them, watches the data land, and concludes the install is
    # done. Nothing said those jobs are a ONE-TIME load, so a correct,
    # digest-pinned, fully verified install can sit there while the data ages.
    #
    # It was not hypothetical: the acceptance host's own register had stopped
    # tracking reality 12.8 hours earlier, with 3,075 unapplied changes, and was
    # found only because Terje asked (imac, urb-agents#756).
    #
    # ⚠️ The application's `automation:` sentence already said this. It was
    # rendered by `template info` and NOT by the installer — the same shape as
    # the `digest:` field in #745: declared once, consumed on one surface,
    # silently absent on the other.
    if [[ -n "$automation" || -n "$jobs" ]]; then
        echo ""
        if [[ -n "$automation" ]]; then
            echo "⚠️  $automation"
        else
            # 🔵 Said even when the definition declares nothing, because silence
            # here is what this fix exists to remove. An application that never
            # writes an `automation:` sentence must not buy back the old silence.
            echo "⚠️  This application does not state whether its automation ships switched on."
        fi
        # 🔴 THIS SENTENCE OUTLIVED ITS TRUTH BY A DAY. It said UIS "can report
        # that state but cannot change it — schedules AND sensors are switched
        # on in the Dagster UI", which was true until 1.6.90 built `--start`
        # this morning. ops-dev quoted this very banner on #991 as the thing
        # that sent operators away to a web UI; the capability was then built
        # and the banner asserting its absence shipped alongside it
        # (ops-dev, urb-agents#1057).
        #
        # ⚠️ A doc going stale is read by contributors. THIS is printed to every
        # operator at the end of every install, and it sent them somewhere the
        # CLI no longer needs them to go.
        #
        # 🔵 Both verbs named, because an asset driven by an automation
        # condition has no schedule to switch on — someone told to "enable the
        # schedules" would enable every schedule and still not be running it.
        echo "    Switch it on when you are ready to go live:"
        echo "      ./uis dagster automation           what is running now"
        echo "      ./uis dagster automation --start   switch every schedule AND"
        echo "                                         sensor on, then re-read"
        # ⚠️ Named separately because an asset driven by an automation condition
        # has no schedule to switch on at all: someone told to "enable the
        # schedules" would enable every schedule and still not be running it.
        # 🔴 DELIBERATELY NOT "no schedule". Both fields are schedule-negative,
        # and the first wording made them near-synonyms while the meanings are
        # opposite: `manual_only` is an INSTRUCTION (you must act, once) and
        # `unscheduled` is a STATEMENT that nothing will happen and nothing is
        # expected of you. "No schedule at all" read as "you will have to run it
        # yourself" — which is the other field (atlas, #801).
        [[ -n "$unscheduled" ]] && echo "    Never runs, and nothing to launch: $unscheduled"
    fi

    # 🔴 A POINTER, NOT THE TEXT — and the reasoning is the whole of the
    # question ops-dev asked (#789).
    #
    # `troubleshooting` is the one operational field whose reader is someone
    # whose install has ALREADY gone wrong. Printing remedies at the end of a
    # SUCCESSFUL install is noise, and noise here is expensive: it trains people
    # to skip the block that also carries the automation warning, which is the
    # thing 1.6.65 existed to make them read.
    #
    # ⚠️ But the end of a successful install is the one moment the operator is
    # certainly reading, and at 02:00 with a dbt schema error they will not
    # discover a command they have never seen. So the install teaches that the
    # place exists; `info` holds what is in it.
    if [[ -n "$troubleshooting" && "$troubleshooting" != "null" ]]; then
        echo ""
        echo "If something goes wrong later, this application ships its own remedies:"
        echo "  ./uis template info ${_tid:-<id>}"
    fi
    # ⚠️ EXPLICIT. Without it the function exits with the status of the last
    # `[[ ... ]] &&` test, so an application with no `unscheduled` list returned
    # 1 from a summary printer that had succeeded. Under `set -e`, or any caller
    # that checks, a successful install would have reported a failure — caught
    # by running the function rather than reading it.
    return 0
}

# Print the `operational:` block from an application's definition, if it has
# one. Silent when it does not — most applications will not, and an empty
# heading is worse than no heading.
# Render the application's OWN declared commands.
#
# 🔴 THE APPLICATION WROTE A DESCRIPTION OF ITS CHECK, UIS READ THAT DESCRIPTION
# IN ORDER TO RUN THE CHECK, AND THE OPERATOR WAS NEVER SHOWN EITHER.
#
# atlas has declared `commands.check` with a description since
# v20260914-1fa7961. `uis template info atlas` was 103 lines and never mentioned
# it (Terje via ops-dev, urb-agents#1031). That is imac's H1 from #925 — "the end
# of an install names the command" — failing on the DISCOVERY surface instead of
# the install summary.
#
# ⚠️ AND THE INVOCATION IS NAMED, not just the script. `run: /app/atlas-status.py`
# is true and an operator cannot use it: it executes inside the code-location
# pod. Printing the path without `./uis template check <id>` beside it would be
# the correct-and-unreachable shape this project keeps removing.
_template_info_commands() {
    local info="$1" template_id="$2"
    command -v yq >/dev/null 2>&1 || return 0

    print_subsection "Commands this application declares" 2>/dev/null \
        || { echo ""; echo "Commands this application declares"; }

    if [[ "$(yq -r 'has("commands")' "$info" 2>/dev/null)" != "true" ]]; then
        # 🔵 SAYS SO, rather than printing nothing. The same honesty the check
        # listing already has: "declares no check" is an answer, an empty
        # section is not.
        echo "  This application declares no commands."
        echo "  'uis template check $template_id' will report 'declares no check'."
        return 0
    fi

    local keys k desc run where
    keys=$(yq -r '.commands | keys | .[]' "$info" 2>/dev/null)
    if [[ -z "$keys" ]]; then
        echo "  This application declares no commands."
        return 0
    fi
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        desc=$(k="$k" yq -r '.commands[strenv(k)].description // ""' "$info" 2>/dev/null)
        run=$(k="$k"  yq -r '.commands[strenv(k)].run // ""' "$info" 2>/dev/null)
        where=$(k="$k" yq -r '.commands[strenv(k)].in // "code-location"' "$info" 2>/dev/null)
        echo "  $k"
        [[ -n "$desc" ]] && printf '    %s\n' "$(printf '%s' "$desc" | tr '\n' ' ' | sed 's/  */ /g')"
        if [[ "$k" == "check" ]]; then
            echo "    you run:  ./uis template check $template_id"
        fi
        [[ -n "$run" ]] && echo "    which runs '$run' inside the $where"
    done <<< "$keys"
    return 0
}

# 🔴 SAY WHICH VERSION THE BLOCK BELOW DESCRIBES.
#
# `uis template info` renders the operational block from the CATALOGUE's pinned
# digest, because that is the digest the registry entry carries. When the host
# is running a different one, every line below — what it deploys, whether
# anything runs afterwards, how to load the data, the cadence table — is the
# catalogue's answer to a question the reader is asking about THIS host.
#
# 🔴 AND THE STATEMENT WAS NOT MISSING. IT WAS TWENTY LINES AWAY.
#
# This is the correction that matters, and the first version of this comment got
# it wrong. imac's stored capture from the session that caused all this, on UIS
# *before* this change (ops-dev, urb-agents#1164):
#
#     Tag:      v20260914-b7e513f
#     Pin:      sha256:aa52587c…b2b6
#     Visible:  public
#
#     ⚠ This host has an OFF-CATALOGUE install of 'atlas'.
#          atlas  installed at v20260916-e439668
#                   sha256:ba5305f0…875613cc
#          catalogue now points at sha256:aa52587c…b2b6
#
#     … roughly twenty lines …
#
#     [the operational block, describing b7e513f]
#
# UIS named the version it was about to describe, named the one the host was
# running, printed both digests and said they differed — all before a word of
# the block. Three agents had that on screen and still spent an afternoon on a
# truncation that never happened.
#
# ⚠️ SO THE FIX IS PLACEMENT, NOT PRESENCE, and that is not a nicety. A label
# twenty lines from its subject is read as preamble, and preamble is skipped. It
# has to sit immediately before the text it governs, and again before the
# commands block, or it is decoration.
#
# 🔴 DO NOT CONSOLIDATE THIS BACK INTO THE HEADER on the grounds that Tag and
# Pin are already printed up there. We did already print them up there. The
# capture above is what that cost.
#
# ⚠️ WHAT THE DISTANCE COST: TWO DAYS AND A FALSE CLAIM IN ANOTHER TEAM'S
# ARTIFACT.
# imac tested atlas at `e439668`, installed by digest while the catalogue still
# pinned `b7e513f`. `info` rendered b7e513f's `first_data.how` — 1114 characters,
# complete and correct for the version it was describing — and three of us read
# it as a TRUNCATED e439668, whose field is 2300. It is a byte-exact prefix,
# because paragraphs had been appended to the end of the field, so the cut we
# all "found" was where the older version simply ended. ops-dev diagnosed a
# truncation mechanism twice, and atlas shipped a general rule about a "silent
# cliff" in UIS that does not exist (urb-agents#1152, #1157).
#
# 🔵 The symptom vanished when dev-templates moved the pin an hour later, and
# would have been unreproducible by anyone re-running the same test. The defect
# did not vanish: the next host whose pin differs reproduces it exactly.
#
# 🔴 THIS FIRES ON THE PINS DIFFERING, AND DOES NOT ALSO REQUIRE
# `off_catalogue`, WHICH IS THE OPPOSITE RULE FROM `_report_off_catalogue` ONE
# CALL BELOW. That is deliberate and they are not in conflict:
#
#   _report_off_catalogue makes a CLAIM ABOUT THE HOST — "you are not current".
#     It needs both conditions, because a host that is merely BEHIND has not
#     drifted, and warning it had was the cry-wolf failure that record already
#     had once (#987).
#
#   this makes a STATEMENT ABOUT THIS OUTPUT — "the text below is that version's".
#     That is true whenever the pins differ, however they came to differ, and a
#     host that is simply behind is the COMMON case rather than the exotic one.
#     Labelling output cannot cry wolf; it is not a claim about anything.
#
# 🔵 And there is now a concrete case where the stricter condition fired and
# the looser one was what was needed: in the capture above `_report_off_catalogue`
# was CORRECT and fired, and the reader accepted it and still misread the block.
# The warning was about the host; the confusion was about the text.
_template_info_describes_pin() {
    local id="$1" catalogue_digest="$2" file pins n=0
    [[ -n "$catalogue_digest" ]] || return 0
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # ⚠️ yq TO JSON, THEN jq — the same reason spelled out in
    # _report_off_catalogue: chained mikefarah selects passed nulls through there
    # and warned on every host with any recorded application.
    pins=$(yq -o=json "$file" 2>/dev/null | jq -r --arg id "$id" --arg cat "$catalogue_digest" \
        '[ .applications[]? | select(.id == $id) | (.pin // "")
           | select(. != "" and . != $cat) ] | unique | .[]' 2>/dev/null) || return 0
    [[ -z "$pins" ]] && return 0
    echo ""
    echo "  ⚠️  WHAT FOLLOWS DESCRIBES THE CATALOGUE'S PIN, NOT THIS HOST'S."
    echo "        catalogue   $catalogue_digest"
    # ⚠️ A `while read` loop, not `printf '%s\n' $pins`. The record is keyed on
    # app_name, so one template id can hold several tenants at several pins, and
    # an unquoted expansion would also split on any space one of them contains.
    while IFS= read -r _p; do
        [[ -z "$_p" ]] && continue
        echo "        installed   $_p"
        n=$((n+1))
    done <<< "$pins"
    echo "      Every line below is the CATALOGUE version's answer — what it"
    echo "      deploys, whether anything runs, how to load the data, the"
    echo "      schedule. Read it as a description of this host only once those"
    echo "      digests agree."
    echo "      './uis template install $id' moves this host to the catalogue pin."
    return 0
}

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

    # 🔴 BEFORE EVERYTHING THIS FUNCTION PRINTS, including the commands block —
    # a `commands.check` read out of the catalogue's version is as wrong about
    # this host as a cadence table is.
    _template_info_describes_pin "$template_id" "$digest"

    # 🔴 BEFORE the operational gate. An artifact may declare `commands:` and no
    # `operational:`, and gating both on the second would hide the first.
    _template_info_commands "$info" "$template_id"

    [[ "$(yq -r 'has("operational")' "$info" 2>/dev/null)" == "true" ]] || return 0

    local v
    print_subsection "What installing this does" 2>/dev/null || { echo ""; echo "What installing this does"; }

    v=$(yq -r '.operational.install.deploys // [] | join(", ")' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  deploys      $v"
    v=$(yq -r '.operational.install.takes // ""' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  takes        $v"
    # 🔴 Directly under `takes`, because it is the other half of that sentence.
    # `takes` says the data load afterwards is the long part; `first_load` says
    # how long is long, and how much disk. Same question — "what is this about to
    # do to my cluster" — same reader, deciding before installing.
    #
    # ⚠️ atlas moved this key UNDER `install` believing that made it render, and
    # it did not: the children of a known container are whitelisted
    # individually, so `install.first_load` was as invisible as the top-level
    # `first_load` it replaced (#791). Their reasoning was right and the
    # mechanism did not agree with it; this makes the mechanism agree.
    v=$(yq -r '.operational.install.first_load // ""' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  first load   $v"

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
    [[ -n "$v" ]] && echo "  never runs   $v — no schedule, and nothing for you to launch"
    # ⚠️ Printed next to `unscheduled` BECAUSE the two are easy to confuse, and
    # collapsing them loses the instruction an operator cannot skip:
    #   unscheduled  cannot run  (no private data, no credential)
    #   manual_only  MUST run, once, by hand — and then never again
    # atlas needed the distinction and invented the key rather than overload the
    # one that existed (#791). `[x] | flatten` accepts a scalar and a list, the
    # shape lesson from the scalar env_secrets that vanished for four rounds.
    v=$(yq -r '[.operational.manual_only // ""] | flatten | join(", ")' "$info" 2>/dev/null)
    [[ -n "$v" ]] && echo "  run once     $v — by hand; nothing else will ever trigger it"

    # 🔴 Rendered with a bare `yq -r`, deliberately, with NO type switch.
    #
    # No application had ever used this field, so its shape is whatever the first
    # one chooses: a scalar, a list of strings, or a list of {symptom, remedy}.
    # All three print readably this way, and none can be silently discarded —
    # which is exactly what a `join(",")` did to a scalar `env_secrets` until a
    # clean-slate install exposed it (#491). mikefarah yq has no `if`, and a type
    # switch in bash would be a second place for the forms to disagree.
    v=$(yq -r '.operational.troubleshooting // ""' "$info" 2>/dev/null)
    if [[ -n "$v" && "$v" != "null" ]]; then
        echo ""
        echo "  when it goes wrong:"
        printf '%s\n' "$v" | sed 's/^/    /'
    fi

    # Last, and unconditional: anything this application declared that UIS has
    # no layout for. Shown rather than dropped.
    _template_info_operational_rest "$info"
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
# ⚠️ `digest` is here because a key absent from this list is not merely
# unwritten — it is never READ from the definition. 1.6.62 added the field to
# the schema, the deploy-time verification and the docs, and atlas declared it,
# while this line silently dropped it one step before the renderer did
# (imac via ops-dev, #745).
TEMPLATE_CODE_LOCATION_KEYS="name image tag module why env_secrets digest env_from_exports env_from_services"

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
        # 🔴 AN UNKNOWN SUBKEY HERE USED TO BE DROPPED IN SILENCE, AND THE LOOP
        # BELOW IS WHY: it walks the WHITELIST and reads each key, so a key the
        # whitelist does not contain is never looked at. Measured on 1.6.83 with
        # an `env_from_services:` block: rc=0, no output, the key simply absent
        # from the conf — the pod then comes up with the variable unset and the
        # check reports "could not look" with nothing anywhere saying why
        # (ops-dev, #960).
        #
        # ⚠️ THE ASYMMETRY IS THE DEFECT. `config.*` one level up has refused
        # unknown keys since it was written; `code_location.*` never did. A
        # definition is a DELIVERY INSTRUCTION — unlike `operational.*`, which
        # is prose and only warns — so an instruction this binary cannot carry
        # out must refuse, not proceed with part of it.
        #
        # 🔵 The usual cause is an artifact newer than this UIS, so the message
        # says so. This cannot help a host already running an older release —
        # nothing shipped now can — but it closes the class from here on.
        local clk
        while IFS= read -r clk; do
            [[ -z "$clk" ]] && continue
            case " $TEMPLATE_CODE_LOCATION_KEYS " in
                *" $clk "*) ;;
                *)  log_error "Unknown code_location key '$clk' for service '$svc'."
                    echo "  Supported: $TEMPLATE_CODE_LOCATION_KEYS" >&2
                    echo "" >&2
                    echo "  This usually means the application definition is NEWER than this" >&2
                    echo "  UIS — the key exists, this release cannot act on it, and carrying" >&2
                    echo "  out part of a delivery instruction is worse than refusing it." >&2
                    echo "  Upgrade with './uis pull' and install again." >&2
                    return 1 ;;
            esac
        done <<< "$(yq -r ".provides.services[$idx].config.code_location // {} | keys | .[]" "$info_file" 2>/dev/null)"

        local ck
        for ck in $TEMPLATE_CODE_LOCATION_KEYS; do
            if [[ "$ck" == "env_from_exports" || "$ck" == "env_from_services" ]]; then
                # 🔴 A MAP, flattened to one JSON line. The conf file is flat
                # key=value, and `env_secrets` solves the list case by joining
                # on commas — that does not work here because both the variable
                # NAME and the export KEY matter and either may contain
                # characters a separator would claim.
                v=$(yq -o=json -I0 ".provides.services[$idx].config.code_location.$ck // {}" "$info_file" 2>/dev/null)
                [[ "$v" == "{}" ]] && v=""
            elif [[ "$ck" == "env_secrets" ]]; then
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
        # A malformed digest must be named here, where the message can point at
        # the declaration, rather than surfacing from Ansible as a mismatch that
        # sends the reader to the registry to investigate their own typo.
        local ckd
        ckd="$(_conf_get "$conf" code_location_digest)"
        if [[ -n "$ckd" && ! "$ckd" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            log_error "Service '$svc': code_location digest '$ckd' is not a sha256 digest."
            echo "  Expected sha256: followed by 64 hex characters." >&2
            return 1
        fi
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

# Validate every `env_from_exports` declaration BEFORE anything is executed.
#
# 🔴 IT USED TO REFUSE LATE. The resolution lives in `_write_code_location`,
# which runs after the database and both namespaces have been ensured — so a
# misnamed export was caught only once the install had already changed the
# cluster. imac checked there was no half-applied state and there was not, but
# "refuses safely after side effects" is a different guarantee from "refuses
# before them", and the second is the one worth having (ops-dev, #959).
#
# This check is a pure read of the definition. Nothing needs a cluster.
_validate_env_from_exports() {
    local info_file="$1" n_svc i map k v exp_keys bad=""
    command -v yq >/dev/null 2>&1 || return 0
    n_svc=$(yq -r '.provides.services // [] | length' "$info_file" 2>/dev/null) || return 0
    [[ "$n_svc" =~ ^[0-9]+$ ]] || return 0
    exp_keys=$(yq -r '.exports // {} | keys | .[]' "$info_file" 2>/dev/null)

    for ((i=0; i<n_svc; i++)); do
        map=$(yq -o=json -I0 ".provides.services[$i].config.code_location.env_from_exports // {}" "$info_file" 2>/dev/null)
        [[ -z "$map" || "$map" == "{}" ]] && continue
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            local name="${k%%=*}" key="${k#*=}"
            if ! grep -qxF "$key" <<< "$exp_keys"; then
                bad+="    $name names export '$key', which this definition does not declare"$'\n'
            fi
        done <<< "$(printf '%s' "$map" | yq -r 'to_entries | .[] | .key + "=" + .value' 2>/dev/null)"
    done

    if [[ -n "$bad" ]]; then
        log_error "This definition's env_from_exports cannot be delivered:"
        printf '%s' "$bad" >&2
        echo "" >&2
        echo "  env_from_exports names an export KEY, and the key must appear" >&2
        echo "  in this definition's own exports: block." >&2
        echo "" >&2
        echo "  Refused before anything was installed." >&2
        return 1
    fi
    return 0
}

# The in-cluster address of a UIS service, composed from published platform data.
#
# 🔴 THE TENANT NAMES A SERVICE; UIS COMPOSES THE ADDRESS. The alternative —
# a tenant artifact declaring `<service>.<namespace>.svc.cluster.local` — asks
# it to encode something UIS does not keep stable: `namespace` was undeclared in
# service.schema.json until this release, and gravitee moved from `default` to
# `gravitee` in 2d0570d. An artifact that had hardcoded the old value would have
# broken silently that day, in a different repository, with no signal here.
#
# ⚠️ The FORM is Kubernetes' DNS spec and is not UIS's to change. The NAME, the
# NAMESPACE and the PORT are, so they are read from services.json at install
# time and never restated anywhere else.
#
# Prints the URL, or nothing (and returns 1) when this service publishes no
# in-cluster address. Absent must REFUSE, never fall through to a guess: a
# guessed address that resolves is the failure that cost a day to disprove.
_service_in_cluster_url() {
    local svc_id="$1" app_name="$2" entry scheme name ns port
    [[ -f "$SERVICES_JSON" ]] || return 1
    entry=$(jq -c --arg id "$svc_id" '.services[] | select(.id == $id)' "$SERVICES_JSON" 2>/dev/null)
    [[ -z "$entry" ]] && return 2          # 2: no such service id at all
    scheme=$(jq -r '.inCluster.scheme // ""' <<< "$entry")
    name=$(jq -r '.inCluster.nameTemplate // ""' <<< "$entry")
    port=$(jq -r '.inCluster.port // ""' <<< "$entry")
    ns=$(jq -r '.namespace // ""' <<< "$entry")
    [[ -z "$scheme" || -z "$name" || -z "$port" || -z "$ns" ]] && return 1
    # `{app}` is the only expansion, and an unresolvable one must not silently
    # produce `-postgrest`.
    if [[ "$name" == *'{app}'* ]]; then
        [[ -z "$app_name" ]] && return 3   # 3: needs app_name, none available
        name="${name//\{app\}/$app_name}"
    fi
    printf '%s://%s.%s.svc.cluster.local:%s\n' "$scheme" "$name" "$ns" "$port"
    return 0
}

# Validate every `env_from_services` declaration BEFORE anything is executed,
# and refuse a variable claimed by both maps.
#
# Like _validate_env_from_exports this is a pure read: services.json and the
# definition, no cluster.
_validate_env_from_services() {
    local info_file="$1" app_name="${2:-}" n_svc i map k bad="" rc
    command -v yq >/dev/null 2>&1 || return 0
    n_svc=$(yq -r '.provides.services // [] | length' "$info_file" 2>/dev/null) || return 0
    [[ "$n_svc" =~ ^[0-9]+$ ]] || return 0

    for ((i=0; i<n_svc; i++)); do
        local exp_map
        exp_map=$(yq -o=json -I0 ".provides.services[$i].config.code_location.env_from_exports // {}" "$info_file" 2>/dev/null)
        map=$(yq -o=json -I0 ".provides.services[$i].config.code_location.env_from_services // {}" "$info_file" 2>/dev/null)
        [[ -z "$map" || "$map" == "{}" ]] && continue
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            local name="${k%%=*}" svc_id="${k#*=}"
            # ⚠️ One variable, two sources, and nothing says which wins. Refuse
            # rather than pick: a silently-chosen answer is the shape this whole
            # change exists to remove.
            #
            # 🔴 THIS LOOKS BACKWARDS AND IS NOT. Measured on the real atlas
            # artifact with both keys added: an OLDER UIS ignores
            # env_from_services, delivers the host-facing export, and INSTALLS
            # with the wrong value — while this release REFUSES. The host that
            # upgraded is the one that stops (ops-dev, #967).
            #
            # ✅ It is still the right way round, because of what each choice
            # does to the transition:
            #
            #   refuse    forces "replace, in one change". An older UIS then
            #             sets nothing, and the check reports CANNOT naming the
            #             variable — one line, and true.
            #   precede   would let an artifact carry both. An older UIS then
            #             delivers the LOOPBACK value, which resolves, connects
            #             to the pod itself, and reads as a cluster problem —
            #             the failure that cost a day to disprove.
            #
            # ⚠️ So the refusal is what makes the worse outcome unreachable.
            # The message below therefore says REPLACE rather than "pick one":
            # an author mid-migration needs to be told which, not asked.
            #
            # 🔵 And it refuses from the plan builder, so nothing is installed
            # when it fires. A backwards that is also destructive would be a
            # different argument.
            if [[ -n "$exp_map" && "$exp_map" != "{}" ]] && \
               printf '%s' "$exp_map" | en="$name" yq -e 'has(strenv(en))' >/dev/null 2>&1; then
                bad+="    $name is set by BOTH env_from_exports and env_from_services"$'\n'
                bad+="      REPLACE the env_from_exports entry, do not add beside it:"$'\n'
                bad+="      keep the env_from_services one, which is valid inside a pod,"$'\n'
                bad+="      and delete '$name' from env_from_exports"$'\n'
                continue
            fi
            rc=0; _service_in_cluster_url "$svc_id" "$app_name" >/dev/null || rc=$?
            # ⚠️ THE REMEDY TRAVELS WITH THE CAUSE. A shared footer explaining
            # in-cluster addressing reads as actionable to someone whose actual
            # problem is a name collision — the same "correct and unreachable"
            # shape this release removed from the loopback guard, reintroduced
            # the moment a second cause was added. Each line carries its own.
            case "$rc" in
                0) ;;
                2) bad+="    $name names service '$svc_id', which is not a UIS service"$'\n'
                   bad+="      the value is a service id as it appears in services.json"$'\n' ;;
                3) bad+="    $name names service '$svc_id', whose address is per-application"$'\n'
                   bad+="      but this definition resolves no params.app_name"$'\n' ;;
                *) bad+="    $name names service '$svc_id', for which UIS publishes no in-cluster address"$'\n'
                   bad+="      UIS refuses rather than guessing one — ask for an inCluster block"$'\n'
                   bad+="      on that service instead of hardcoding an address here"$'\n' ;;
            esac
        done <<< "$(printf '%s' "$map" | yq -r 'to_entries | .[] | .key + "=" + .value' 2>/dev/null)"
    done

    if [[ -n "$bad" ]]; then
        log_error "This definition's env_from_services cannot be delivered:"
        printf '%s' "$bad" >&2
        echo "" >&2
        echo "  Refused before anything was installed." >&2
        return 1
    fi
    return 0
}

# Resolve NAME -> service id into NAME -> URL, as a JSON object.
# Prints `{}` when there is nothing to resolve.
_resolve_service_env() {
    local map="$1" app_name="${2:-}" out="{}" k url
    [[ -z "$map" || "$map" == "{}" ]] && { printf '{}'; return 0; }
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        local name="${k%%=*}" svc_id="${k#*=}"
        url=$(_service_in_cluster_url "$svc_id" "$app_name") || return 1
        out=$(printf '%s' "$out" | jq -c --arg n "$name" --arg v "$url" '.[$n] = $v') || return 1
    done <<< "$(printf '%s' "$map" | yq -r 'to_entries | .[] | .key + "=" + .value' 2>/dev/null)"
    printf '%s' "$out"
    return 0
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

    # ⚠️ Before the plan, therefore before any side effect.
    _validate_env_from_exports "$info_file" || return 1
    # `{app}` in a service's nameTemplate resolves against the effective params,
    # which _install_template writes before it builds the plan.
    local _app_name
    _app_name=$(_conf_param "$template_dir/.effective-params" app_name)
    _validate_env_from_services "$info_file" "$_app_name" || return 1

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

# Warn when this host has an off-catalogue install of this id.
#
# Reads the record rather than the registry: the point is what IS here, which
# `--version` can make differ from what the catalogue advertises.
_report_off_catalogue() {
    local id="$1" catalogue_digest="${2:-}" file rows
    file="$(_applications_file)"
    [[ -f "$file" ]] || return 0
    command -v yq >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    # 🔴 yq TO JSON, THEN jq — AND BOTH HALVES OF THAT ARE A BUG I HIT HERE.
    #
    # Written first as chained mikefarah selects with `+ "\t" +`, and running it
    # showed two failures at once:
    #
    #   select(.off_catalogue == true) did NOT drop a false row. It passed a
    #   null through, so `rows` was non-empty and this warned "your host is
    #   OFF-CATALOGUE" on every host with any recorded application. A control
    #   that cries wolf is worse than no control — it is the one people learn
    #   to scroll past.
    #
    #   `+ "\t" +` emits a LITERAL backslash-t, so `IFS=$'\t' read` got the
    #   whole row in one field. Same trap already recorded once this project.
    #
    # ⚠️ jq's semantics here are the predictable ones, and converting costs one
    # process on a command that already does network I/O.
    # 🔴 SELF-CLEARING, BECAUSE THE CLAIM IS ABOUT NOW AND THE RECORD IS ABOUT
    # THEN. A nominee verified with `--version` is normally the pin about to
    # BECOME the catalogue pin, so a marker that only a reinstall could retract
    # left a false "not current" claim on the verification host from the moment
    # dev-templates caught up (ops-dev, #987).
    #
    # So this reports on TWO conditions, and needs both:
    #   the install used --version           (provenance, from the record)
    #   the recorded pin differs from the catalogue AS IT STANDS NOW
    #
    # ⚠️ BOTH, not either. Comparing pins alone would warn on every host whose
    # catalogue has moved since install — which is "behind", a different thing,
    # and would be the cry-wolf failure this record already had once.
    #
    # ⚠️ And with no catalogue digest to compare against, this says it could not
    # compare rather than reporting either currency or drift. A marker that
    # guesses in the dark is the thing it exists to replace.
    rows=$(yq -o=json "$file" 2>/dev/null | jq -r --arg id "$id" --arg cat "$catalogue_digest" \
        '.applications[]? | select(.id == $id and .off_catalogue == true)
         | select($cat == "" or (.pin // "") != $cat)
         | [(.app_name // "?"), (.tag // "?"), (.pin // "?")] | @tsv' 2>/dev/null) || return 0
    [[ -z "$rows" ]] && return 0
    echo "" >&2
    if [[ -z "$catalogue_digest" ]]; then
        log_warn "'$id' was installed with --version here, and the catalogue pin could not be read."
    else
        log_warn "This host has an OFF-CATALOGUE install of '$id'."
    fi
    while IFS=$'\t' read -r an tg pn; do
        [[ -z "$an" ]] && continue
        echo "    $an  installed at $tg" >&2
        echo "             $pn" >&2
    done <<< "$rows"
    if [[ -z "$catalogue_digest" ]]; then
        echo "  Whether that is still current could NOT be determined — the" >&2
        echo "  comparison needs the catalogue entry, and this is not a claim" >&2
        echo "  that the host has drifted." >&2
        return 0
    fi
    echo "    catalogue now points at $catalogue_digest" >&2
    echo "  It was installed with --version, so it is deliberate — but it is not" >&2
    echo "  current. A plain 'uis template install $id' replaces it, and this" >&2
    echo "  notice clears itself if the catalogue moves here instead." >&2
    return 0
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
            "exports":   (strenv(exports_json) | from_json),
            "off_catalogue": (strenv(off_catalogue) == "1"),
            "catalogue_pin": strenv(catalogue_pin)
          }])'

    # 🔴 RECORDED, so an off-catalogue host does not read as current. The only
    # record of imac's deliberate off-catalogue state was a bus comment, and a
    # test host whose drift lives in a chat thread is a test host that drifts
    # (ops-dev, #981). `catalogue_pin` keeps what the catalogue said AT THE
    # TIME, so the divergence is legible later without re-reading the registry.
    if ! app_id="$app_id" artifact="$artifact" tag="$tag" digest="$digest" \
         off_catalogue="${OFF_CATALOGUE:-0}" \
         catalogue_pin="${CATALOGUE_DIGEST:-}" \
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
    local cl_digest="${7:-}" cl_env_map="${8:-}" cl_exports="${9:-{\}}"
    local cl_svc_env="${10:-{\}}"
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

    # 🔴 Written as a SEPARATE expression, like env_secrets, so that an absent
    # digest leaves the key out rather than writing an empty string. The
    # deploy's `(digest | trim | length) > 0` guard would treat `digest: ""` as
    # "declared but empty" and skip, which is the silent no-op this fixes.
    if [[ -n "$cl_digest" ]]; then
        local dig_expr='(.code_locations[] | select(.name == strenv(cl_name)) | .digest)
            = strenv(cl_digest)'
        if ! cl_name="$cl_name" cl_digest="$cl_digest" yq -i "$dig_expr" "$file"; then
            log_error "Failed to write digest for '$cl_name'"
            return 1
        fi
    fi

    if [[ -n "$cl_env_secrets" ]]; then
        local sec_expr='(.code_locations[] | select(.name == strenv(cl_name)) | .env_secrets)
            = (strenv(cl_env_secrets) | split(","))'
        if ! cl_name="$cl_name" cl_env_secrets="$cl_env_secrets" yq -i "$sec_expr" "$file"; then
            log_error "Failed to write env_secrets for '$cl_name'"
            return 1
        fi
    fi

    # 🔴 Resolve NAME -> export key -> value, and REFUSE on a missing export
    # rather than writing an empty one. An env var set to "" is not the same as
    # unset and is worse: the check would run, reach nothing, and have to guess
    # why — which is the state this whole command exists to make legible.
    if [[ -n "$cl_env_map" && "$cl_env_map" != "{}" ]]; then
        local _pairs _n _k _val _missing=""
        # ⚠️ `-r`, not `-o=json`. The JSON form quotes each string, so the
        # variable name arrived as `"ATLAS_POSTGREST_URL` and the export key as
        # `api-url"` — the lookup missed, the write was refused, and the error
        # message showed the stray quotes. Found by running it.
        _pairs=$(printf '%s' "$cl_env_map" | yq -r 'to_entries | .[] | .key + "=" + .value' 2>/dev/null) || _pairs=""
        while IFS= read -r _pair; do
            [[ -z "$_pair" ]] && continue
            _n="${_pair%%=*}"; _k="${_pair#*=}"
            _val=$(printf '%s' "$cl_exports" | exp_k="$_k" yq -r '.[strenv(exp_k)] // ""' 2>/dev/null) || _val=""
            if [[ -z "$_val" ]]; then
                _missing+="$_n (export '$_k') "
                continue
            fi
            local env_expr='(.code_locations[] | select(.name == strenv(cl_name)) | .env[strenv(en)]) = strenv(ev)'
            if ! cl_name="$cl_name" en="$_n" ev="$_val" yq -i "$env_expr" "$file"; then
                log_error "Failed to write env var '$_n' for '$cl_name'"
                return 1
            fi
        done <<< "$_pairs"
        if [[ -n "$_missing" ]]; then
            log_error "Code location '$cl_name' declares env_from_exports naming exports that do not exist:"
            echo "    ${_missing% }" >&2
            echo "  Refusing: an env var set to empty is not the same as unset, and" >&2
            echo "  the check would reach nothing and have to guess why." >&2
            return 1
        fi
    fi

    # 🔵 env_from_services arrives already resolved to literal URLs — see the
    # call site. There is nothing to look up here and nothing that can be
    # missing: a service without a published address was refused by
    # _validate_env_from_services before the plan ran.
    if [[ -n "$cl_svc_env" && "$cl_svc_env" != "{}" ]]; then
        local _spairs _sn _sv
        _spairs=$(printf '%s' "$cl_svc_env" | yq -r 'to_entries | .[] | .key + "=" + .value' 2>/dev/null) || _spairs=""
        while IFS= read -r _pair; do
            [[ -z "$_pair" ]] && continue
            _sn="${_pair%%=*}"; _sv="${_pair#*=}"
            local senv_expr='(.code_locations[] | select(.name == strenv(cl_name)) | .env[strenv(en)]) = strenv(ev)'
            if ! cl_name="$cl_name" en="$_sn" ev="$_sv" yq -i "$senv_expr" "$file"; then
                log_error "Failed to write env var '$_sn' for '$cl_name'"
                return 1
            fi
            # ⚠️ Prove the write, for the same reason the digest does: a value
            # can be accepted by every layer above and still not be in the file.
            local _sback
            _sback=$(cl_name="$cl_name" en="$_sn" yq -r '.code_locations[] | select(.name == strenv(cl_name)) | .env[strenv(en)] // ""' "$file" 2>/dev/null)
            if [[ "$_sback" != "$_sv" ]]; then
                log_error "env var '$_sn' for '$cl_name' did not survive the write to $file."
                echo "  intended: $_sv" >&2
                echo "  in file:  ${_sback:-<absent>}" >&2
                return 1
            fi
        done <<< "$_spairs"
    fi

    # 🔴 PROVE THE WRITE. A value can be accepted by every layer above and still
    # not be in the file: that is exactly how the digest was lost — declared by
    # the application, enforced by the deploy, and dropped by the renderer in
    # between, with each piece correct on its own. Reading it back is the only
    # claim worth making.
    if [[ -n "$cl_digest" ]]; then
        local _back
        _back=$(cl_name="$cl_name" yq -r '.code_locations[] | select(.name == strenv(cl_name)) | .digest // ""' "$file" 2>/dev/null)
        if [[ "$_back" != "$cl_digest" ]]; then
            log_error "Digest for '$cl_name' did not survive the write to $file."
            echo "  declared: $cl_digest" >&2
            echo "  in file:  ${_back:-<absent>}" >&2
            echo "  Refusing: the deploy would report this location as unpinned." >&2
            return 1
        fi
    fi

    echo "Code location '$cl_name' written to $file" >&2
    echo "  image: ${cl_image}:${cl_tag}" >&2
    if [[ -n "$cl_digest" ]]; then
        echo "  digest: ${cl_digest} (pinned — the deploy refuses if the tag has moved)" >&2
    else
        echo "  digest: not declared by this application — the tag is not pinned" >&2
    fi
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

# Evaluate ONE application's check, quietly. Sets CHECK_STATE and CHECK_DETAIL.
#
# 🔴 STATES ARE REACHED BY IDENTIFIED CONDITIONS ONLY. atlas found its own
# `worst()` letting a TypeError surface as "cannot answer" — "a bug wearing a
# connectivity failure's clothes" (ops-dev, #935). An aggregate that maps any
# exception to state 4 inherits that exactly: a defect in UIS would present as
# the honest outcome and never be looked at.
#
# So there is a FIFTH state that is not a state of the application at all:
# `uis-error`. If this function cannot reach one of the four for a reason it
# recognises, it says UIS failed rather than blaming the tenant.
#
#   healthy | unhealthy | no-check | could-not-ask | uis-error
CHECK_STATE=""
CHECK_DETAIL=""
# ⚠️ `uis-cli.sh` runs under `set -e`, and EVERY assignment here is
# `x=$(cmd)` — a bare simple command, so a non-zero status kills the process
# instead of reaching the branch below it. `2>/dev/null` hides the message and
# not the status.
#
# 🔴 That is exactly what imac found on a real cluster: `kubectl -o jsonpath`
# returns 1 on an EMPTY match, so `uis template check atlas` on a healthy pod
# printed a digest and died with EXIT=1 — no section, no line, no reason, and
# the "NOTHING WAS CHECKED" text never reached. G1's own FAIL clause, verbatim,
# produced by my own known hazard (ops-dev, #937).
#
# Every capture is now `|| true`-guarded and the status read deliberately.
_check_state() {
    local app_id="$1" cl_csv="${2:-}" verbose="${3:-0}"
    CHECK_STATE=""; CHECK_DETAIL=""; CHECK_SCOPE=""

    local template info dir artifact tag digest vis
    template=$(_get_template "$app_id" 2>/dev/null) || true
    if [[ -z "$template" || "$template" == "null" ]]; then
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="not in the registry (cached read?)"; return 0
    fi
    artifact="$(_template_source_field "$template" artifact)"
    tag="$(_template_source_field "$template" tag)"
    digest="$(_template_source_field "$template" digest)"
    vis="$(_json_field "$template" '.visibility')"; vis="${vis:-public}"
    if [[ -z "$artifact" || -z "$digest" ]]; then
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="no pinned definition artifact"; return 0
    fi
    dir=$(_resolve_definition "$app_id" "$artifact" "$tag" "$digest" "$vis" 2>/dev/null) || dir=""
    if [[ -z "$dir" ]]; then
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="definition could not be fetched"; return 0
    fi
    info="$dir/template-info.yaml"
    [[ -f "$info" ]] || { CHECK_STATE="could-not-ask"; CHECK_DETAIL="definition has no template-info.yaml"; return 0; }

    local run_cmd where cl_name pod
    run_cmd=$(yq -r '.commands.check.run // ""' "$info" 2>/dev/null) || true
    if [[ -z "$run_cmd" || "$run_cmd" == "null" ]]; then
        # 🔵 NOT could-not-ask. Nothing failed — the application never offered to
        # answer. Folding them together would hide an authoring gap inside a
        # runtime one, and they need different fixes from different people.
        CHECK_STATE="no-check"; CHECK_DETAIL="declares no check command"; return 0
    fi
    # 🔴 WHAT THE APPLICATION SAYS ITS CHECK COVERS.
    #
    # atlas's check answers "is Brreg internally consistent" and was PRESENTED
    # as "is atlas working" — 41 other ingest sources are covered by a 24-hour
    # window that cannot see a weekly source going stale, and a healthy exit 0
    # stood while a third of the data might not have moved (Terje via ops-dev,
    # urb-agents#1040).
    #
    # ⚠️ UIS cannot widen a tenant's check. What it can stop doing is relaying a
    # narrow verdict as though it were a broad one — and the narrowing is
    # ALREADY DECLARED, in the description UIS reads in order to run the check
    # and then showed to nobody on this surface.
    CHECK_SCOPE=$(yq -r '.commands.check.description // ""' "$info" 2>/dev/null) || CHECK_SCOPE=""
    where=$(yq -r '.commands.check.in // "code-location"' "$info" 2>/dev/null) || where="code-location"
    if [[ "$where" != "code-location" ]]; then
        # Refusing rather than guessing where to run it: a tenant's script in
        # the wrong context is worse than not running it.
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="declares check.in='$where', which UIS cannot run"; return 0
    fi
    # 🔴 THE RENDERED NAME, FROM THE INSTALL RECORD — not the definition.
    #
    # A definition declares `code_location.name: {{ params.app_name }}-data`.
    # Reading it raw gave a selector containing literal braces, which matched
    # nothing, and with errexit fixed that becomes a PERMANENT false
    # "COULD NOT BE ASKED" for a perfectly healthy application — the failure
    # changing costume rather than going away (imac, #937).
    #
    # `.uis.extend/applications.yaml` holds what was actually installed, keyed on
    # app_name and rendered at install time. That is the installed truth, and it
    # is also how two tenants of one template stay distinguishable.
    cl_name="${cl_csv%%,*}"
    if [[ -z "$cl_name" ]]; then
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="install record names no code location"; return 0
    fi
    if [[ "$cl_name" == *"{{"* ]]; then
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="code location '$cl_name' is unrendered — install record is wrong"; return 0
    fi
    # 🔴 `|| pod=""` FIXED THE ABORT BY DISCARDING THE STATUS, which made
    # "kubectl is broken" and "there is no pod" the same answer — and UIS then
    # stated, specifically and confidently, that there was no running pod.
    # imac replaced kubectl with a binary exiting 9 and got exactly that
    # (ops-dev, #939). An unreachable API server, a wrong context or an RBAC
    # denial all land here too.
    #
    # ⚠️ `{.items[0]…}` cannot help: it returns 1 BOTH for a real failure and for
    # an empty match. `{.items[*]…}` returns 0 with empty output when nothing
    # matched, so rc and output finally mean different things.
    local pod_list krc=0
    pod_list=$(kubectl get pods -n dagster -l "deployment=$cl_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || krc=$?
    if [[ "$krc" -ne 0 ]]; then
        CHECK_STATE="could-not-ask"
        CHECK_DETAIL="kubectl failed (exit $krc) — cannot tell whether a pod exists"
        return 0
    fi
    pod="${pod_list%% *}"
    if [[ -z "$pod" ]]; then
        # ⚠️ G1: a stopped application still produces a LINE, with a reason. It
        # must not vanish from the list and must not abort the run.
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="no running pod for code location '$cl_name'"; return 0
    fi
    # 🔴 Same conflation one line down: `!` on a kubectl exec cannot tell "the
    # command is not in the image" from "I could not reach the pod". The probe
    # therefore always exits 0 and SAYS which, so the status belongs to kubectl
    # alone (imac, #939).
    local probe prc=0
    probe=$(kubectl exec -n dagster "$pod" -- bash -lc \
        "if command -v ${run_cmd%% *} >/dev/null 2>&1 || test -x ${run_cmd%% *}; then echo PRESENT; else echo ABSENT; fi" 2>/dev/null) || prc=$?
    if [[ "$prc" -ne 0 ]]; then
        CHECK_STATE="could-not-ask"; CHECK_DETAIL="could not reach pod $pod (kubectl exec exit $prc)"; return 0
    fi
    case "$probe" in
        *PRESENT*) : ;;
        *ABSENT*)  CHECK_STATE="could-not-ask"; CHECK_DETAIL="${run_cmd%% *} is not in the image"; return 0 ;;
        *)         CHECK_STATE="could-not-ask"; CHECK_DETAIL="probe returned nothing — cannot tell if ${run_cmd%% *} is present"; return 0 ;;
    esac

    local rc=0
    # ⚠️ ONE path for both forms. The single and the listing used to resolve
    # separately, and imac's general warning applies: a collision produces one
    # defect per branch, and the branches fail differently, so the loud one
    # masks the quiet one. They now differ only in whether the output is shown.
    if [[ "$verbose" == "1" ]]; then
        kubectl exec -n dagster "$pod" -- bash -lc "$run_cmd" || rc=$?
    else
        kubectl exec -n dagster "$pod" -- bash -lc "$run_cmd" >/dev/null 2>&1 || rc=$?
    fi
    # ⚠️ The application's exit code is the verdict and is relayed, not judged.
    # UIS interprets nothing — the same contract as `operational`.
    # 🔴 THE EXIT-CODE CONTRACT. An application must be able to say "I could not
    # look", and until now it could not: `*` collapsed every non-zero code into
    # UNHEALTHY, so a check that had lost its database connection made a
    # DEFINITE claim that the data was wrong.
    #
    # imac measured it: atlas's check exits 2 for CANNOT, and with
    # ATLAS_POSTGREST_URL unset UIS reported "UNHEALTHY — reported a problem
    # (exit 2)" while the data was fine throughout (ops-dev, #946).
    #
    # ⚠️ ops-dev turned my own argument on me and was right. I removed the
    # "anything else" bucket from state 4 so a defect of MINE could not hide in
    # a benign state — and left the same bucket in place for tenants, where a
    # tenant's "could not look" hides in an alarming one.
    #
    #   0    healthy      the output reflects the input
    #   1    unhealthy    it does not — a DEFINITE claim
    #   2    cannot look  the check could not reach what it needed
    #   127  cannot look  the command or a dependency is missing (shell-reserved)
    #   *    treated as a problem, and SAID to be outside the contract
    #
    # 🔵 The remaining catch-all is deliberate and the asymmetry is the
    # principle: a catch-all must fail toward ALARM, never toward reassurance.
    # State 4's catch-all failed toward reassurance — a UIS bug looked like an
    # honest "cannot tell" — which is why it had to go. This one puts an
    # undefined code into the alarming state, and says UIS is interpreting
    # rather than relaying a meaning the contract defines.
    case "$rc" in
        0)   CHECK_STATE="healthy";       CHECK_DETAIL="reported success (relayed, not verified)" ;;
        1)   CHECK_STATE="unhealthy";     CHECK_DETAIL="reported a problem (exit 1)" ;;
        2)   CHECK_STATE="could-not-ask"; CHECK_DETAIL="the check could not reach what it needed (exit 2)" ;;
        127) CHECK_STATE="could-not-ask"; CHECK_DETAIL="the check ran but something it needs was missing (127)" ;;
        *)   CHECK_STATE="unhealthy";     CHECK_DETAIL="exit $rc is outside the check contract — treated as a problem" ;;
    esac
    return 0
}

# Command: uis template check   (no id) — every installed application
#
# 🔴 THE PER-APPLICATION FORM REQUIRES SOMEONE TO ALREADY SUSPECT THE
# APPLICATION. Nobody suspected atlas. That is why it served a deleted company
# for 7.5 hours behind five green signals (ops-dev, #935).
cmd_template_check_all() {
    local file; file="$(_applications_file)"
    if [[ ! -f "$file" ]]; then
        log_info "No applications installed."
        return 0
    fi
    command -v yq >/dev/null 2>&1 || { log_error "yq is required."; return 1; }
    _fetch_registry || true

    # ⚠️ One line per RECORD, not per id: two tenants of one template are two
    # applications with different app_names and different code locations.
    local ids
    # ⚠️ `@tsv`, not string concatenation with "\t". mikefarah yq emits a
    # LITERAL backslash-t from `+ "\t" +`, so `IFS=$'\t' read` split nothing and
    # every row arrived as one field — the id became `atlas\tatlas\tatlas-data`
    # and the selector was garbage. Found by running it, not by reading it.
    ids=$(yq -r '.applications[]? | [(.id // ""), (.app_name // ""), ((.code_locations // []) | join(","))] | @tsv' "$file" 2>/dev/null) || true
    ids=$(printf '%s\n' "$ids" | grep -v '^[[:space:]]*$') || true
    if [[ -z "$ids" ]]; then
        log_info "No applications installed."
        return 0
    fi

    print_section "Application checks"
    local n_h=0 n_u=0 n_n=0 n_c=0 n_e=0 id
    local app_name cl_csv
    while IFS=$'\t' read -r id app_name cl_csv; do
        [[ -z "$id" ]] && continue
        # 🔴 THE FIFTH STATE HAS TO BE REACHABLE OR IT IS DECORATION.
        #
        # It used to be only the INITIAL value of CHECK_STATE, overwritten by
        # all eleven terminal paths — and the one way it survived was the
        # function not finishing, which under errexit killed the process instead
        # of returning. "A green that could not have gone red" (imac, #937).
        #
        # Now it is reached two ways that can actually happen: the evaluator
        # returning non-zero, or finishing without setting a state.
        CHECK_STATE=""; CHECK_DETAIL=""
        local _rc=0
        _check_state "$id" "$cl_csv" || _rc=$?
        if [[ "$_rc" -ne 0 ]]; then
            CHECK_STATE="uis-error"; CHECK_DETAIL="evaluator exited $_rc"
        elif [[ -z "$CHECK_STATE" ]]; then
            CHECK_STATE="uis-error"; CHECK_DETAIL="evaluator set no state"
        fi
        case "$CHECK_STATE" in
            healthy)       printf '  %-22s %-22s %s
' "${app_name:-$id}" "healthy"            "$CHECK_DETAIL"; n_h=$((n_h+1)) ;;
            unhealthy)     printf '  %-22s %-22s %s
' "${app_name:-$id}" "UNHEALTHY"          "$CHECK_DETAIL"; n_u=$((n_u+1)) ;;
            no-check)      printf '  %-22s %-22s %s
' "${app_name:-$id}" "declares no check"  "$CHECK_DETAIL"; n_n=$((n_n+1)) ;;
            could-not-ask) printf '  %-22s %-22s %s
' "${app_name:-$id}" "COULD NOT BE ASKED" "$CHECK_DETAIL"; n_c=$((n_c+1)) ;;
            *)             printf '  %-22s %-22s %s
' "${app_name:-$id}" "UIS FAILED TO EVAL" "$CHECK_DETAIL"; n_e=$((n_e+1)) ;;
        esac
    done <<< "$ids"

    echo ""
    # 🔴 F3: EVERY STATE IS NAMED WITH ITS COUNT. Never "3 of 4 healthy" — that
    # arithmetic silently drops what could not be asked, which is the state the
    # 7.5 hours lived in.
    echo "  $n_h healthy · $n_u unhealthy · $n_n declare no check · $n_c could not be asked$([[ $n_e -gt 0 ]] && echo " · $n_e UIS ERRORS")"
    if [[ "$n_e" -gt 0 ]]; then
        echo "" >&2
        log_error "$n_e application(s) could not be evaluated by UIS itself."
        echo "    That is a defect here, not a state of the application. It is" >&2
        echo "    reported separately so it cannot hide inside 'could not be asked'." >&2
        return 1
    fi
    [[ "$n_u" -gt 0 ]] && return 1
    [[ "$n_c" -gt 0 || "$n_n" -gt 0 ]] && return 2
    return 0
}

# Command: uis template check <id>
#
# 🔴 WHY `check` AND NOT `status`, recorded here because Terje handed the
# grammar to me rather than arbitrating it, which makes "deliberate" my job to
# discharge rather than his.
#
# The CLI already spends both obvious words on component liveness:
#
#     status   4 places   `uis status`, `platform status`, `network status`,
#                         `secrets status` — is the thing up?
#     verify   6 places   `postgresql verify`, `alloy verify`, `argocd verify` …
#                         — does the platform's own component work?
#
# ⚠️ This command asks neither. It asks the APPLICATION whether its published
# output still reflects its input — and the incident that produced it is exactly
# a case where every liveness signal was green and the data was wrong:
#
#     atlas served a DELETED company over its public API for 7.5 hours
#     feed SUCCESS · exit_code 0 · backlog 0 · watermark advancing · API 200
#     5 instigators RUNNING
#     meanwhile the transform had failed 16 consecutive times, 119 changes were
#     unapplied — 22 of them deletions — and the register was 8.4 hours stale
#
# 🔵 So naming this `status` would give the same word to the claim that was TRUE
# and the claim that was FALSE during those 7.5 hours. The conflation is the
# defect, not a naming inconvenience.
#
# Rejected alternatives, so the next person finds the reasoning and not just the
# outcome:
#
#   `template status <id>`  a third meaning of a word already meaning liveness
#   `template verify <id>`  platform-side vocabulary; this is application-side
#   `app <id> check`        a new top-level noun for one command, and it puts the
#                           subject before the verb, breaking `template <verb> <id>`
#
# ⚠️ `--check` exists as a FLAG on `pull` ("is there an update"). Different
# surface, different grammatical role, and no collision — but worth knowing.
# ── uis template progress <id> ───────────────────────────────────────────────
#
# 🔴 NOTHING ANSWERED "HOW FAR THROUGH THE FIRST INSTALL AM I?"
#
# Terje asked for status while a cold install was running and imac answered by
# reading its own script's log and poking kubectl — the thing this programme
# spent the day removing. What the product said at that moment was:
#
#     ✗ cannot answer: relation "marts.dim_brreg_enhet" does not exist
#     ⚠ COULD NOT BE ASKED (exit 2)
#
# ⚠️ That is CORRECT. The marts tables genuinely did not exist and the check
# refused to guess. But to an operator whose install is progressing perfectly it
# is a red ✗ that reads as breakage — and every other status verb reports
# LIVENESS, which this programme established is green while the data is absent
# (ops-dev, urb-agents#1023; reference implementation by imac in uis-tester).
#
# 🔵 So this verb exists to say "that red ✗ is expected right now", with the
# evidence for why.

# Classify declared first-data jobs against Dagster's run history.
#
# 🔴 SEPARATED FROM THE PROBE ON PURPOSE. The probe needs a cluster; this needs
# a JSON blob. A classifier that can only be exercised against a live install is
# one whose FAILURE path never gets tested — and the failure path is the one that
# matters most here, because a first-data job failing while the summary says "in
# flight" is worse than no command at all.
#
# Sets: PROG_LINES, PROG_DONE, PROG_FAILED, PROG_RUNNING, PROG_ABSENT,
#       PROG_FAILED_NAMES, PROG_UNDECLARED
_progress_classify() {
    local runs_json="$1" jobs="$2" now="${3:-0}"
    PROG_LINES=""; PROG_DONE=0; PROG_FAILED=0; PROG_RUNNING=0; PROG_ABSENT=0
    PROG_FAILED_NAMES=""; PROG_UNDECLARED=""; PROG_ELAPSED=""; PROG_WINDOW_FROM=""
    # ⚠️ `now` is a PARAMETER, not a `date` call in here. A classifier that
    # reads the clock cannot be tested against a fixture twice and get the same
    # answer, and this function exists precisely so its failure path can be
    # driven on demand.

    # Latest run per job, by startTime. A job re-run after a failure must read as
    # its CURRENT state, not its worst ever.
    local latest
    latest=$(printf '%s' "$runs_json" | jq -c '
        [ (.data.runsOrError.results // [])[] | select(.jobName != null) ]
        | group_by(.jobName)
        | map(sort_by(.startTime // 0) | last)
        | INDEX(.jobName)' 2>/dev/null) || latest="{}"
    [[ -z "$latest" || "$latest" == "null" ]] && latest="{}"

    local j
    for j in $jobs; do
        local st dur line
        st=$(printf '%s' "$latest" | jq -r --arg j "$j" '.[$j].status // ""' 2>/dev/null)
        # 🔴 AN IN-FLIGHT JOB GETS AN ELAPSED TOO, and that is the point of this
        # change. An operator told "~11 minutes" who is 25 minutes in has no way
        # to tell SLOW from STUCK (ops-dev, #1026) — measured wall time is the
        # only answer that does not depend on anyone's prose being current.
        dur=$(printf '%s' "$latest" | jq -r --arg j "$j" --argjson now "${now:-0}" '
            if (.[$j].startTime != null and .[$j].endTime != null)
            then "  " + (((.[$j].endTime - .[$j].startTime) | floor | tostring) + "s")
            elif (.[$j].startTime != null and $now > 0)
            then "  " + ((($now - .[$j].startTime) | floor | tostring) + "s so far")
            else "" end' 2>/dev/null)
        case "$st" in
            "")        line=$(printf '    %-26s %s' "$j" "·  not started"); PROG_ABSENT=$((PROG_ABSENT+1)) ;;
            SUCCESS)   line=$(printf '    %-26s %s%s' "$j" "✅ succeeded" "$dur"); PROG_DONE=$((PROG_DONE+1)) ;;
            FAILURE|CANCELED)
                       line=$(printf '    %-26s %s%s' "$j" "🔴 FAILED" "$dur")
                       PROG_FAILED=$((PROG_FAILED+1)); PROG_FAILED_NAMES+="$j " ;;
            STARTED|STARTING|QUEUED|NOT_STARTED|CANCELING)
                       line=$(printf '    %-26s ⏳ %s%s' "$j" "$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')" "$dur")
                       PROG_RUNNING=$((PROG_RUNNING+1)) ;;
            # ⚠️ A status this release does not know is NOT folded into a state it
            # does. Counting it as "in flight" would be the guess that turns a
            # stuck install into a progressing one.
            *)         line=$(printf '    %-26s ?  %s (status this UIS does not recognise)' "$j" "$st")
                       PROG_RUNNING=$((PROG_RUNNING+1)) ;;
        esac
        PROG_LINES+="$line"$'\n'
    done

    # 🔵 THE CASCADE TOTAL, from the orchestrator's own timestamps rather than
    # from an estimate. Earliest start of a declared job to the latest end — or
    # to `now` while anything is still running.
    if [[ "$PROG_DONE" -gt 0 || "$PROG_RUNNING" -gt 0 || "$PROG_FAILED" -gt 0 ]]; then
        # 🔴 AND IT REPORTS WHERE THE WINDOW STARTS, NOT ONLY HOW WIDE IT IS.
        #
        # `$from` is the earliest recorded run of a declared job on this
        # Dagster — EVER. Dagster's run history survives an upgrade, so on an
        # upgraded host this measures from the ORIGINAL install: imac saw
        # "143794s elapsed so far (2397 min)" on a host installed two days
        # earlier, under a line telling the operator to prefer that figure over
        # the application's estimate (ops-dev, urb-agents#1152).
        #
        # ⚠️ Harmless on a cold install. Misleading on an upgrade — which is
        # precisely the case where someone is watching the clock to decide
        # whether it hung.
        #
        # ⚠️ THE NUMBER IS NOT SILENTLY NARROWED to "since this install". The
        # record that would scope it is keyed on app_name, so a template with
        # two tenants has two install times and no rule here picks between them
        # — and a window that quietly means something different from one host to
        # the next is worse than a wide one that says where it starts. The
        # caller prints the start; the reader decides.
        local _pw
        _pw=$(printf '%s' "$latest" | jq -r --argjson now "${now:-0}" --arg jobs "$jobs" '
            ($jobs | split(" ")) as $want
            | [ to_entries[] | select(.key as $k | $want | index($k)) | .value ] as $rs
            | ([ $rs[] | .startTime // empty ] | min) as $from
            | ([ $rs[] | .endTime // empty ] | max) as $to
            | if $from == null then " "
              elif ([ $rs[] | select(.endTime == null) ] | length) > 0 and $now > 0
                then ((($now - $from) | floor | tostring) + " " + (($from | floor) | tostring))
              elif $to == null then " "
              else ((($to - $from) | floor | tostring) + " " + (($from | floor) | tostring)) end' 2>/dev/null) || _pw=""
        # ⚠️ Split on a SPACE, not a literal tab. Both halves are integers, and
        # this project has already been bitten twice by a "\t" that arrived as
        # two characters.
        PROG_ELAPSED="${_pw%% *}"; PROG_WINDOW_FROM="${_pw##* }"
        [[ "$PROG_ELAPSED" =~ ^[0-9]+$ ]] || PROG_ELAPSED=""
        [[ "$PROG_WINDOW_FROM" =~ ^[0-9]+$ ]] || PROG_WINDOW_FROM=""
    fi

    # 🔵 P5's second half. The declared order is printed; a job Dagster has RUN
    # that the definition does not declare is a real disagreement between the
    # artifact and the orchestrator, and naming it beats silently preferring
    # either list.
    local ran
    ran=$(printf '%s' "$latest" | jq -r 'keys[]?' 2>/dev/null)
    local r
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        case " $jobs " in *" $r "*) ;; *) PROG_UNDECLARED+="$r " ;; esac
    done <<< "$ran"
    return 0
}

# The summary sentence, and the exit code. Kept beside the classifier so both
# are exercised by the same fixtures.
#
# 🔴 FOUR STATES, EACH COUNTED. Never "N of 6 done": that arithmetic drops what
# has NOT STARTED, which is the state a fresh install spends most of its life in
# (imac's P1).
_progress_summary() {
    local declared_takes="${1:-}"
    printf '\n    %s succeeded · %s failed · %s in flight · %s not started\n' \
        "$PROG_DONE" "$PROG_FAILED" "$PROG_RUNNING" "$PROG_ABSENT"

    # 🔴 MEASURED WALL TIME, AND THE APPLICATION'S ESTIMATE, SIDE BY SIDE.
    #
    # ops-dev: "an operator told ~11 minutes who is 25 minutes in has no way to
    # tell slow from stuck." A cold install measured 29.5 minutes against an
    # estimate of ~11, which was written on a warm host and predates the bulk
    # load (#1026).
    #
    # ⚠️ UIS does NOT correct the estimate — it belongs to the application and
    # only the application can revise it. What the platform can do is show what
    # actually happened next to it, so the reader does not have to trust either
    # one alone. The same reason the check verb exists at all.
    if [[ -n "$PROG_ELAPSED" && "$PROG_ELAPSED" -gt 0 ]] 2>/dev/null; then
        printf '    %s elapsed so far, measured from Dagster (%s min)\n' \
            "${PROG_ELAPSED}s" "$(( (PROG_ELAPSED + 30) / 60 ))"
        # 🔴 SAY WHEN THE WINDOW OPENED. Without this the figure reads as "this
        # install", and on an upgraded host it is not: Dagster's run history
        # survives, so the earliest recorded run of a declared job can belong to
        # an install two days ago. One absolute timestamp turns a number the
        # operator would have trusted into one they can check.
        if [[ -n "$PROG_WINDOW_FROM" ]]; then
            printf '      measured from the first recorded run of these jobs: %s\n' \
                "$(date -u -d "@$PROG_WINDOW_FROM" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                   || date -u -r "$PROG_WINDOW_FROM" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                   || printf 'epoch %s' "$PROG_WINDOW_FROM")"
            printf '      ⚠️  that is EVERY recorded run on this Dagster, not this install.\n'
            printf '          An upgraded host keeps its run history, so check that date\n'
            printf '          before reading the figure above as "how long this has taken".\n'
        fi
        if [[ -n "$declared_takes" ]]; then
            printf '    the application estimates: %s\n' \
                "$(printf '%s' "$declared_takes" | tr '\n' ' ' | cut -c1-96)"
            printf '    ⚠️  that estimate is the APPLICATION'"'"'S and may predate its own\n'
            printf '        workloads. The elapsed figure above is measured — prefer it\n'
            printf '        WHEN its window starts at this install, and not otherwise.\n'
        fi
    fi
    if [[ -n "$PROG_UNDECLARED" ]]; then
        printf '\n    ⚠️  Dagster has run jobs this definition does not declare as first data:\n'
        printf '        %s\n' "${PROG_UNDECLARED% }"
        printf '        Either the artifact is behind, or something ran out of band.\n'
    fi
    if [[ "$PROG_FAILED" -gt 0 ]]; then
        printf '\n    🔴 A first-data job FAILED: %s\n' "${PROG_FAILED_NAMES% }"
        printf '       The install is NOT progressing. It is stuck, and it will stay\n'
        printf '       stuck until that job is fixed and re-run — nothing retries it.\n'
        return 1
    fi
    if [[ "$PROG_RUNNING" -gt 0 ]]; then
        printf '\n    ⏳ First data is still loading.\n'
        printf '       ⚠️  A red ✗ from `uis template check` is EXPECTED until this\n'
        printf '           finishes. It means the tables do not exist yet, which is\n'
        printf '           true and is not breakage.\n'
        return 0
    fi
    if [[ "$PROG_ABSENT" -gt 0 && "$PROG_DONE" -eq 0 ]]; then
        printf '\n    ⚠️  Nothing has run yet. First-data jobs do NOT self-trigger.\n'
        printf '       Read the order this application documents:\n'
        printf '         ./uis template info <id>   → operational.first_data.how\n'
        return 0
    fi
    if [[ "$PROG_ABSENT" -gt 0 ]]; then
        printf '\n    ⚠️  %s first-data job(s) have never run. Run them in the documented order.\n' "$PROG_ABSENT"
        return 0
    fi
    printf '\n    ✅ Every first-data job has succeeded. `uis template check` is\n'
    printf '       meaningful from now on.\n'
    printf '       ⚠️  Loaded is not RUNNING: a fresh install ships with automation\n'
    printf '           STOPPED. Switch it on with `uis dagster automation --start`.\n'
    return 0
}

# Read Dagster's run history and instigator state through one throwaway pod.
#
# ⚠️ `kubectl run curlimages/curl` rather than exec-ing into an existing pod,
# because what is inside the webserver image is not this repository's to assume —
# and the same pattern is already proven on a real cluster in
# 361-dagster-automation.yml. The query is imac's, verified against the deployed
# chart rather than written from the docs.
#
# 🔴 IT RETURNS NON-ZERO ONLY WHEN IT COULD NOT LOOK. "Dagster answered and
# nothing has run" and "Dagster did not answer" must never arrive as the same
# value — rendering an unreachable orchestrator as "nothing has run yet" is
# imac's P4, and it is the failure mode that would make this verb worse than
# silence.
_progress_read_dagster() {
    local probe="uis-progress-$RANDOM"
    local q1='{"query":"{ runsOrError { ... on Runs { results { jobName status startTime endTime } } } }"}'
    local q2='{"query":"{ repositoriesOrError { ... on RepositoryConnection { nodes { schedules { name scheduleState { status } } sensors { name sensorState { status } } } } } }"}'
    # Both queries in ONE pod. `RUNSPLIT` separates them because two JSON
    # documents concatenated are not parseable, and inventing a wrapper would be
    # a format only this function understands.
    local script out krc=0
    script="curl -s -m 20 -X POST -H 'Content-Type: application/json' -d '$q1' http://dagster-dagster-webserver:80/graphql; echo; echo RUNSPLIT; curl -s -m 20 -X POST -H 'Content-Type: application/json' -d '$q2' http://dagster-dagster-webserver:80/graphql"
    out=$(kubectl run "$probe" --image=curlimages/curl --restart=Never \
            -n dagster --quiet --rm -i --command -- \
            sh -c "echo $(printf '%s' "$script" | base64 -w0) | base64 -d | sh" 2>/dev/null) || krc=$?
    # ⚠️ rc AND content, because `--rm -i` has been seen to return 0 with empty
    # stdout when the container outlives the attach — the same hazard 360-test
    # and 361 both name. Either one failing is "could not look".
    if [[ "$krc" -ne 0 || -z "$out" || "$out" != *runsOrError* ]]; then
        PROGRESS_RUNS=""; PROGRESS_AUTO=""
        return 1
    fi
    PROGRESS_RUNS="${out%%RUNSPLIT*}"
    PROGRESS_AUTO="${out#*RUNSPLIT}"
    # ⚠️ The automation half failing does NOT make the progress half unusable.
    # It is reported as unreadable rather than allowed to fail the command that
    # was asked about first data.
    [[ "$PROGRESS_AUTO" == *repositoriesOrError* ]] || PROGRESS_AUTO=""
    return 0
}

# imac's P6: "all data loaded" is NOT "running". A fresh install ships STOPPED,
# so the two are routinely different and belong in the same breath.
#
# 🔴 UNREADABLE IS ITS OWN ANSWER HERE TOO. An empty automation payload must not
# print "0 running" — that is a claim, and the wrong one.
_progress_automation_line() {
    local payload="$1"
    if [[ -z "$payload" ]]; then
        echo "    (could not read automation state — './uis dagster automation' asks directly)"
        return 0
    fi
    # 🔴 A CODE LOCATION THAT HAS NOT FINISHED LOADING DECLARES NOTHING, AND
    # THAT IS NOT THE SAME AS DECLARING NOTHING.
    #
    # Three minutes after install, `uis template progress atlas` said "Dagster
    # declares no schedules or sensors — nothing to switch on" while FIVE were
    # declared and running; re-run later it read "5 RUNNING, 0 STOPPED, of 5
    # declared" (imac via ops-dev, urb-agents#1152/#1146).
    #
    # ⚠️ The reading was not wrong about what it could see. The CONCLUSION was
    # wrong, and it is wrong in exactly the minutes an operator runs `progress`
    # — "nothing to switch on" does not read as "try again later", it reads as
    # permission to SKIP enabling automation. That is the step that makes every
    # asset check ever run, and skipping it leaves a loaded, unvalidated install
    # with nothing to say so.
    #
    # 🔵 So the node count is read FIRST. `repositoriesOrError` lists
    # repositories that have loaded; a location still starting, or one that
    # failed to load (the payload is then a PythonError and `... on
    # RepositoryConnection` matches nothing), is absent rather than empty. Zero
    # nodes is 'nobody has reported in', which is a different sentence from
    # 'they reported in and declare none'.
    #
    # ⚠️ AND THE MESSAGE DOES NOT QUOTE THE SENTENCE IT REPLACES, not even to
    # deny it. The first version said "so this is NOT 'nothing to switch on'";
    # its own test failed it, because a reader skimming for that phrase finds it
    # either way — and so does any assertion. A negation is not a safe place to
    # repeat the words you are trying to stop someone acting on.
    local nodes counts
    nodes=$(printf '%s' "$payload" | jq -r '(.data.repositoriesOrError.nodes // []) | length' 2>/dev/null) || nodes=""
    if [[ ! "$nodes" =~ ^[0-9]+$ ]]; then
        echo "    (could not read automation state — './uis dagster automation' asks directly)"
        return 0
    fi
    if [[ "$nodes" -eq 0 ]]; then
        echo "    No code location has reported to Dagster yet, so this is"
        echo "    'cannot tell yet', not 'there are none'. A code location still"
        echo "    loading declares nothing until it finishes, and a few minutes"
        echo "    is normal. Re-run this; './uis dagster verify' lists what has"
        echo "    loaded."
        return 0
    fi
    counts=$(printf '%s' "$payload" | jq -r '
        [ (.data.repositoriesOrError.nodes // [])[]
          | ((.schedules // [])[] | .scheduleState.status),
            ((.sensors   // [])[] | .sensorState.status) ]
        | "\([ .[] | select(. == "RUNNING") ] | length) RUNNING, \([ .[] | select(. != "RUNNING") ] | length) STOPPED, of \(length) declared"' 2>/dev/null) || counts=""
    # ⚠️ AND AN UNPARSEABLE PAYLOAD IS NOT 'NONE' EITHER. This branch used to
    # catch `-z "$counts"` too, so a jq failure printed "declares no schedules or
    # sensors" — the same claim-from-silence one line down from the comment
    # saying an empty payload must never print "0 running".
    if [[ -z "$counts" ]]; then
        echo "    (could not read automation state — './uis dagster automation' asks directly)"
        return 0
    fi
    if [[ "$counts" == *"of 0 declared"* ]]; then
        echo "    This code location has loaded and declares no schedules or"
        echo "    sensors — nothing to switch on."
        return 0
    fi
    echo "    $counts"
    case "$counts" in
        "0 RUNNING"*) echo "    ⚠️  Nothing is switched on. Data loading and automation are separate"
                      echo "        decisions: './uis dagster automation --start' switches them on." ;;
    esac
    return 0
}

cmd_template_progress() {
    local app_id="${1:-}"
    if [[ -z "$app_id" ]]; then
        log_error "Usage: uis template progress <id>"
        echo "  Answers 'how far through the first install am I, and is that normal?'" >&2
        return 1
    fi

    _fetch_registry || return 2

    # The declared order comes from the ARTIFACT, not from a list in this file.
    # imac's reference implementation hardcodes it and says so; the product does
    # not have to, because the definition declares it (imac's P5).
    local template artifact tag digest vis dir info
    template=$(_get_template "$app_id" 2>/dev/null) || true
    if [[ -z "$template" || "$template" == "null" ]]; then
        log_error "'$app_id' is not in the registry — cannot read its first-data order."
        return 2
    fi
    artifact="$(_template_source_field "$template" artifact)"
    tag="$(_template_source_field "$template" tag)"
    digest="$(_template_source_field "$template" digest)"
    vis="$(_json_field "$template" '.visibility')"; vis="${vis:-public}"
    dir=$(_resolve_definition "$app_id" "$artifact" "$tag" "$digest" "$vis" 2>/dev/null) || dir=""
    if [[ -z "$dir" || ! -f "$dir/template-info.yaml" ]]; then
        log_error "Could not fetch the definition for '$app_id' — cannot read its first-data order."
        return 2
    fi
    info="$dir/template-info.yaml"

    local jobs
    jobs=$(yq -r '[.operational.first_data.jobs // []] | flatten | join(" ")' "$info" 2>/dev/null) || jobs=""
    if [[ -z "$jobs" || "$jobs" == "null" ]]; then
        # 🔵 Not an error and not "could not look": this application never said
        # it had a first-data sequence. Same distinction as `no-check`.
        print_section "Install progress: $app_id"
        echo "  This application declares no operational.first_data.jobs, so there is"
        echo "  no first-data sequence to report progress through."
        echo "  'uis template check $app_id' is the question to ask instead."
        return 0
    fi

    print_section "Install progress: $app_id"
    echo "  first-data order, as this application declares it:"
    printf '    %s\n' "$(printf '%s' "$jobs" | tr ' ' '\n' | sed -n '1,20p' | paste -sd' ' -)"
    echo ""

    if ! _progress_read_dagster; then
        log_error "COULD NOT ASK — Dagster's GraphQL API did not answer."
        echo "  ⚠️  This is NOT 'nothing has run yet'. An unreachable orchestrator, a" >&2
        echo "      wrong kube context and an RBAC denial all land here, and reporting" >&2
        echo "      any of them as 'no progress' would be a false negative about the" >&2
        echo "      one thing this command exists to report." >&2
        echo "  './uis verify dagster' asks whether the orchestrator is alive at all." >&2
        return 2
    fi

    local takes
    takes=$(yq -r '.operational.first_data.takes // ""' "$info" 2>/dev/null) || takes=""
    _progress_classify "$PROGRESS_RUNS" "$jobs" "$(date -u +%s)"
    printf '%s' "$PROG_LINES"
    local rc=0
    _progress_summary "$takes" || rc=$?

    # imac's P6: loaded is not running, and a fresh install ships STOPPED, so the
    # two are routinely different. Reported in the same breath rather than
    # leaving the operator to find the other verb.
    echo ""
    echo "  Automation (a fresh install ships STOPPED):"
    _progress_automation_line "$PROGRESS_AUTO"
    return "$rc"
}

# Read Dagster's instigator state: how many schedules and sensors are RUNNING.
#
# 🔴 A HEALTHY VERDICT ON A STOPPED PIPELINE IS A FALSE ALL-CLEAR.
#
# `uis template check atlas` reported healthy, exit 0, and told the operator
# "3 newer deletion(s) awaiting the next transform (:10/:40) — not a fault"
# while every schedule and sensor was STOPPED. There is no next transform. The
# sentence is not incomplete, it is FALSE (imac via ops-dev, urb-agents#1036).
#
# ⚠️ AND IT IS THE FIRST STATE EVERY OPERATOR IS IN. A fresh install ships with
# automation stopped, so the documented happy path — install, load first data,
# run the status command — passes straight through it.
#
# 🔵 imac's framing: "a false alarm wastes attention, a false all-clear spends
# it." The sentence was added to FIX a false alarm, and that fix was right; it
# asserts a future event without checking that anything is scheduled to produce
# it.
#
# Sets AUTO_RUNNING / AUTO_TOTAL, or returns 1 when it could not look — which is
# NOT the same as zero running and must never be rendered as such.
_check_automation_state() {
    AUTO_RUNNING=""; AUTO_TOTAL=""; AUTO_STOPPED_NAMES=""
    command -v jq >/dev/null 2>&1 || return 1
    local probe="uis-autostate-$RANDOM" out krc=0
    local q='{"query":"{ repositoriesOrError { ... on RepositoryConnection { nodes { schedules { name scheduleState { status } } sensors { name sensorState { status } } } } } }"}'
    out=$(kubectl run "$probe" --image=curlimages/curl --restart=Never \
            -n dagster --quiet --rm -i --command -- \
            curl -s -m 20 -X POST -H 'Content-Type: application/json' \
            -d "$q" http://dagster-dagster-webserver:80/graphql 2>/dev/null) || krc=$?
    [[ "$krc" -ne 0 || -z "$out" || "$out" != *repositoriesOrError* ]] && return 1
    local counts
    counts=$(printf '%s' "$out" | jq -r '
        [ (.data.repositoriesOrError.nodes // [])[]
          | ((.schedules // [])[] | .scheduleState.status),
            ((.sensors   // [])[] | .sensorState.status) ]
        | "\([ .[] | select(. == "RUNNING") ] | length) \(length)"' 2>/dev/null) || return 1
    [[ "$counts" =~ ^[0-9]+\ [0-9]+$ ]] || return 1
    AUTO_RUNNING="${counts%% *}"; AUTO_TOTAL="${counts##* }"

    # 🔴 NAME THE STOPPED ONES. "4 RUNNING, 1 STOPPED" reads as mostly fine, and
    # the one stopped instigator is precisely the one backing the false sentence
    # — so the partial case survives a glance at BOTH commands (imac via
    # ops-dev, urb-agents#1046).
    #
    # ⚠️ UIS still does not claim WHICH instigator a check's sentence depends on
    # — only the application knows that. But the names are a measured fact UIS
    # owns, and printing them lets the reader do the correlation that UIS cannot
    # honestly do for them. "1 STOPPED: brreg_transform_half_hourly" beside a
    # sentence about "the next transform" is legible; a bare count is not.
    AUTO_STOPPED_NAMES=$(printf '%s' "$out" | jq -r '
        [ (.data.repositoriesOrError.nodes // [])[]
          | ((.schedules // [])[] | select(.scheduleState.status != "RUNNING") | .name),
            ((.sensors   // [])[] | select(.sensorState.status   != "RUNNING") | .name) ]
        | join(", ")' 2>/dev/null) || AUTO_STOPPED_NAMES=""
    return 0
}

# Qualify a check verdict with what is actually running.
#
# 🔴 THE ONE RULE ops-dev ASSERTED: the output must not say a scheduled event is
# coming without having checked that something is scheduled. So this prints a
# measured fact and withholds trust in forward-looking sentences. It never
# claims the application is wrong about its data.
#
# ⚠️ ONLY 0-OF-N CHANGES THE EXIT CODE, and the boundary is deliberate:
#
#   0 running     nothing can be producing output, so "does the output reflect
#                 the input" is UNANSWERABLE, not answered. could-not-ask.
#   some running  UIS cannot tell whether the stopped one is the one this
#                 check's claim depended on. Only the application knows which
#                 instigator its own sentence refers to — so this qualifies the
#                 OUTPUT and leaves the verdict alone, rather than inventing a
#                 new false alarm to replace the false all-clear.
#   could not look  says so. Silence here would be the could-not-look defect
#                 this project has paid for repeatedly.
#
# 🔴 IT BUILDS TEXT RATHER THAN PRINTING IT, so the caller can put the
# retraction ABOVE the relayed verdict. "atlas reported success" printed above
# "NOTHING IS RUNNING" — the exit code was right and the retraction unmissable
# if read, but a reader skimming top-down met "reported success" first, on a
# command whose whole job is not to mislead at a glance (imac via ops-dev,
# urb-agents#1046). That ordering was structural, so the structure changed.
#
# Sets QUALIFY_TEXT and QUALIFY_RC (0 keep the verdict, 2 downgrade it).
_check_qualify_by_automation() {
    local state="$1"
    QUALIFY_TEXT=""; QUALIFY_RC=0
    if [[ -z "$AUTO_TOTAL" ]]; then
        QUALIFY_TEXT="$(cat <<'EOT'
⚠  Could not read whether anything is scheduled to run.
    So a sentence below about a future scheduled run cannot be relied on
    here — and this is 'could not look', not 'nothing is running'.
    './uis dagster automation' asks directly.
EOT
)"
        return 0
    fi
    [[ "$AUTO_TOTAL" == "0" ]] && return 0
    [[ "$AUTO_RUNNING" == "$AUTO_TOTAL" ]] && return 0

    local stopped_line=""
    [[ -n "$AUTO_STOPPED_NAMES" ]] && stopped_line="    stopped: ${AUTO_STOPPED_NAMES}"$'\n'

    if [[ "$AUTO_RUNNING" == "0" ]]; then
        QUALIFY_TEXT="⚠  NOTHING IS RUNNING: 0 of $AUTO_TOTAL schedules and sensors are switched on."$'\n'
        QUALIFY_TEXT+="$stopped_line"
        QUALIFY_TEXT+="$(cat <<'EOT'
    Any sentence below about a future run — 'awaiting the next transform',
    a cadence, 'not a fault' — assumes something is scheduled. Nothing is.

    ⚠️  So this is not a clean bill of health. It is a question that
        cannot be answered: with nothing producing output, whether the
        output reflects the input is undecidable.

    A fresh install ships stopped. Switch it on:
      ./uis dagster automation --start
EOT
)"
        [[ "$state" == "healthy" ]] && QUALIFY_RC=2
        return 0
    fi

    # 🔴 THE PARTIAL CASE IS QUIETER, NOT MILDER. One stopped instigator beside
    # four running ones reads as mostly fine — and it is the stopped one that
    # backs the false sentence. UIS still cannot claim WHICH instigator a
    # check's claim depends on, so the verdict is left alone; what changed is
    # that the names are printed, so the reader can make the connection UIS
    # cannot honestly make for them.
    QUALIFY_TEXT="⚠  $AUTO_RUNNING of $AUTO_TOTAL schedules and sensors are running — and the stopped one may be the one that matters."$'\n'
    QUALIFY_TEXT+="$stopped_line"
    QUALIFY_TEXT+="$(cat <<'EOT'
    If a sentence below expects a future scheduled run, check it against
    that list by name. A count alone reads as mostly fine.

    UIS cannot tell which instigator this application's claim depends on —
    only the application knows that — so the verdict below is left as it
    was rather than guessed at.
EOT
)"
    return 0
}

cmd_template_check() {
    local template_id="${1:-}"
    [[ -z "$template_id" ]] && { cmd_template_check_all; return $?; }

    command -v yq >/dev/null 2>&1 || { log_error "yq is required."; return 1; }
    _fetch_registry || true

    # 🔴 Resolve through the INSTALL RECORD, like the listing. Reading the
    # definition's `code_location.name` raw gave `{{ params.app_name }}-data`,
    # which matches no pod — a permanent false COULD NOT BE ASKED for a healthy
    # application (imac, #937).
    local file cl_csv
    file="$(_applications_file)"
    if [[ ! -f "$file" ]]; then
        log_error "'$template_id' is not installed (no application record)."
        return 2
    fi
    cl_csv=$(app_id="$template_id" yq -r '[.applications[]? | select(.id == strenv(app_id)) | (.code_locations // []) | join(",")] | .[0] // ""' "$file" 2>/dev/null) || cl_csv=""
    if [[ -z "$cl_csv" ]]; then
        log_error "'$template_id' has no install record with a code location."
        echo "    NOTHING WAS CHECKED — it may not be installed here." >&2
        return 2
    fi

    print_section "Check: $template_id"
    CHECK_STATE=""; CHECK_DETAIL=""
    local _rc=0
    _check_state "$template_id" "$cl_csv" 1 || _rc=$?
    if [[ "$_rc" -ne 0 ]]; then
        CHECK_STATE="uis-error"; CHECK_DETAIL="evaluator exited $_rc"
    elif [[ -z "$CHECK_STATE" ]]; then
        CHECK_STATE="uis-error"; CHECK_DETAIL="evaluator set no state"
    fi

    # 🔴 READ WHAT IS RUNNING BEFORE RELAYING A VERDICT ABOUT THE FUTURE.
    _check_automation_state || true

    echo "" >&2
    case "$CHECK_STATE" in
        healthy)
            # 🔴 THE RETRACTION GOES FIRST WHEN THERE IS ONE. A reader skimming
            # top-down used to meet "reported success" before the line that
            # takes it back (imac via ops-dev, #1046). The exit code was already
            # right; the ORDER was the defect, on a command whose whole job is
            # not to mislead at a glance.
            _check_qualify_by_automation healthy
            if [[ "$QUALIFY_RC" -eq 2 && -n "$QUALIFY_TEXT" ]]; then
                printf '  %s\n' "$QUALIFY_TEXT" >&2
                echo "" >&2
                echo "  Below is what the application itself reported, which UIS" >&2
                echo "  relayed and did not verify:" >&2
            fi
            echo "  $template_id reported success. UIS relayed this; it did not verify it." >&2
            # ⚠️ AND SAY WHAT THE SUCCESS WAS ABOUT. "Reported success" reads as
            # "the application is working"; the application's own description
            # says which question it answered. Anything outside that question is
            # not covered by this exit code, and only the declaration can say
            # where the edge is.
            if [[ -n "$CHECK_SCOPE" ]]; then
                echo "" >&2
                echo "  What that verdict covers, in the application's own words:" >&2
                printf '    %s\n' "$(printf '%s' "$CHECK_SCOPE" | tr '\n' ' ' | sed 's/  */ /g')" >&2
                echo "    ⚠️  Anything outside that question is NOT covered by this" >&2
                echo "        exit code, however healthy it reads." >&2
            fi
            # A qualification that does NOT retract the verdict still belongs
            # after it — it is a caveat, not a correction.
            if [[ "$QUALIFY_RC" -ne 2 && -n "$QUALIFY_TEXT" ]]; then
                echo "" >&2
                printf '  %s\n' "$QUALIFY_TEXT" >&2
            fi
            [[ "$QUALIFY_RC" -eq 2 ]] && return 2
            return 0 ;;
        unhealthy)
            log_warn "$template_id $CHECK_DETAIL"
            _check_qualify_by_automation unhealthy
            [[ -n "$QUALIFY_TEXT" ]] && { echo "" >&2; printf '  %s\n' "$QUALIFY_TEXT" >&2; }
            return 1 ;;
        no-check)
            log_warn "'$template_id' declares no check command."
            echo "    This application cannot tell you whether its output reflects" >&2
            echo "    its input. Its pods may be healthy and its data still wrong." >&2
            echo "" >&2
            echo "    An application declares one in template-info.yaml:" >&2
            echo "      commands:" >&2
            echo "        check:" >&2
            echo "          run: /path/to/script   # must ship IN THE IMAGE" >&2
            echo "          in: code-location" >&2
            return 2 ;;
        could-not-ask)
            log_warn "COULD NOT BE ASKED — $CHECK_DETAIL"
            echo "    This is neither healthy nor unhealthy. NOTHING WAS CHECKED." >&2
            return 2 ;;
        *)
            log_error "UIS failed to evaluate '$template_id': $CHECK_DETAIL"
            echo "    That is a defect here, not a state of the application." >&2
            return 1 ;;
    esac
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

# Command: uis template install <id>
cmd_template_install() {
    local template_id="${1:-}"
    shift || true

    if [[ -z "$template_id" ]]; then
        log_error "Usage: uis template install <id> [--dry-run] [--refresh] [--param key=value]... [--version <tag>@<digest>]"
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
            --refresh)
                # Re-read the registry rather than trusting the hourly cache.
                # The novice case this exists for: an application published in
                # the last hour reads as "not found" without it (#716).
                REGISTRY_REFRESH=true
                shift
                ;;
            --version)
                # 🔴 INSTALL A VERSION THE CATALOGUE DOES NOT POINT AT.
                #
                # Without this the catalogue pin is the only installable thing,
                # so a nominee could not be verified until after it had been
                # advertised to everyone. Every nomination to date was therefore
                # unverified at install, or verified by hand-editing a registry
                # cache — a method nobody reproduces, and a step nobody
                # reproduces is one that quietly stops happening (ops-dev,
                # #981).
                if [[ -z "${2:-}" ]]; then
                    log_error "--version needs <tag>@<digest>"
                    return 1
                fi
                OFF_CATALOGUE_SPEC="$2"
                shift 2
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
                echo "Usage: uis template install <id> [--dry-run] [--refresh] [--param key=value]... [--version <tag>@<digest>]" >&2
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
        _registry_staleness_hint "$template_id"
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
        CATALOGUE_TAG="$SOURCE_TAG"
        CATALOGUE_DIGEST="$SOURCE_DIGEST"
        if [[ -n "${OFF_CATALOGUE_SPEC:-}" ]]; then
            _apply_off_catalogue_version "$template_id" || return 1
        fi
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
            local cl_n cl_i cl_t cl_m cl_w cl_s cl_d
            cl_n=$(_substitute_params "$(_conf_get "$conf" code_location_name)" "$params_file")
            cl_i=$(_substitute_params "$(_conf_get "$conf" code_location_image)" "$params_file")
            cl_t=$(_substitute_params "$(_conf_get "$conf" code_location_tag)" "$params_file")
            cl_m=$(_substitute_params "$(_conf_get "$conf" code_location_module)" "$params_file")
            cl_w=$(_substitute_params "$(_conf_get "$conf" code_location_why)" "$params_file")
            cl_s=$(_substitute_params "$(_conf_get "$conf" code_location_env_secrets)" "$params_file")
            cl_d=$(_substitute_params "$(_conf_get "$conf" code_location_digest)" "$params_file")

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

            # 🔴 THE INSTALLER ALREADY KNOWS THE VALUE AND WAS NOT PASSING IT.
            #
            # atlas's check needs ATLAS_POSTGREST_URL; the artifact exports
            # `api-url: http://api-{{ params.app_name }}.localhost`; the
            # installer computes it and PRINTS it to the operator — and the pod
            # that runs the check never sees it. So a stock install reported
            # "could not look" on a healthy application (ops-dev, #950).
            #
            # ⚠️ atlas declined the easy fix and was right to: "a tool that
            # answers 'healthy' without ever asking the public API is the false
            # pass this whole command exists to prevent." The cannot-look state
            # is the SAFETY NET; the variable arriving is the OUTCOME.
            #
            # 🔵 Declared as NAME -> export key, not as a value, so nothing is
            # restated. The definition already says what the URL is once.
            local cl_e cl_x cl_sv cl_svenv
            cl_e=$(_conf_get "$conf" code_location_env_from_exports)
            cl_x="{}"
            [[ -n "$cl_e" ]] && cl_x=$(_collect_exports "$info_file" "$params_file")
            # 🔵 env_from_services is resolved HERE, not in the writer: composing
            # the address needs services.json and app_name, both of which are
            # install-time facts. The writer is handed literals and writes them.
            cl_sv=$(_conf_get "$conf" code_location_env_from_services)
            cl_svenv="{}"
            if [[ -n "$cl_sv" ]]; then
                cl_svenv=$(_resolve_service_env "$cl_sv" "$(_conf_param "$params_file" app_name)") || {
                    log_error "Could not resolve env_from_services for code location '$cl_n'."
                    return 1
                }
            fi
            _write_code_location "$cl_n" "$cl_i" "$cl_t" "$cl_m" "$cl_w" "$cl_s" "$cl_d" "$cl_e" "$cl_x" "$cl_svenv" || return 1

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
        echo "      A dependant's \`requires: $template_id\` will not see it." >&2
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

    # ⚠️ Immediately after Endpoints, deliberately. An install that says where
    # the API is and not that it is empty on purpose invites the reader to
    # conclude the install failed.
    _install_summary_operational "$info_file" "$template_id"
    # Content that reaches no surface at all — the case the two-renderer
    # comparison is blind to by construction.
    _warn_unrendered_operational "$info_file"

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

    # 🔴 `--help` WAS READ AS AN APPLICATION ID, and inconsistently.
    #
    #     uis template check --help    -> "'--help' has no install record"
    #     uis template install --help  -> "Template '--help' not found in
    #                                      registry", then advised --refresh:
    #                                      offering to re-read the catalogue to
    #                                      look harder for an application called
    #                                      --help
    #
    # ⚠️ `uis --help` and `uis dagster --help` already honoured it, which is what
    # makes this a defect rather than a missing feature — two of five surfaces
    # behaved and three did not (Terje via ops-dev, urb-agents#1031).
    #
    # 🔵 Handled ONCE, before dispatch. Five copies of the same guard is five
    # things that drift apart.
    local _a
    for _a in "$@"; do
        case "$_a" in
            --help|-h) set --; subcmd="help"; break ;;
        esac
    done

    case "$subcmd" in
        list)
            [[ "${1:-}" == "--refresh" ]] && REGISTRY_REFRESH=true
            cmd_template_list
            ;;
        info)
            # ⚠️ `--refresh` on every reader, not only install. `info` is what a
            # person runs when `install` says "not found", so it is the second
            # place the stale cache would confirm the wrong answer (#716).
            local _iargs=()
            for _a in "$@"; do
                case "$_a" in
                    --refresh) REGISTRY_REFRESH=true ;;
                    *) _iargs+=("$_a") ;;
                esac
            done
            cmd_template_info "${_iargs[@]}"
            ;;
        install)
            cmd_template_install "$@"
            ;;
        check)
            cmd_template_check "$@"
            ;;
        progress)
            cmd_template_progress "$@"
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
            echo "  check <id>        Ask the application whether its output reflects its input"
            echo '                    (not liveness — `status` and `verify` are the words for that)'
            echo "  progress <id>     How far through the FIRST INSTALL am I, and is that normal?"
            echo "                    Names four states — not started, in flight, succeeded,"
            echo '                    FAILED — and says when a red x from `check` is expected.'
            echo "                    Exit 1 if a first-data job failed; 2 if it could not look."
            echo "  list              List available UIS templates"
            echo "    --refresh       Re-read the registry instead of the hourly cache."
            echo "                    An application published in the last hour reads as"
            echo "                    \"not found\" without it."
            echo "  info <id>         Show template details"
            echo "  install <id>      Install a template (deploy + configure services)"
            echo "                    --version <tag>@<digest> installs a version the"
            echo "                    catalogue does NOT point at, for verifying a"
            echo "                    nominee before it is advertised. Recorded, and"
            echo "                    'template info' says so until a plain install"
            echo "                    replaces it."
            echo "    --dry-run       Pull the definition and print the numbered plan."
            echo "                    Installs NOTHING. The best way to see what an"
            echo "                    application is before committing to it."
            echo "  remove <id>       Remove an installed application (data is kept unless --purge)"
            echo ""
            echo "Examples:"
            echo "  uis template list"
            echo "  uis template info postgresql-demo"
            echo "  uis template install postgresql-demo --dry-run"
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
