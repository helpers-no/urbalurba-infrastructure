#!/bin/bash
# init.sh — Interactive wizard for proxmox onboarding.
#
# Entry point: ./uis platform init proxmox
#
# Its EXISTENCE at this path is also what makes UIS recognize proxmox as
# a platform at all — pf_list_platforms (provision-host/uis/lib/
# platform-switching.sh) discovers platforms by looking for
# platforms/<name>/scripts/init.sh, and pf_banner's "is this a UIS platform"
# check does the same. Found running this for real: without this file,
# `./uis deploy` printed "Platform: proxmox (not a UIS platform —
# proceeding with kubectl context anyway)" even with a perfectly healthy
# cluster active.
#
# Prompts for the one thing that can't have a sane default — your own three
# machines — and writes config.sh. Does NOT touch Proxmox or create anything;
# that's scripts/02-k3s-preflight.sh (verifies) and 03-k3s-apply.sh (builds).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"
TEMPLATE_FILE="$PLATFORM_DIR/config.sh-template"

echo "═══════════════════════════════════════════════════════════"
echo " Proxmox + k3s lab setup wizard"
echo " (uis platform init proxmox)"
echo " Writes config.sh. No Proxmox or k3s changes are made yet."
echo "═══════════════════════════════════════════════════════════"
echo

if [[ ! -t 0 ]]; then
    echo "✗ This wizard needs an interactive terminal." >&2
    echo "  Run './uis shell' first, or copy config.sh-template to config.sh" >&2
    echo "  by hand and fill it in yourself." >&2
    exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
    read -r -p "config.sh already exists. Overwrite? [y/N] " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || { echo "Keeping existing config.sh."; exit 0; }
fi

cp "$TEMPLATE_FILE" "$CONFIG_FILE"

echo
echo "Before continuing: each of your 3 machines needs Proxmox already"
echo "installed and joined into one cluster. If you haven't done that yet,"
echo "stop here and read README.md's \"Before you start\" section first —"
echo "one of those steps needs you to type a password by hand, so there's"
echo "no point filling in the rest of this until it's done."
echo
read -r -p "Have you already done that? [y/N] " ready
if [[ "$ready" != "y" && "$ready" != "Y" ]]; then
    echo "No changes made beyond copying the template to config.sh — edit it"
    echo "yourself when you're ready, or re-run this wizard."
    exit 0
fi

ask() {
    local prompt="$1" default="$2" var
    read -r -p "$prompt [$default]: " var
    echo "${var:-$default}"
}

echo
echo "── The three Proxmox hosts ──"
h1_name="$(ask "Host 1 name" "host1")"
h1_addr="$(ask "Host 1 address" "192.168.1.10")"
h2_name="$(ask "Host 2 name" "host2")"
h2_addr="$(ask "Host 2 address" "192.168.1.11")"
h3_name="$(ask "Host 3 name (your weakest machine — gets a lighter VM)" "host3")"
h3_addr="$(ask "Host 3 address" "192.168.1.12")"

echo
echo "── Networking ──"
gw="$(ask "Gateway" "192.168.1.1")"
prefix="$(ask "Network prefix length (e.g. 24 for a /24)" "24")"

sed -i.bak \
    -e "s/PROXMOX_HOST1_NAME=\"host1\"/PROXMOX_HOST1_NAME=\"${h1_name}\"/" \
    -e "s/PROXMOX_HOST1_ADDR=.*/PROXMOX_HOST1_ADDR=\"${h1_addr}\"/" \
    -e "s/PROXMOX_HOST2_NAME=\"host2\"/PROXMOX_HOST2_NAME=\"${h2_name}\"/" \
    -e "s/PROXMOX_HOST2_ADDR=.*/PROXMOX_HOST2_ADDR=\"${h2_addr}\"/" \
    -e "s/PROXMOX_HOST3_NAME=\"host3\"/PROXMOX_HOST3_NAME=\"${h3_name}\"/" \
    -e "s/PROXMOX_HOST3_ADDR=.*/PROXMOX_HOST3_ADDR=\"${h3_addr}\"/" \
    -e "s/NETWORK_GATEWAY=.*/NETWORK_GATEWAY=\"${gw}\"/" \
    -e "s/NETWORK_DNS=.*/NETWORK_DNS=\"${gw}\"/" \
    -e "s/NETWORK_PREFIX_LENGTH=.*/NETWORK_PREFIX_LENGTH=\"${prefix}\"/" \
    "$CONFIG_FILE"
rm -f "${CONFIG_FILE}.bak"

echo
echo "═══════════════════════════════════════════════════════════"
echo " ✓ config.sh written"
echo "═══════════════════════════════════════════════════════════"
echo "  Review the rest of config.sh — the six k3s VMs' addresses, sizing,"
echo "  and VMIDs still have template defaults that may collide with your"
echo "  own network or numbering."
echo
echo "Next: ./uis platform up proxmox"
