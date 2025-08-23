#!/usr/bin/env bash
set -euo pipefail
# Pi400 Admin Multi-Tool — Uninstall / Reset script
# Usage:
#   sudo bash uninstall-pi400-admin.sh [--purge-config] [--purge-data]
#
# --purge-config : entfernt /etc/pi400-admin, udev-Regel, dnsmasq/nginx-Snippets
# --purge-data   : entfernt /srv/tftpboot und /srv/nfs/images (PXE/NFS-Daten)
#
# Das Skript stoppt & disabled systemd-Units, löscht Binärdateien und Hilfsskripte.

PURGE_CFG=false
PURGE_DATA=false
for a in "$@"; do
  case "$a" in
    --purge-config) PURGE_CFG=true ;;
    --purge-data)   PURGE_DATA=true ;;
    *) echo "Unknown arg: $a"; exit 2 ;;
  esac
done

need_root(){ if [[ $EUID -ne 0 ]]; then echo "Please run as root"; exit 1; fi }
need_root

# ---- constants ----
BIN_DIR="/opt/admin-bin"
ETC_DIR="/etc/pi400-admin"
RUN_DIR="/run/pi400-admin"
LOG_DIR="/var/log/pi400-admin"
TFTP_ROOT="/srv/tftpboot"
NFS_IMAGES="/srv/nfs/images"

UNIT_FILES=(
  /etc/systemd/system/admin-backend.service
  /etc/systemd/system/admin-backend-sock.service
  /etc/systemd/system/kiosk.service
  /etc/systemd/system/pi400-gadget-ensure.service
  /etc/systemd/system/target-serial-tcp.service
  /etc/systemd/system/pxe-server.target
  /etc/systemd/system/pxe-http.target
)

SERVICES=(
  admin-backend.service
  admin-backend-sock.service
  kiosk.service
  pi400-gadget-ensure.service
  target-serial-tcp.service
  dnsmasq.service
  nfs-kernel-server.service
  nginx.service
  pxe-server.target
  pxe-http.target
)

SCRIPTS=(
  /usr/local/sbin/pi400-composite.sh
  /usr/local/sbin/nat-toggle.sh
  /usr/local/sbin/target-ip
  /usr/local/sbin/hid-type.py
  /usr/local/sbin/media-bump.sh
)

echo "==> Stopping services"
for s in "${SERVICES[@]}"; do systemctl stop "$s" 2>/dev/null || true; done
for s in "${SERVICES[@]}"; do systemctl disable "$s" 2>/dev/null || true; done

echo "==> Removing systemd unit files"
for u in "${UNIT_FILES[@]}"; do rm -f "$u"; done
systemctl daemon-reload

# nginx site
if [[ -f /etc/nginx/sites-enabled/pxe.conf ]]; then rm -f /etc/nginx/sites-enabled/pxe.conf; fi
if [[ "$PURGE_CFG" == true ]]; then rm -f /etc/nginx/sites-available/pxe.conf; fi
systemctl restart nginx 2>/dev/null || true

# dnsmasq snippet
if [[ "$PURGE_CFG" == true ]]; then rm -f /etc/dnsmasq.d/pxe.conf; fi
systemctl restart dnsmasq 2>/dev/null || true

# udev rule
if [[ "$PURGE_CFG" == true ]]; then rm -f /etc/udev/rules.d/99-pi400-media.rules; udevadm control --reload 2>/dev/null || true; fi

# helper scripts
echo "==> Removing helper scripts"
for p in "${SCRIPTS[@]}"; do rm -f "$p"; done

# binaries
echo "==> Removing binaries in ${BIN_DIR}"
rm -f "${BIN_DIR}/admin-backend" "${BIN_DIR}/admin-panel-iced" 2>/dev/null || true
rmdir "${BIN_DIR}" 2>/dev/null || true

# config/runtime/logs
if [[ "$PURGE_CFG" == true ]]; then
  echo "==> Purging ${ETC_DIR}"
  rm -rf "$ETC_DIR"
fi
rm -rf "$RUN_DIR" 2>/dev/null || true
rm -rf "$LOG_DIR" 2>/dev/null || true

# PXE/NFS data
if [[ "$PURGE_DATA" == true ]]; then
  echo "==> Purging PXE/NFS trees"
  rm -rf "$TFTP_ROOT" "$NFS_IMAGES"
fi

# Final
echo "Uninstall complete. (Config purged: ${PURGE_CFG}, Data purged: ${PURGE_DATA})"
