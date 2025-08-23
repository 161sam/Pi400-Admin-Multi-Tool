#!/usr/bin/env bash
set -euo pipefail
# Imager/Clone/Backup dry-run checks
# - Validate lsblk JSON parseability and table render
# - Flash dry-run: pv -> dd of=/dev/null
# - Clone dry-run: pv of=/dev/null from src device
# - Verify: cmp -n first N bytes between image and device
# Usage examples:
#   sudo bash imager-dry-run.sh --list
#   sudo bash imager-dry-run.sh --flash /path/to/image.img.xz sdb
#   sudo bash imager-dry-run.sh --clone sdb
#   sudo bash imager-dry-run.sh --verify sdb /path/to/image.img

CMD=${1:-}
shift || true

err(){ echo "Error: $*" >&2; exit 2; }
need(){ command -v "$1" >/dev/null 2>&1 || err "$1 missing"; }
need lsblk; need pv; need dd; need xz; need gzip; need cmp; need stat; need awk

case "$CMD" in
  --list)
    lsblk -J -o NAME,KNAME,TYPE,SIZE,RM,RO,MOUNTPOINT,MODEL,TRAN | jq . || { echo "Install jq for pretty-print (apt install jq)"; }
    ;;
  --flash)
    IMG=${1:-}; DEVK=${2:-}
    [[ -n "$IMG" && -n "$DEVK" ]] || err "Usage: --flash <image> <kname>"
    if [[ "$IMG" == *.xz ]]; then
      xz -dc "$IMG" | pv -s "$(xz --robot -l "$IMG" | awk '/totals/ {print $5}')" | dd of=/dev/null bs=4M status=none
    elif [[ "$IMG" == *.gz ]]; then
      gzip -dc "$IMG" | pv | dd of=/dev/null bs=4M status=none
    else
      pv "$IMG" | dd of=/dev/null bs=4M status=none
    fi
    echo "Flash dry-run finished (to /dev/null)"
    ;;
  --clone)
    DEVK=${1:-}
    [[ -n "$DEVK" ]] || err "Usage: --clone <src_kname>"
    SRC="/dev/${DEVK}"
    [[ -e "$SRC" ]] || err "No such device: $SRC"
    pv "$SRC" | dd of=/dev/null bs=4M status=none
    echo "Clone dry-run finished (to /dev/null)"
    ;;
  --verify)
    DEVK=${1:-}; IMG=${2:-}
    [[ -n "$DEVK" && -n "$IMG" ]] || err "Usage: --verify <dst_kname> <image_path>"
    DST="/dev/${DEVK}"
    SZ=$(stat -c %s "$IMG")
    dd if="$IMG" bs=4M status=none | cmp -n "$SZ" - "$DST" && echo "verify: identical (first $SZ bytes)" || echo "verify: mismatch or error"
    ;;
  *)
    cat <<USAGE
Usage:
  $0 --list
  $0 --flash <image(.img|.xz|.gz)> <dst_kname>   # dry-run to /dev/null
  $0 --clone <src_kname>                          # dry-run to /dev/null
  $0 --verify <dst_kname> <image>
USAGE
    exit 1
    ;;
esac
