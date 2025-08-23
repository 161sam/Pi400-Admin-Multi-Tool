#!/usr/bin/env bash
set -e

# Optional display config
CONF="/etc/pi400-display.conf"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
fi

# Turn off power management/screen blanking
xset -dpms
xset s off
xset s noblank

# Hide cursor after inactivity
unclutter -idle 0.1 -root &

# Minimal window manager for proper stacking
matchbox-window-manager -use_titlebar no &

# Detect output if not provided (HDMI preferred)
if [ -z "${OUTPUT:-}" ]; then
  OUTPUT=$(xrandr | awk '/ connected/{print $1; exit}')
fi
ROTATION=${ROTATION:-normal} # normal|left|right|inverted

# Apply rotation if possible
if [ -n "${OUTPUT:-}" ]; then
  xrandr --output "$OUTPUT" --rotate "$ROTATION" || true
fi

# Map touch device to output if provided
if [ -n "${TOUCH_NAME:-}" ] && [ -n "${OUTPUT:-}" ]; then
  xinput --map-to-output "$TOUCH_NAME" "$OUTPUT" || true
fi

# Launch Iced GUI fullscreen
/opt/admin-panel-iced/admin-panel-iced
