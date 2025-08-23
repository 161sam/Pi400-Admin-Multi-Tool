#!/usr/bin/env bash
set -euo pipefail
# Pi400 Admin Multi-Tool — Upgrade/Re-Install with zero-ish downtime
# Builds backend/frontend from sources and swaps binaries atomically.
# Optional: pull from git when BACKEND_SRC/FRONTEND_SRC are git repos.
# Usage: sudo bash upgrade-pi400-admin.sh [--no-git] [--skip-frontend] [--skip-backend]

NO_GIT=false; SKIP_FE=false; SKIP_BE=false
for a in "$@"; do case "$a" in
  --no-git) NO_GIT=true;;
  --skip-frontend) SKIP_FE=true;;
  --skip-backend) SKIP_BE=true;;
  *) echo "Unknown arg: $a"; exit 2;; esac; done

need_root(){ [[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }; }
need_root

BACKEND_SRC=${BACKEND_SRC:-/opt/pi400-admin/backend}
FRONTEND_SRC=${FRONTEND_SRC:-/opt/pi400-admin/frontend-iced}
BIN_DIR=/opt/admin-bin
BACKEND_BIN=${BIN_DIR}/admin-backend
FRONTEND_BIN=${BIN_DIR}/admin-panel-iced
UDS=/run/pi400-admin/backend.sock

check_src(){ local p="$1"; [[ -d "$p" && -f "$p/Cargo.toml" ]] || { echo "Missing Rust project at $p"; exit 1; }; }
$SKIP_BE || check_src "$BACKEND_SRC"
$SKIP_FE || check_src "$FRONTEND_SRC"

pull_if_git(){ $NO_GIT && return 0; local dir="$1"; if [[ -d "$dir/.git" ]]; then echo "==> git -C $dir pull"; git -C "$dir" pull --ff-only; fi }
$SKIP_BE || pull_if_git "$BACKEND_SRC"
$SKIP_FE || pull_if_git "$FRONTEND_SRC"

mkdir -p "$BIN_DIR"

build_rust(){ local dir="$1"; echo "==> cargo build --release ($dir)"; pushd "$dir" >/dev/null; CARGO_TERM_COLOR=always cargo build --release; popd >/dev/null; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

if ! $SKIP_BE; then
  build_rust "$BACKEND_SRC"
  # detect final name
  CAND=("$BACKEND_SRC/target/release/admin-backend" "$BACKEND_SRC/target/release/$(basename "$BACKEND_SRC")")
  for c in "${CAND[@]}"; do [[ -x "$c" ]] && cp -f "$c" "$TMPD/admin-backend.new" && break; done
  [[ -x "$TMPD/admin-backend.new" ]] || { echo "backend binary not built"; exit 1; }
fi

if ! $SKIP_FE; then
  build_rust "$FRONTEND_SRC"
  CAND=("$FRONTEND_SRC/target/release/admin-panel-iced" "$FRONTEND_SRC/target/release/$(basename "$FRONTEND_SRC")")
  for c in "${CAND[@]}"; do [[ -x "$c" ]] && cp -f "$c" "$TMPD/admin-panel-iced.new" && break; done
  [[ -x "$TMPD/admin-panel-iced.new" ]] || { echo "frontend binary not built"; exit 1; }
fi

# swap with minimal downtime
systemctl is-active --quiet admin-backend.service && BACKEND_ACTIVE=true || BACKEND_ACTIVE=false
systemctl is-active --quiet kiosk.service && KIOSK_ACTIVE=true || KIOSK_ACTIVE=false

if [[ -f "$TMPD/admin-backend.new" ]]; then
  echo "==> Deploy backend"
  install -m755 "$TMPD/admin-backend.new" "$BACKEND_BIN.new"
  if $BACKEND_ACTIVE; then systemctl stop admin-backend-sock.service || true; systemctl stop admin-backend.service; fi
  mv -f "$BACKEND_BIN.new" "$BACKEND_BIN"
  systemctl daemon-reload
  systemctl restart admin-backend.service
  systemctl restart admin-backend-sock.service
fi

if [[ -f "$TMPD/admin-panel-iced.new" ]]; then
  echo "==> Deploy frontend"
  install -m755 "$TMPD/admin-panel-iced.new" "$FRONTEND_BIN.new"
  $KIOSK_ACTIVE && systemctl stop kiosk.service || true
  mv -f "$FRONTEND_BIN.new" "$FRONTEND_BIN"
  systemctl daemon-reload
  $KIOSK_ACTIVE && systemctl start kiosk.service || true
fi

# health check
if [[ -S "$UDS" ]]; then
  PIN=$(cat /etc/pi400-admin/pin 2>/dev/null || echo 0000)
  if out=$(curl --silent --unix-socket "$UDS" -H "x-admin-pin: $PIN" http://unix/api/health 2>/dev/null); then
    echo "$out" | grep -q '"ok":true' && echo "==> Health: OK" || { echo "Health bad: $out"; exit 1; }
  else
    echo "Health check failed (curl/UDS)."; exit 1
  fi
else
  echo "UDS not found ($UDS). Backend sock proxy running?"; exit 1
fi

echo "Upgrade finished."
