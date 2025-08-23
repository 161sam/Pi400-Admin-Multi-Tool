#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Pi400 Admin Multi-Tool — Full installer (Kali)
# ============================================

# Paths to sources (adjust if needed)
BACKEND_SRC="${BACKEND_SRC:-/opt/pi400-admin/backend}"
FRONTEND_SRC="${FRONTEND_SRC:-/opt/pi400-admin/frontend-iced}"

# Binaries install paths
BIN_DIR="/opt/admin-bin"
BACKEND_BIN="${BIN_DIR}/admin-backend"
FRONTEND_BIN="${BIN_DIR}/admin-panel-iced"

# Runtime / config dirs
ETC_DIR="/etc/pi400-admin"
RUN_DIR="/run/pi400-admin"
LOG_DIR="/var/log/pi400-admin"
TFTP_ROOT="/srv/tftpboot"
NFS_IMAGES="/srv/nfs/images"

PIN_FILE="${ETC_DIR}/pin"
CONSENT_FILE="${ETC_DIR}/consent.token"

# ------- sanity checks -------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)"; exit 1
fi

if [[ ! -d "$BACKEND_SRC" ]] || [[ ! -f "$BACKEND_SRC/Cargo.toml" ]]; then
  echo "Missing backend sources at ${BACKEND_SRC}. Put your Rust backend (main.rs v8.1 + patches) there."; exit 1
fi
if [[ ! -d "$FRONTEND_SRC" ]] || [[ ! -f "$FRONTEND_SRC/Cargo.toml" ]]; then
  echo "Missing frontend sources at ${FRONTEND_SRC}. Put your Iced GUI sources (v8.1) there."; exit 1
fi

echo "==> Updating APT & installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  xserver-xorg xinit x11-xserver-utils xinput xrandr \
  matchbox-window-manager unclutter \
  autossh socat nftables \
  python3 python3-venv \
  pass gnupg rng-tools yubikey-manager \
  git build-essential pkg-config libssl-dev \
  curl ca-certificates \
  dnsmasq nfs-kernel-server pxelinux syslinux-common \
  pv xz-utils gzip parted dosfstools rsync nginx bsdtar \
  rustc cargo

echo "==> Creating dirs"
mkdir -p "$BIN_DIR" "$ETC_DIR" "$RUN_DIR" "$LOG_DIR"
mkdir -p "$TFTP_ROOT/pxelinux.cfg" "$NFS_IMAGES"

# -------- PIN & Consent token ----------
if [[ ! -f "$PIN_FILE" ]]; then
  echo "0000" > "$PIN_FILE"
  chmod 600 "$PIN_FILE"
fi
if [[ ! -f "$CONSENT_FILE" ]]; then
  head -c 16 /dev/urandom | base64 > "$CONSENT_FILE"
  chmod 600 "$CONSENT_FILE"
fi

# -------- Build Rust projects ----------
echo "==> Building backend (release)"
pushd "$BACKEND_SRC" >/dev/null
cargo build --release
install -m755 "target/release/$(basename "$BACKEND_SRC")" "$BACKEND_BIN" || install -m755 "target/release/admin-backend" "$BACKEND_BIN"
popd >/dev/null

echo "==> Building frontend (release)"
pushd "$FRONTEND_SRC" >/dev/null
cargo build --release
install -m755 "target/release/$(basename "$FRONTEND_SRC")" "$FRONTEND_BIN" || install -m755 "target/release/admin-panel-iced" "$FRONTEND_BIN"
popd >/dev/null

# --------- Scripts (Gadget, NAT, HID, udev bump) ---------
echo "==> Installing helper scripts"
install -m755 /dev/stdin /usr/local/sbin/pi400-composite.sh <<'EOF'
#!/bin/bash
set -euo pipefail
# Composite USB Gadget: HID (keyboard), ACM serial, ECM ethernet
# Requires: modprobe libcomposite; configfs mounted at /sys/kernel/config
G=/sys/kernel/config/usb_gadget/pi400
if [[ -d $G ]]; then echo "Gadget exists"; exit 0; fi

modprobe libcomposite

mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0100 > $G/bcdDevice
echo 0x0200 > $G/bcdUSB

mkdir -p $G/strings/0x409
echo "Pi400 Admin Gadget" > $G/strings/0x409/product
echo "Pi400" > $G/strings/0x409/manufacturer
echo "4000001" > $G/strings/0x409/serialnumber

mkdir -p $G/configs/c.1
mkdir -p $G/configs/c.1/strings/0x409
echo "config 1" > $G/configs/c.1/strings/0x409/configuration

# HID keyboard
mkdir -p $G/functions/hid.usb0
echo 1 > $G/functions/hid.usb0/protocol
echo 1 > $G/functions/hid.usb0/subclass
echo 8 > $G/functions/hid.usb0/report_length
# Simple boot keyboard report descriptor
echo -ne \\x05\\x01\\x09\\x06\\xa1\\x01\\x05\\x07\\x19\\xe0\\x29\\xe7\\x15\\x00\\x25\\x01\\x75\\x01\\x95\\x08\\x81\\x02\\x95\\x01\\x75\\x08\\x81\\x01\\x95\\x05\\x75\\x01\\x05\\x08\\x19\\x01\\x29\\x05\\x91\\x02\\x95\\x01\\x75\\x03\\x91\\x01\\x95\\x06\\x75\\x08\\x15\\x00\\x25\\x65\\x05\\x07\\x19\\x00\\x29\\x65\\x81\\x00\\xc0 > $G/functions/hid.usb0/report_desc

# ACM serial
mkdir -p $G/functions/acm.usb0

# ECM ethernet
mkdir -p $G/functions/ecm.usb0
HOST="02:1a:11:00:00:00"; DEV="02:1a:11:00:00:01"
echo $HOST > $G/functions/ecm.usb0/dev_addr
echo $DEV  > $G/functions/ecm.usb0/host_addr

ln -s $G/functions/hid.usb0 $G/configs/c.1/
ln -s $G/functions/acm.usb0 $G/configs/c.1/
ln -s $G/functions/ecm.usb0 $G/configs/c.1/

UDC=$(ls /sys/class/udc | head -n1)
echo $UDC > $G/UDC || { echo "No UDC found"; exit 1; }

# Bring up usb0 with static IP (for RNDIS/ECM)
ip link set dev usb0 up || true
ip addr add 10.66.0.1/30 dev usb0 || true
EOF

install -m755 /dev/stdin /usr/local/sbin/nat-toggle.sh <<'EOF'
#!/bin/bash
# Usage: nat-toggle.sh on|off [uplink]
set -euo pipefail
ACTION="${1:-on}"
UPLINK="${2:-eth0}"
USBIF="usb0"
SYSCTL=/proc/sys/net/ipv4/ip_forward

if [[ "$ACTION" == "on" ]]; then
  echo 1 > "$SYSCTL"
  nft -f - <<RULES
table inet natpi {
  chain postrouting { type nat hook postrouting priority 100; policy accept;
    oifname "$UPLINK" ip saddr 10.66.0.0/30 masquerade
  }
}
RULES
  echo "NAT enabled via $UPLINK"
else
  echo 0 > "$SYSCTL" || true
  nft delete table inet natpi || true
  echo "NAT disabled"
fi
EOF

install -m755 /dev/stdin /usr/local/sbin/target-ip <<'EOF'
#!/bin/sh
# naive: try arp/neigh on usb0
ip -4 neigh show dev usb0 | awk '{print $1}' | head -n1
EOF

install -m755 /dev/stdin /usr/local/sbin/hid-type.py <<'EOF'
#!/usr/bin/env python3
import sys,time,argparse,os
# Very small typer: writes HID reports to /dev/hidg0 using Linux input keycodes mapping (simplified)
# This is a placeholder; your full mapping from the project should live here.
parser=argparse.ArgumentParser()
parser.add_argument("--text",required=True)
parser.add_argument("--wpm",type=int,default=300)
parser.add_argument("--enter",action="store_true")
parser.add_argument("--layout",choices=["us","de"],default="us")
a=parser.parse_args()
delay = max(0.001, 12.0/(a.wpm*5))  # approx
path="/dev/hidg0"
def press(ch):
    # extremely simplified: only letters/numbers and space/enter — replace with your proper map
    code = 0
    if ch=="\n": code=0x28
    elif ch==" ": code=0x2c
    elif "a"<=ch<="z": code=0x04+ord(ch)-ord("a")
    elif "A"<=ch<="Z": os.write(fd,bytes([2,0,0x00,0,0,0,0,0])); code=0x04+ord(ch.lower())-ord("a")
    elif "0"<=ch<="9": code = [0x27,0x1e,0x1f,0x20,0x21,0x22,0x23,0x24,0x25,0x26][ord(ch)-ord("0")]
    else: return
    os.write(fd,bytes([0,0,code,0,0,0,0,0])); os.write(fd,bytes([0,0,0,0,0,0,0,0]))
with open(path,"wb", buffering=0) as fd:
    for ch in a.text:
        press(ch); time.sleep(delay)
    if a.enter: press("\n")
print("typed")
EOF

install -m755 /dev/stdin /usr/local/sbin/media-bump.sh <<'EOF'
#!/bin/sh
mkdir -p /run/pi400-admin
date +%s > /run/pi400-admin/media.bump
exit 0
EOF

# --------- udev for media bump ----------
echo 'ACTION=="add|remove", SUBSYSTEM=="block", RUN+="/usr/local/sbin/media-bump.sh"' \
  > /etc/udev/rules.d/99-pi400-media.rules
udevadm control --reload || true

# ---------- nginx HTTP-Boot site ----------
install -m644 /dev/stdin /etc/nginx/sites-available/pxe.conf <<'EOF'
server {
    listen 8080 default_server;
    server_name _;
    access_log /var/log/nginx/pxe_access.log;
    error_log  /var/log/nginx/pxe_error.log;
    root /srv/tftpboot;
    autoindex on;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
ln -sf /etc/nginx/sites-available/pxe.conf /etc/nginx/sites-enabled/pxe.conf
systemctl restart nginx

# ---------- PXE basics (dnsmasq, nfs) ----------
install -m644 /dev/stdin /etc/dnsmasq.d/pxe.conf <<'EOF'
# Limit to usb0 to avoid LAN DHCP conflicts!
interface=usb0
bind-interfaces
dhcp-range=10.66.0.2,10.66.0.3,12h
enable-tftp
tftp-root=/srv/tftpboot
pxe-service=x86PC, "Network Boot", pxelinux
# Boot files
dhcp-boot=pxelinux.0
EOF

# pxelinux core files
cp -f /usr/lib/PXELINUX/pxelinux.0 "${TFTP_ROOT}/" || true
cp -f /usr/lib/syslinux/modules/bios/ldlinux.c32 "${TFTP_ROOT}/" || true
cp -f /usr/lib/syslinux/modules/bios/libutil.c32 "${TFTP_ROOT}/" || true
cp -f /usr/lib/syslinux/modules/bios/menu.c32 "${TFTP_ROOT}/" || true
[[ -f "${TFTP_ROOT}/pxelinux.cfg/default" ]] || cat > "${TFTP_ROOT}/pxelinux.cfg/default" <<'EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50

MENU TITLE Pi400 PXE Menu
LABEL local
  MENU LABEL Boot from local disk
  LOCALBOOT 0
EOF

# NFS export
if ! grep -q "^${NFS_IMAGES} " /etc/exports 2>/dev/null; then
  echo "${NFS_IMAGES} 10.66.0.0/30(rw,sync,no_subtree_check)" >> /etc/exports
fi
exportfs -a

# ---------- systemd units ----------
install -m644 /dev/stdin /etc/systemd/system/admin-backend.service <<EOF
[Unit]
Description=Pi400 Admin Backend (Axum)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${BACKEND_BIN}
Restart=on-failure
Environment=RUST_LOG=info
RuntimeDirectory=pi400-admin
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# UDS forwarder for frontend (frontend talks to /run/pi400-admin/backend.sock)
install -m644 /dev/stdin /etc/systemd/system/admin-backend-sock.service <<'EOF'
[Unit]
Description=UDS proxy to admin-backend (TCP 127.0.0.1:5000)
After=admin-backend.service

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/pi400-admin
ExecStart=/usr/bin/socat UNIX-LISTEN:/run/pi400-admin/backend.sock,fork,mode=660,unlink-early TCP:127.0.0.1:5000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

install -m644 /dev/stdin /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Pi400 Kiosk (Iced Admin Panel)
After=systemd-user-sessions.service admin-backend.service admin-backend-sock.service
Wants=admin-backend.service admin-backend-sock.service

[Service]
Environment=DISPLAY=:0
ExecStart=/bin/bash -lc 'xinit ${FRONTEND_BIN} -- :0 -s 0 -dpms'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Gadget ensure at boot (optional one-shot)
install -m644 /dev/stdin /etc/systemd/system/pi400-gadget-ensure.service <<'EOF'
[Unit]
Description=Ensure composite USB gadget (HID+ACM+ECM)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pi400-composite.sh

[Install]
WantedBy=multi-user.target
EOF

# Serial TCP bridge (5555 -> /dev/ttyGS0)
install -m644 /dev/stdin /etc/systemd/system/target-serial-tcp.service <<'EOF'
[Unit]
Description=TCP→/dev/ttyGS0 serial bridge (port 5555)
After=pi400-gadget-ensure.service
Wants=pi400-gadget-ensure.service

[Service]
ExecStart=/usr/bin/socat -d -d tcp-listen:5555,reuseaddr,fork file:/dev/ttyGS0,raw,echo=0,crnl
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# PXE target (dnsmasq + nfs)
install -m644 /dev/stdin /etc/systemd/system/pxe-server.target <<'EOF'
[Unit]
Description=PXE Server (dnsmasq + nfs-kernel-server)
Requires=dnsmasq.service nfs-kernel-server.service
After=network-online.target
Wants=network-online.target

[Install]
WantedBy=multi-user.target
EOF

# HTTP Boot target (nginx)
install -m644 /dev/stdin /etc/systemd/system/pxe-http.target <<'EOF'
[Unit]
Description=PXE HTTP Boot stack (nginx)
Requires=nginx.service
After=network-online.target
Wants=network-online.target

[Install]
WantedBy=multi-user.target
EOF

# -------- enable & start essentials ----------
echo "==> Enabling services"
systemctl daemon-reload
systemctl enable --now admin-backend.service
systemctl enable --now admin-backend-sock.service
systemctl enable --now kiosk.service
systemctl enable --now pi400-gadget-ensure.service
systemctl enable --now target-serial-tcp.service

# PXE stacks remain opt-in; you can start them from the GUI or here:
# systemctl enable --now pxe-server.target
# systemctl enable --now pxe-http.target

# -------- done ----------
echo "==========================================="
echo "Install complete."
echo "Admin PIN: $(cat "$PIN_FILE")"
echo "Consent token: $(cat "$CONSENT_FILE")"
echo
echo "PXE TFTP root: ${TFTP_ROOT}"
echo "NFS images:    ${NFS_IMAGES}"
echo "GUI should be running in kiosk on :0"
echo "==========================================="
