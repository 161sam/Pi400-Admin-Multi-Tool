#!/usr/bin/env bash
set -euo pipefail
# PXE/iPXE/HTTP-Boot smoke test
# - checks dnsmasq config, pxelinux files, menu validity, nginx reachability
# - optional fetch of kernel/initrd paths provided as args
# Usage:
#   sudo bash smoke-pxe.sh [kernel_relpath] [initrd_relpath]
# Example:
#   sudo bash smoke-pxe.sh ubuntu/vmlinuz ubuntu/initrd

TFTP_ROOT=${TFTP_ROOT:-/srv/tftpboot}
MENU=${TFTP_ROOT}/pxelinux.cfg/default
HTTP_URL=${HTTP_URL:-http://127.0.0.1:8080}

pass(){ echo -e "\e[32mOK\e[0m  $*"; }
warn(){ echo -e "\e[33mWARN\e[0m $*"; }
fail(){ echo -e "\e[31mFAIL\e[0m $*"; }

# dnsmasq config syntax (if using distro's dnsmasq)
if command -v dnsmasq >/dev/null; then
  if dnsmasq --test >/dev/null 2>&1; then pass "dnsmasq config syntax ok"; else warn "dnsmasq --test failed (check /etc/dnsmasq.d/pxe.conf)"; fi
else warn "dnsmasq not installed"; fi

# pxelinux files present
[[ -f ${TFTP_ROOT}/pxelinux.0 ]] && pass "pxelinux.0 present" || fail "pxelinux.0 missing"
[[ -f ${TFTP_ROOT}/ldlinux.c32 ]] && pass "ldlinux.c32 present" || warn "ldlinux.c32 missing"
[[ -f ${MENU} ]] && pass "menu default present" || warn "pxelinux.cfg/default missing"

# menu sanity
if [[ -f ${MENU} ]]; then
  grep -q '^DEFAULT' "$MENU" && pass "menu has DEFAULT" || warn "DEFAULT not found in menu"
fi

# HTTP
if command -v curl >/dev/null; then
  curl -fsS "${HTTP_URL}/pxelinux.0" >/dev/null && pass "HTTP pxelinux.0 reachable" || warn "HTTP pxelinux.0 not reachable"
  if [[ -n "${1:-}" ]]; then
    curl -fsS "${HTTP_URL}/$1" -o /dev/null && pass "HTTP kernel reachable: $1" || warn "HTTP kernel missing: $1"
  fi
  if [[ -n "${2:-}" ]]; then
    curl -fsS "${HTTP_URL}/$2" -o /dev/null && pass "HTTP initrd reachable: $2" || warn "HTTP initrd missing: $2"
  fi
else warn "curl not installed"; fi

# leases/logs
[[ -f /var/lib/misc/dnsmasq.leases ]] && pass "dnsmasq leases file exists" || warn "dnsmasq.leases missing (no PXE clients yet?)"
journalctl -u dnsmasq -n 20 --no-pager || true

echo "Smoke PXE done."
