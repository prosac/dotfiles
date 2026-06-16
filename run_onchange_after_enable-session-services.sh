#!/usr/bin/env bash
# Enables all managed user services.
# Re-runs automatically when this file changes (i.e. when services are added/removed).
set -euo pipefail

systemctl --user daemon-reload

# hypridle.service (Hyprland) and hypridle-niri.service (niri) are both enabled;
# each carries a ConditionEnvironment gate so only the one matching the live
# session ever starts. Same for the rest — they're shared across both sessions.
systemctl --user enable \
  elephant.service \
  waybar.service \
  hyprpaper.service \
  hypridle.service \
  hypridle-niri.service \
  nm-applet.service \
  polkit-mate-authentication-agent-1.service \
  dotsnap.timer

# Enable only when binary is present — not yet installed means skip, not fail
enable_if_exists() {
  local svc="$1" bin="$2"
  if command -v "$bin" >/dev/null 2>&1 || [[ -x "$bin" ]]; then
    systemctl --user enable "$svc"
  else
    echo "  $svc: skipped ($bin not found)"
  fi
}

enable_if_exists kando.service kando
enable_if_exists wayland-noti.service noti
# swayosd.service drives the brightness/volume media-key OSD (swayosd-client →
# swayosd-server). Shared across Hyprland + niri via the unit's ConditionEnvironment.
enable_if_exists swayosd.service swayosd-server
