#!/usr/bin/env bash
# Enables all managed user services.
# Re-runs automatically when this file changes (i.e. when services are added/removed).
#
# ⚠️ EVERY `systemctl --user enable` HERE GOES THROUGH enable_unit(). Calling
# systemctl directly will break `chezmoi apply` inside the "Hyprland (DMS)"
# session, and it fails in a way that is easy to misread.
#
# That session's wrapper (~/.local/bin/hyprland-dms) runtime-masks the seven
# units DMS supersedes -- waybar, wayland-noti, swayosd, mate-polkit, nm-applet,
# elephant, hypridle -- by symlinking them to /dev/null in user.control. systemd
# refuses to enable a masked unit:
#
#     Failed to enable unit: Unit /run/user/1000/systemd/user.control/waybar.service is masked
#
# With `set -e` that aborts this script, and because it sorts FIRST among the
# run_onchange_after_ scripts it aborts the entire `chezmoi apply` -- so every
# later script silently stops running too. The symptom is a growing backlog of
# pending scripts, not an error anyone connects to the desktop session.
#
# The mask is runtime-only and this script's job is PERSISTENT enablement, so a
# masked unit that is already linked into a *.wants/ directory has nothing left
# to do and is skipped. A masked unit that is NOT linked is a real failure --
# it cannot be enabled from here at all -- so that case stays loud rather than
# leaving, say, waybar quietly unenabled for the default Hyprland session.
#
# `systemctl is-enabled` is no help for the second half of that decision: it
# answers `masked-runtime` and tells you nothing about the persistent state
# underneath. The *.wants/ symlink is the persistent state, so read that.
set -euo pipefail

systemctl --user daemon-reload

# Persistent enablement is exactly "a symlink in some ~/.config/systemd/user/
# <target>.wants/", which is where `systemctl --user enable` writes. Globbed
# across all targets rather than assuming graphical-session.target, so timers
# (WantedBy=timers.target) answer correctly too.
is_persistently_enabled() {
  compgen -G "$HOME/.config/systemd/user/"'*.wants/'"$1" >/dev/null
}

enable_unit() {
  local unit="$1" state
  state="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"

  case "$state" in
    masked | masked-runtime)
      if is_persistently_enabled "$unit"; then
        echo "  $unit: masked in this session, already enabled — skipped"
        return 0
      fi
      echo "ERROR: $unit is masked in this session and is NOT persistently enabled." >&2
      echo "       systemctl cannot enable a masked unit, so this is unfixable from" >&2
      echo "       inside the DMS session. Log into the default Hyprland session" >&2
      echo "       (or niri) and re-run:  mise run ch:apply" >&2
      return 1
      ;;
  esac

  systemctl --user enable "$unit"
}

# hypridle.service (Hyprland) and hypridle-niri.service (niri) are both enabled;
# each carries a ConditionEnvironment gate so only the one matching the live
# session ever starts. Same for the rest — they're shared across both sessions.
#
# Wallpaper is awww.service + waypaper.service, NOT hyprpaper: waypaper.service
# is ordered After=awww.service and awww.service only reports active once its
# socket answers, so `waypaper --restore` cannot race the daemon. hyprpaper is
# the superseded stack — it is a distro unit, not managed here, and enabling it
# alongside awww would leave two wallpaper daemons fighting over the output.
# See ~/Documents/docs/hyprland-wallpaper-waypaper-setup.md.
SESSION_UNITS=(
  elephant.service
  waybar.service
  awww.service
  waypaper.service
  hypridle.service
  hypridle-niri.service
  nm-applet.service
  polkit-mate-authentication-agent-1.service
  dotsnap.timer
)

for unit in "${SESSION_UNITS[@]}"; do enable_unit "$unit"; done

# Enable only when binary is present — not yet installed means skip, not fail
enable_if_exists() {
  local svc="$1" bin="$2"
  if command -v "$bin" >/dev/null 2>&1 || [[ -x "$bin" ]]; then
    enable_unit "$svc"
  else
    echo "  $svc: skipped ($bin not found)"
  fi
}

enable_if_exists kando.service kando
enable_if_exists wayland-noti.service noti

# opentabletdriver.service drives the Wacom tablet. The kernel wacom driver is
# muted for Wacom devices by /etc/udev/rules.d/99-opentabletdriver.rules
# (mise run bootstrap:opentabletdriver), so without this daemon the tablet is
# inert — enable it whenever the Flatpak is present.
if flatpak info net.opentabletdriver.OpenTabletDriver >/dev/null 2>&1; then
  enable_unit opentabletdriver.service
else
  echo "  opentabletdriver.service: skipped (Flatpak not installed)"
fi
# swayosd.service drives the brightness/volume media-key OSD (swayosd-client →
# swayosd-server). Shared across Hyprland + niri via the unit's ConditionEnvironment.
enable_if_exists swayosd.service swayosd-server
