#!/usr/bin/env bash
set -e
CONF="/etc/pi400-display.conf"
[ -f "$CONF" ] && . "$CONF"

xset -dpms; xset s off; xset s noblank
unclutter -idle 0.1 -root &
matchbox-window-manager -use_titlebar no &

# Detect output if not declared
if [ -z "${OUTPUT:-}" ]; then
  OUTPUT=$(xrandr | awk '/ connected/{print $1; exit}')
fi
ROTATION=${ROTATION:-normal}
[ -n "${OUTPUT:-}" ] && xrandr --output "$OUTPUT" --rotate "$ROTATION" || true
[ -n "${TOUCH_NAME:-}" ] && [ -n "${OUTPUT:-}" ] && xinput --map-to-output "$TOUCH_NAME" "$OUTPUT" || true

/opt/admin-panel-iced/admin-panel-iced
