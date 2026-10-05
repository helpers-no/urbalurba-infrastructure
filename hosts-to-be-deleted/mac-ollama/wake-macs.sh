#!/bin/bash
# Wake a sleeping Mac Ollama backend with a Wake-on-LAN magic packet.
#
#   ./wake-macs.sh          # wake whichever backends are not responding
#   ./wake-macs.sh m4       # wake just the M4
#   ./wake-macs.sh m1       # wake just the M1
#
# WHY THIS WORKS: both Macs have "Wake for network access" enabled, so the
# Wi-Fi chip stays reachable while the CPU sleeps. A magic packet brings the
# machine back. Verified on the M4 2026-08-02: asleep for ~30 min, all TCP
# ports closed, woke and served Ollama on the first poll after the packet.
#
# This is a RECOVERY tool, not a prevention one. To stop the Macs sleeping in
# the first place, see the "Keeping the Macs awake" section in README.md - that
# has to be configured on each Mac, it cannot be done from here.
#
# NOTE ON MAC ADDRESSES: both Macs use Apple "Private Wi-Fi Address"
# randomisation (the a6:/d6: prefixes are locally-administered). The address is
# stable per network, but if you toggle Private Wi-Fi Address on the Mac, or
# join a different network, re-read it with:
#
#     ping -c1 <ip> >/dev/null; ip neigh show <ip>

set -uo pipefail

# name:ip:mac
BACKENDS=(
    "m4:192.168.68.58:a6:c1:40:ca:2a:da"
    "m1:192.168.68.70:d6:18:47:95:84:36"
)

# Derive the real subnet broadcast rather than assuming a /24. This LAN is a
# /22 (192.168.68.0/22), so the broadcast is 192.168.71.255 - hardcoding
# 192.168.68.255 would silently target an ordinary host address instead.
BROADCAST="$(ip -4 route get 192.168.68.58 2>/dev/null |
    grep -oP 'dev \K\S+' |
    head -1 |
    xargs -r -I{} ip -4 addr show {} 2>/dev/null |
    grep -oP 'brd \K[0-9.]+' |
    head -1)"
BROADCAST="${BROADCAST:-255.255.255.255}"

WANT="${1:-all}"

send_magic() {
    local mac="$1" ip="$2"
    python3 - "$mac" "$ip" "$BROADCAST" <<'PY'
import socket, sys
mac, ip, bcast = sys.argv[1], sys.argv[2], sys.argv[3]
pkt = b'\xff' * 6 + bytes.fromhex(mac.replace(':', '')) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for tgt in [(bcast, 9), ('255.255.255.255', 9), (ip, 9), (bcast, 7)]:
    try:
        s.sendto(pkt, tgt)
    except OSError:
        pass
PY
}

is_up() {
    curl -s --max-time 5 "http://$1:11434/api/version" 2>/dev/null | grep -q version
}

rc=0
for entry in "${BACKENDS[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    ip="${rest%%:*}"
    mac="${rest#*:}"

    [ "$WANT" != "all" ] && [ "$WANT" != "$name" ] && continue

    if is_up "$ip"; then
        echo "$name ($ip): already awake"
        continue
    fi

    echo "$name ($ip): asleep - sending magic packet to $mac"
    send_magic "$mac" "$ip"

    woke=false
    for i in $(seq 1 12); do
        if is_up "$ip"; then
            echo "$name ($ip): awake after ~$((i * 5))s"
            woke=true
            break
        fi
    done

    if [ "$woke" = false ]; then
        echo "$name ($ip): STILL ASLEEP after ~60s." >&2
        echo "  - is the Mac powered and on this network?" >&2
        echo "  - is 'Wake for network access' still enabled on it?" >&2
        echo "  - has the private Wi-Fi MAC changed? (see note at top of this script)" >&2
        rc=1
    fi
done

exit $rc
