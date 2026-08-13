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
_file_date() {
    local file="$1"
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
title: Completed
sidebar_position: 1
---

# Completed Plans

All completed plans and investigations, sorted by date. Kept for reference.

| Plan | Goal | Completed |
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
