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
