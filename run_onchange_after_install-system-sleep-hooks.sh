#!/usr/bin/env bash
# Installs system-sleep hooks for generic Wayland GPU recovery on resume.
# Re-runs automatically when this file changes.
set -euo pipefail

HOOK=/usr/lib/systemd/system-sleep/wayland-gpu-wakefix
OLD_HOOK=/usr/lib/systemd/system-sleep/chromium-gpu-restart

sudo tee "$HOOK" > /dev/null << 'EOF'
#!/bin/bash
case "$1/$2" in
  post/suspend|post/hibernate|post/hybrid-sleep|post/suspend-then-hibernate)
    # Kill GPU subprocess for all Chromium-based apps (Chrome, Electron: VS Code, Discord, Slack, etc.)
    pkill -f -- "--type=gpu-process" || true
    # Kill WebKit renderer/network processes (GNOME Web, Evolution, some Flatpaks)
    pkill -f "WebKitNetworkProcess" || true
    pkill -f "WebKitWebProcess" || true
    # Force Hyprland to repaint all windows after GPU processes respawn
    sleep 1
    HYPRLAND_INSTANCE_SIGNATURE=$(ls /tmp/hypr/ 2>/dev/null | head -1) \
      hyprctl dispatch forcerendererreload 2>/dev/null || true
    ;;
esac
EOF

sudo chmod +x "$HOOK"

# Remove old chromium-specific hook if still present
[[ -f "$OLD_HOOK" ]] && sudo rm "$OLD_HOOK"

echo "==> Installed $HOOK"

# ---------------------------------------------------------------------------
# Hibernation state for hyprlock's sleep-state label.
# ---------------------------------------------------------------------------
STAMP_HOOK=/usr/lib/systemd/system-sleep/hibernate-resume-stamp

sudo tee "$STAMP_HOOK" > /dev/null << 'EOF'
#!/bin/bash
# Records hibernation state so the lock screen can mention it.
#
# $1 is pre|post. SYSTEMD_SLEEP_ACTION carries the *leg* being processed --
# "suspend", "hibernate", or "suspend-after-failed-hibernate" -- and is the only
# way to tell a suspend-then-hibernate escalation from a plain suspend, since $2
# reads "suspend-then-hibernate" for every leg. Falls back to $2 on a systemd too
# old to set it, which then lands harmlessly in the post:* clear branch.
#
# user.slice is frozen while this runs, so no IPC with hyprlock is possible --
# see systemd-sleep(8). Writing a file needs no reply, which is why this works
# where `hyprctl` cannot.
STAMP=hyprlock-sleep-state

write_state() {
  for dir in /run/user/*; do
    [ -d "$dir" ] || continue
    printf '%s %s\n' "$1" "$(date +%s)" > "$dir/$STAMP" 2>/dev/null || continue
    # Hand ownership to the session user so hibernate-now can replace it later.
    chown --reference="$dir" "$dir/$STAMP" 2>/dev/null || true
    chmod 0644 "$dir/$STAMP" 2>/dev/null || true
  done
}

clear_state() {
  for dir in /run/user/*; do
    rm -f "$dir/$STAMP" 2>/dev/null || true
  done
}

case "$1:${SYSTEMD_SLEEP_ACTION:-$2}" in
  pre:hibernate)  write_state hibernating ;;
  post:hibernate) write_state resumed ;;
  post:*)         clear_state ;;
esac
EOF

sudo chmod +x "$STAMP_HOOK"

echo "==> Installed $STAMP_HOOK"
