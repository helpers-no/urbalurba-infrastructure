#!/bin/bash
# uis-docs-plan-indexes.sh - Generate index pages for plan folders
#
# Scans plan files in active/, backlog/, completed/ and generates
# index.md files with tables listing all plans sorted by date.
#
# Usage:
#   ./uis-docs-plan-indexes.sh [plans-dir]
#
# If plans-dir is not specified, auto-detects from script location.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$UIS_DIR/lib"

# Source logging if available, otherwise use echo
if [[ -f "$LIB_DIR/logging.sh" ]]; then
    source "$LIB_DIR/logging.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ============================================================
# Path Detection
# ============================================================

_detect_plans_dir() {
    if [[ -n "${1:-}" ]]; then
        echo "$1"
        return 0
    fi
    # Container path
    if [[ -d "/mnt/urbalurbadisk/website" ]]; then
        echo "/mnt/urbalurbadisk/website/docs/ai-developer/plans"
        return 0
    fi
    # Host path: derive from script location
    local base_dir
    base_dir="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    if [[ -d "$base_dir/website/docs/ai-developer/plans" ]]; then
        echo "$base_dir/website/docs/ai-developer/plans"
        return 0
    fi
    log_error "Cannot find plans directory"
    exit 1
}

# ============================================================
# Metadata Extraction
# ============================================================

# Extract title from line 1 (# Title)
_extract_title() {
    local file="$1"
    head -1 "$file" | sed 's/^# //'
}

# Extract a **Field**: value line from first 15 lines
_extract_field() {
    local file="$1"
    local field="$2"
    head -15 "$file" | grep "^\*\*${field}\*\*:" | sed "s/^\*\*${field}\*\*: *//" | head -1
}

# Get file modification date (YYYY-MM-DD)
# ⚠️ The date comes from GIT, not from mtime. mtime is a checkout artefact: a
# fresh clone stamps every file with the clone time, so the "Updated"/"Completed"
# column read 2026-09-04 for all 125 completed plans (a clone date), then
# 2026-09-07 for all of them (a CI runner's checkout date). It has never once
# held the date anything was completed, and CI overwrote it on every run.
#
# Requires a non-shallow checkout. With fetch-depth 1 `git log -1 -- <file>`
# returns nothing for any file not touched by the single fetched commit, which
# would make this silently revert to the old behaviour — so the fallback WARNS,
# once, rather than degrading quietly. That is the failure mode this repository
# hit three times last week: a correct-looking mechanism defeated by its
# environment, in a path nobody watches.
_PLAN_DATE_FELL_BACK=0
_file_date() {
    local file="$1" d
    d="$(git -C "$(dirname "$file")" log -1 --format=%cs -- "$(basename "$file")" 2>/dev/null)"
    if [[ -n "$d" ]]; then
        echo "$d"
        return 0
    fi
    if [[ "$_PLAN_DATE_FELL_BACK" -eq 0 ]]; then
        _PLAN_DATE_FELL_BACK=1
        echo "⚠️  git gave no date for $(basename "$file") — falling back to file mtime," >&2
        echo "    which is a checkout artefact. If this ran in CI, the checkout is" >&2
        echo "    shallow: generate-uis-docs.yml needs fetch-depth: 0." >&2
    fi
    # macOS
    stat -f '%Sm' -t '%Y-%m-%d' "$file" 2>/dev/null && return 0
    # Linux (GNU coreutils)
    date -r "$file" '+%Y-%m-%d' 2>/dev/null && return 0
    echo "—"
}

# Extract goal — tries Goal, then Problem Statement first line
_extract_goal() {
    local file="$1"
    local goal
    goal="$(_extract_field "$file" "Goal")"
    if [[ -z "$goal" ]]; then
        goal="$(awk '/^## Problem Statement/{found=1; next} found && /^[A-Z]/{print; exit}' "$file")"
    fi
    echo "$goal"
}

# ============================================================
# Index Generation
# ============================================================

# Generate a table of plans from a directory
# Args: directory, output_file
_generate_folder_index() {
    local dir="$1"
    local output="$2"
    local folder_name
    folder_name="$(basename "$dir")"

    # Collect metadata from all .md files (skip index.md and README.md)
    local entries=()
    local file
    for file in "$dir"/*.md; do
        [[ ! -f "$file" ]] && continue
        local basename
        basename="$(basename "$file")"
        [[ "$basename" = "index.md" ]] && continue
        [[ "$basename" = "README.md" ]] && continue

        local title goal updated filename_no_ext
        title="$(_extract_title "$file")"
        goal="$(_extract_goal "$file")"
        updated="$(_file_date "$file")"
        filename_no_ext="${basename%.md}"

        # Default if missing
        [[ -z "$goal" ]] && goal="—"

        # Store as pipe-delimited for sorting
        entries+=("${updated}|${filename_no_ext}|${title}|${goal}")
    done

    # Sort by date descending (newest first)
    local sorted
    sorted="$(printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -r)"

    # Count
    local count
    count="$(echo "$sorted" | grep -c . || true)"

    # Write the index
    case "$folder_name" in
        active)
            cat > "$output" <<HEADER
---
# ⚠️ GENERATED FILE - DO NOT EDIT BY HAND.
# Rewritten in full by provision-host/uis/manage/uis-docs-plan-indexes.sh, which
# GitHub Actions runs on merge. Anything you add here is silently deleted on the
# next run - a note added to active/index.md on 2026-08-30 survived four minutes.
# Prose about what is being worked on belongs in plans/backlog/1PRIORITY.md, which
# is not generated. To change what these pages SAY, edit the generator.
title: Active Plans
sidebar_position: 1
---

# Active Plans

Plans currently being implemented. Maximum 1-2 at a time.

| Plan | Goal | Updated |
|------|------|---------|
HEADER
            ;;
        backlog)
            cat > "$output" <<HEADER
---
# ⚠️ GENERATED FILE - DO NOT EDIT BY HAND.
# Rewritten in full by provision-host/uis/manage/uis-docs-plan-indexes.sh, which
# GitHub Actions runs on merge. Anything you add here is silently deleted on the
# next run - a note added to active/index.md on 2026-08-30 survived four minutes.
# Prose about what is being worked on belongs in plans/backlog/1PRIORITY.md, which
# is not generated. To change what these pages SAY, edit the generator.
title: Backlog
sidebar_position: 1
---

# Backlog

Investigations and plans waiting for implementation, sorted by last updated date.

| Document | Goal | Updated |
|----------|------|---------|
HEADER
            ;;
        completed)
            cat > "$output" <<HEADER
---
# ⚠️ GENERATED FILE - DO NOT EDIT BY HAND.
# Rewritten in full by provision-host/uis/manage/uis-docs-plan-indexes.sh, which
# GitHub Actions runs on merge. Anything you add here is silently deleted on the
# next run - a note added to active/index.md on 2026-08-30 survived four minutes.
# Prose about what is being worked on belongs in plans/backlog/1PRIORITY.md, which
# is not generated. To change what these pages SAY, edit the generator.
title: Completed
sidebar_position: 1
---

# Completed Plans

All completed plans and investigations, sorted by date. Kept for reference.

⚠️ **"Last updated" is the last commit that touched the file, not a completion
date.** It was labelled "Completed" and read from file mtime, which made it a
checkout artefact — every row showed whichever day the repository was last
cloned. Git dates are honest but they still move when a file is edited for any
reason: a bulk Status normalisation on 2026-09-08 is why most rows share a date.

Where a real completion date matters it lives in the plan's own `**Status:**`
line, which carries one for the plans whose authors recorded it.

| Plan | Goal | Last updated |
|------|------|-----------|
HEADER
            ;;
    esac

    # Append rows
    while IFS='|' read -r date filename_no_ext title goal; do
        [[ -z "$filename_no_ext" ]] && continue
        echo "| [${title}](${filename_no_ext}.md) | ${goal} | ${date} |" >> "$output"
    done <<< "$sorted"

    log_info "  ${folder_name}/index.md — ${count} items"
}

# Generate the top-level plans/index.md
_generate_plans_overview() {
    local plans_dir="$1"
    local output="$plans_dir/index.md"

    cat > "$output" <<'HEADER'
---
title: Plans Overview
sidebar_position: 1
slug: /ai-developer/plans-overview
---

# Plans

Implementation plans and investigations for the UIS platform. Plans follow the workflow described in [WORKFLOW.md](../WORKFLOW.md) and use the templates in [PLANS.md](../PLANS.md).

## Plan Types

| Type | When to use |
|------|-------------|
| `PLAN-*.md` | Solution is clear, ready to implement |
| `INVESTIGATE-*.md` | Needs research first, approach unclear |
| `STATUS-*.md` | Tracks ongoing status across multiple items |

## Folders

| Folder | Purpose |
|--------|---------|
| [Active](active/index.md) | Currently being worked on (max 1-2 at a time) |
| [Backlog](backlog/index.md) | Approved plans and investigations waiting for work |
| [Completed](completed/index.md) | Done — kept for reference |

## Platform Roadmap

See [1PRIORITY.md](backlog/1PRIORITY.md) for the prioritized list of open investigations and completed work.
HEADER

    log_info "  plans/index.md"
}

# ============================================================
# Main
# ============================================================

main() {
    local plans_dir
    plans_dir="$(_detect_plans_dir "${1:-}")"

    if [[ ! -d "$plans_dir" ]]; then
        log_error "Plans directory not found: $plans_dir"
        exit 1
    fi

    log_info "Generating plan indexes in: $plans_dir"

    _generate_plans_overview "$plans_dir"

    for folder in active backlog completed; do
        local dir="$plans_dir/$folder"
        if [[ -d "$dir" ]]; then
            _generate_folder_index "$dir" "$dir/index.md"
        fi
    done

    log_info "Done"
}

main "$@"
