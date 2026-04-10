#!/bin/bash
# menu-helpers.sh - Dialog menu utilities for UIS
#
# Provides functions for creating interactive TUI menus using dialog.
# Falls back to text-based prompts if dialog is not available.

# Guard against multiple sourcing
[[ -n "${_UIS_MENU_HELPERS_LOADED:-}" ]] && return 0
_UIS_MENU_HELPERS_LOADED=1

# Determine script directory for sourcing siblings
_MENU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$_MENU_SCRIPT_DIR/logging.sh"

# Check if dialog is available
has_dialog() {
    command -v dialog &>/dev/null
}

# Check if whiptail is available (fallback)
has_whiptail() {
    command -v whiptail &>/dev/null
}

# Get the menu command to use
get_menu_cmd() {
    if has_dialog; then
        echo "dialog"
    elif has_whiptail; then
        echo "whiptail"
    else
        echo ""
    fi
}

# Show a simple message box
# Usage: show_msgbox "Title" "Message"
show_msgbox() {
    local title="$1"
    local message="$2"
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        "$cmd" --title "$title" --msgbox "$message" 10 50
    else
        echo "" >&2
        echo "=== $title ===" >&2
        echo "$message" >&2
        echo "" >&2
        read -p "Press Enter to continue..."
    fi
}

# Show a yes/no dialog
# Usage: show_yesno "Title" "Question"
# Returns: 0 for yes, 1 for no
show_yesno() {
    local title="$1"
    local question="$2"
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        "$cmd" --title "$title" --yesno "$question" 10 50
        return $?
    else
        echo "" >&2
        echo "=== $title ===" >&2
        echo "$question" >&2
        read -p "[y/N]: " answer
        [[ "$answer" =~ ^[Yy] ]] && return 0
        return 1
    fi
}

# Show an input box
# Usage: show_inputbox "Title" "Prompt" "Default"
# Output: User input to stdout
show_inputbox() {
    local title="$1"
    local prompt="$2"
    local default="${3:-}"
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        local result
        result=$("$cmd" --title "$title" --inputbox "$prompt" 10 50 "$default" 3>&1 1>&2 2>&3)
        local status=$?
        echo "$result"
        return $status
    else
        echo "" >&2
        echo "=== $title ===" >&2
        read -p "$prompt [$default]: " answer
        echo "${answer:-$default}"
        return 0
    fi
}

# Show a menu with choices
# Usage: show_menu "Title" "Prompt" "tag1" "item1" "tag2" "item2" ...
# Output: Selected tag to stdout
show_menu() {
    local title="$1"
    local prompt="$2"
    shift 2
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        local result
        result=$("$cmd" --title "$title" --menu "$prompt" 20 60 12 "$@" 3>&1 1>&2 2>&3)
        local status=$?
        echo "$result"
        return $status
    else
        echo "" >&2
        echo "=== $title ===" >&2
        echo "$prompt" >&2
        echo "" >&2
        local i=1
        local -a tags=()
        while [[ $# -gt 0 ]]; do
            tags+=("$1")
            echo "  $i. $1 - $2" >&2
            shift 2
            ((++i))
        done
        echo "" >&2
        read -p "Choice [1-$((i-1))]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#tags[@]}" ]]; then
            echo "${tags[$((choice-1))]}"
            return 0
        fi
        return 1
    fi
}

# Show a checklist
# Usage: show_checklist "Title" "Prompt" "tag1" "item1" "on/off" ...
# Output: Space-separated selected tags to stdout
show_checklist() {
    local title="$1"
    local prompt="$2"
    shift 2
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        local result
        result=$("$cmd" --title "$title" --checklist "$prompt" 20 60 12 "$@" 3>&1 1>&2 2>&3)
        local status=$?
        echo "$result"
        return $status
    else
        echo "" >&2
        echo "=== $title ===" >&2
        echo "$prompt" >&2
        echo "" >&2
        local i=1
        local -a tags=()
        local -a states=()
        while [[ $# -gt 0 ]]; do
            tags+=("$1")
            local state="$3"
            states+=("$state")
            local marker="[ ]"
            [[ "$state" == "on" ]] && marker="[*]"
            echo "  $i. $marker $1 - $2" >&2
            shift 3
            ((++i))
        done
        echo "" >&2
        echo "Enter numbers to toggle (space-separated), then press Enter:" >&2
        read -p "> " toggles

        # Build result from selected items
        local result=""
        for idx in "${!tags[@]}"; do
            local num=$((idx + 1))
            if [[ "${states[$idx]}" == "on" ]] || [[ " $toggles " == *" $num "* ]]; then
                if [[ "${states[$idx]}" != "on" ]] || [[ " $toggles " != *" $num "* ]]; then
                    result+="${tags[$idx]} "
                fi
            fi
        done
        echo "$result"
        return 0
    fi
}

# Show a radiolist
# Usage: show_radiolist "Title" "Prompt" "tag1" "item1" "on/off" ...
# Output: Selected tag to stdout
show_radiolist() {
    local title="$1"
    local prompt="$2"
    shift 2
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        local result
        result=$("$cmd" --title "$title" --radiolist "$prompt" 20 60 12 "$@" 3>&1 1>&2 2>&3)
        local status=$?
        echo "$result"
        return $status
    else
        # Fall back to simple menu for radiolist
        local -a menu_args=()
        while [[ $# -gt 0 ]]; do
            menu_args+=("$1" "$2")
            shift 3  # Skip the on/off state
        done
        show_menu "$title" "$prompt" "${menu_args[@]}"
    fi
}

# Show a gauge/progress bar
# Usage: echo "progress" | show_gauge "Title" "Message" percent
show_gauge() {
    local title="$1"
    local message="$2"
    local percent="${3:-0}"
    local cmd
    cmd=$(get_menu_cmd)

    if [[ -n "$cmd" ]]; then
        "$cmd" --title "$title" --gauge "$message" 8 50 "$percent"
    else
        echo "$message... ${percent}%"
    fi
}

# Clear the screen (for menu transitions)
clear_screen() {
    if has_dialog || has_whiptail; then
        clear
    fi
}

# Get terminal dimensions
get_term_height() {
    tput lines 2>/dev/null || echo 24
}

get_term_width() {
    tput cols 2>/dev/null || echo 80
}
