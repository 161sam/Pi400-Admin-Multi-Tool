#!/usr/bin/env bash
set -euo pipefail
# Pi400 Admin Multi-Tool — First-Boot Self-Check
# Usage: bash self-check.sh [--fix]
#  --fix : versucht, inaktive Services zu enablen/starten und einfache Probleme zu beheben

FIX=false
[[ "${1:-}" == "--fix" ]] && FIX=true || true

# ---------- helpers ----------
C_RESET='\e[0m'; C_RED='\e[31m'; C_GREEN='\e[32m'; C_YELLOW='\e[33m'; C_BLUE='\e[34m'
ok(){ echo -e "${C_GREEN}OK${C_RESET}  $*"; }
warn(){ echo -e "${C_YELLOW}WARN${C_RESET} $*"; }
fail(){ echo -e "${C_RED}FAIL${C_RESET} $*"; }
info(){ echo -e "${C_BLUE}INFO${C_RESET} $*"; }

exists(){ command -v "$1" >/dev/null 2>&1; }
svc_active(){ systemctl is-active --quiet "$1"; }
svc_enable(){ systemctl is-enabled --quiet "$1"; }
try_start(){ systemctl start "$1" 2>/dev/null || true; }
try_enable(){ systemctl enable "$1" 2>/dev/null || true; }

PIN_FILE="/etc/pi400-admin/pin"
CONSENT_FILE="/etc/pi400-admin/consent.token"
UDS="/run/pi400-admin/backend.sock"
BACKEND_BIN="/opt/admin-bin/admin-backend"
FRONTEND_BIN="/opt/admin-bin/admin-panel-iced"
TFTP_ROOT="/srv/tftpboot"
NFS_IMAGES="/srv/nfs/images"

PASS=0; FAIL=0; WARN=0
sum_ok(){ PASS=$((PASS+1)); ok "$1"; }
sum_fail(){ FAIL=$((FAIL+1)); fail "$1"; }
sum_warn(){ WARN=$((WARN+1)); warn "$1"; }

section(){ echo; echo "===== $* ====="; }

section "System & Pakete"
info "Kernel: $(uname -a)"
for p in xserver-xorg xinit matchbox-window-manager unclutter autossh socat nftables python3 pass gnupg rng-tools yubikey-manager git build-essential pkg-config libssl-dev curl dnsmasq nfs-kernel-server pxelinux syslinux-common pv xz-utils gzip parted dosfstools rsync nginx bsdtar rustc cargo; do
  if exists "$p"; then sum_ok "cmd $p found"; else sum_warn "cmd $p missing"; fi
done

section "Binaries & Config"
[[ -x "$BACKEND_BIN" ]] && sum_ok "backend binary present" || sum_fail "backend binary missing ($BACKEND_BIN)"
[[ -x "$FRONTEND_BIN" ]] && sum_ok "frontend binary present" || sum_fail "frontend binary missing ($FRONTEND_BIN)"
[[ -s "$PIN_FILE" ]] && sum_ok "PIN present" || sum_warn "PIN missing ($PIN_FILE)"
[[ -s "$CONSENT_FILE" ]] && sum_ok "Consent token present" || sum_warn "Consent token missing ($CONSENT_FILE)"

section "Services"
SERV=(admin-backend.service admin-backend-sock.service kiosk.service pi400-gadget-ensure.service target-serial-tcp.service)
for s in "${SERV[@]}"; do
  if svc_active "$s"; then sum_ok "$s active"; else sum_warn "$s inactive"; $FIX && try_start "$s"; fi
  if svc_enable "$s"; then sum_ok "$s enabled"; else sum_warn "$s disabled"; $FIX && try_enable "$s"; fi
done

section "Backend API über UDS"
if [[ -S "$UDS" ]]; then
  if exists curl; then
    PIN=$(cat "$PIN_FILE" 2>/dev/null || echo 0000)
    if out=$(curl --silent --unix-socket "$UDS" -H "x-admin-pin: $PIN" http://unix/api/health 2>/dev/null); then
      echo "$out" | grep -q '"ok":true' && sum_ok "backend /api/health reachable" || sum_fail "backend health bad response: $out"
    else
      sum_fail "curl to backend failed"
    fi
  else
    sum_warn "curl missing; skip UDS check"
  fi
else
  sum_warn "UDS not found: $UDS (admin-backend-sock.service running?)"
fi

section "USB Gadget & Netzwerk (usb0)"
UDC=$(ls /sys/class/udc 2>/dev/null | head -n1 || true)
if [[ -n "$UDC" ]]; then sum_ok "UDC present: $UDC"; else sum_warn "No UDC present — native Device-Mode evtl. nicht verfügbar"; fi
if ip link show usb0 >/dev/null 2>&1; then
  sum_ok "usb0 exists"
  ip -4 addr show usb0 | grep -q "10.66.0.1/30" && sum_ok "usb0 has 10.66.0.1/30" || sum_warn "usb0 IP not set"
else
  sum_warn "usb0 interface missing — Gadget not up"
fi

section "NAT"
if nft list table inet natpi >/dev/null 2>&1; then sum_ok "nft natpi table present"; else sum_warn "nft natpi table missing (nat-toggle.sh on <uplink>)"; fi

section "PXE / dnsmasq / NFS / TFTP/HTTP"
svc_active dnsmasq.service && sum_ok "dnsmasq running" || sum_warn "dnsmasq not running"
svc_active nfs-kernel-server.service && sum_ok "nfs-kernel-server running" || sum_warn "nfs-kernel-server not running"
[[ -f "$TFTP_ROOT/pxelinux.0" ]] && sum_ok "pxelinux.0 present" || sum_warn "pxelinux.0 missing (copy from /usr/lib/PXELINUX)"
[[ -f "$TFTP_ROOT/pxelinux.cfg/default" ]] && sum_ok "pxe menu exists" || sum_warn "pxe menu missing"
if exists curl; then
  if curl -fsS http://127.0.0.1:8080/ >/dev/null; then sum_ok "nginx http-boot reachable on :8080"; else sum_warn "nginx http-boot not reachable"; fi
fi

section "Media Tools"
for p in lsblk pv dd xz gzip rsync sha256sum cmp find stat blockdev; do
  exists "$p" && sum_ok "$p ok" || sum_fail "$p missing"
done

section "udev bump"
NOW=$(date +%s)
/usr/local/sbin/media-bump.sh 2>/dev/null || true
sleep 1
if [[ -s /run/pi400-admin/media.bump ]]; then
  T=$(cat /run/pi400-admin/media.bump 2>/dev/null || echo 0)
  if [[ "$T" -ge "$NOW" ]]; then sum_ok "media.bump updated"; else sum_warn "media.bump old ($T < $NOW)"; fi
else
  sum_warn "media.bump file missing"
fi

section "Vault & YubiKey"
if exists pass; then sum_ok "pass present"; pass ls >/dev/null 2>&1 && sum_ok "pass usable" || sum_warn "pass store not initialized"; else sum_warn "pass missing"; fi
if exists ykman; then ykman list >/dev/null 2>&1 && sum_ok "YubiKey detected" || sum_warn "YubiKey not detected"; else sum_warn "ykman missing"; fi

section "Serial TCP & TTY"
if ss -lntp 2>/dev/null | grep -q ":5555"; then sum_ok "socat listens on 5555"; else sum_warn "no listener on 5555"; fi
[[ -e /dev/ttyGS0 ]] && sum_ok "/dev/ttyGS0 present" || sum_warn "/dev/ttyGS0 missing"

section "Kiosk/X"
if pgrep -x Xorg >/dev/null || pgrep -x X >/dev/null; then sum_ok "Xorg running"; else sum_warn "Xorg not running"; fi
[[ -x "$FRONTEND_BIN" ]] && sum_ok "frontend binary exists" || sum_fail "frontend missing"

section "Zusammenfassung"
echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  echo "Es gab Fehlermeldungen. Siehe oben."
  exit 1
else
  echo "Selbsttest abgeschlossen."
fi
