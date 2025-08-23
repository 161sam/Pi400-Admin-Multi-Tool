#!/usr/bin/env bash
# Create/ensure composite USB gadget: HID (managed by pi400kb), ACM serial, ECM (Linux/macOS) + RNDIS (Windows)
# Safe to run multiple times.
set -euo pipefail
G=/sys/kernel/config/usb_gadget
NAME="pi400kb"   # use same name if pi400kb already creates it
VID=${VID:-0x1d6b}
PID=${PID:-0x0104}
PRODUCT=${PRODUCT:-"Pi400 KB+Serial+Net"}
MANUF=${MANUF:-"Raspberry Pi"}
SERIAL=${SERIAL:-PI400-$(cat /proc/sys/kernel/random/uuid | cut -c1-8)}

HOST_MAC_ECM=${HOST_MAC_ECM:-02:11:22:33:44:55}
DEV_MAC_ECM=${DEV_MAC_ECM:-02:11:22:33:44:56}
HOST_MAC_RNDIS=${HOST_MAC_RNDIS:-02:aa:bb:cc:dd:ee}
DEV_MAC_RNDIS=${DEV_MAC_RNDIS:-02:aa:bb:cc:dd:ef}

modprobe libcomposite || true
mkdir -p "$G"; cd "$G"

if [ ! -d "$NAME" ]; then
  mkdir "$NAME"
fi
cd "$NAME"

# Unbind if already active
if [ -f UDC ] && [ -n "$(cat UDC)" ]; then echo "" > UDC || true; fi

echo $VID > idVendor
echo $PID > idProduct
mkdir -p strings/0x409
[ -f strings/0x409/serialnumber ] || echo "$SERIAL" > strings/0x409/serialnumber
[ -f strings/0x409/manufacturer ] || echo "$MANUF"  > strings/0x409/manufacturer
[ -f strings/0x409/product ] || echo "$PRODUCT" > strings/0x409/product
mkdir -p configs/c.1/strings/0x409
[ -f configs/c.1/strings/0x409/configuration ] || echo "Config 1: HID+ACM+NET" > configs/c.1/strings/0x409/configuration

# CDC-ACM
mkdir -p functions/acm.usb0 2>/dev/null || true
ln -sf functions/acm.usb0 configs/c.1/ 2>/dev/null || true

# ECM + RNDIS
mkdir -p functions/ecm.usb0 2>/dev/null || true
mkdir -p functions/rndis.usb0 2>/dev/null || true

echo "$DEV_MAC_ECM" > functions/ecm.usb0/dev_addr || true
echo "$HOST_MAC_ECM" > functions/ecm.usb0/host_addr || true
ln -sf functions/ecm.usb0 configs/c.1/ || true

echo "$DEV_MAC_RNDIS" > functions/rndis.usb0/dev_addr || true
echo "$HOST_MAC_RNDIS" > functions/rndis.usb0/host_addr || true
ln -sf functions/rndis.usb0 configs/c.1/ || true

# Bind to UDC
UDC=$(ls /sys/class/udc | head -n1)
echo "$UDC" > UDC

# Print resulting interfaces
ip -br link show | grep -E '^usb' || true
