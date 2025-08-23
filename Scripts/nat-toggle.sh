#!/usr/bin/env bash
# Enable/disable NAT masquerading from usb0 → uplink (eth0|wlan0)
set -euo pipefail
ACTION=${1:-}
UPLINK=${2:-eth0}

if [ "$ACTION" != on ] && [ "$ACTION" != off ]; then
  echo "usage: $0 on|off [uplink]" >&2; exit 2; fi

cat >/tmp/nft-nat.conf <<EOF
flush ruleset

# Persist filter (allow fwd between usb0 and uplink)
table inet filter {
  chain input { type filter hook input priority 0; policy accept; }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state related,established accept
    iifname "usb0" oifname "$UPLINK" accept
    iifname "$UPLINK" oifname "usb0" accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}

# NAT table (postrouting masquerade)
$([ "$ACTION" = on ] && cat <<ON || true)
table inet nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "$UPLINK" masquerade
  }
}
ON
EOF

nft -f /tmp/nft-nat.conf
rm -f /tmp/nft-nat.conf

echo "NAT $ACTION on uplink=$UPLINK"
