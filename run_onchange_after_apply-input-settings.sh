#!/usr/bin/env bash
# Desktop input settings that live outside any dotfile (dconf, and the openrazer
# daemon's own state), so chezmoi can only set them by running something.
# chezmoi re-runs this whenever the file changes.

set -eu

# Old-school middle-click paste of the primary selection. Hyprland passes the
# click through (misc:middle_click_paste defaults to true), but Fedora ships
# this GTK key as false, so GTK apps and Firefox ignore it.
gsettings set org.gnome.desktop.interface gtk-enable-primary-paste true

# Razer Basilisk V3 Pro at 3200 DPI. Hyprland scales it down on the desktop
# (accel_profile "custom 1 0 0.4" in hyprland.lua, applied only while this mouse
# is attached), so the two values go together. openrazer saves the value and
# restores it on every daemon start, so setting it once is enough. Skipped if
# the daemon or mouse is not there yet (a fresh machine before relogin into
# plugdev); then run this script again by hand, or directly:
#   busctl --user call org.razer /org/razer/device/<serial> razer.device.dpi setDPI qq 3200 3200
dpi=3200
if serials=$(busctl --user call org.razer /org/razer razer.devices getDevices 2>/dev/null); then
    for serial in $(echo "$serials" | grep -o '"[^"]*"' | tr -d '"'); do
        path=/org/razer/device/$serial
        name=$(busctl --user call org.razer "$path" razer.device.misc getDeviceName 2>/dev/null || true)
        case "$name" in
            *"Basilisk V3 Pro"*)
                # The DPI button cycles the mouse's onboard stages, and the stock
                # config had one stage at 6400, so a single press jumped there.
                # A single 3200 stage makes the button a no-op.
                busctl --user call org.razer "$path" razer.device.dpi setDPIStages 'ya(qq)' 1 1 "$dpi" "$dpi"
                busctl --user call org.razer "$path" razer.device.dpi setDPI qq "$dpi" "$dpi"
                echo "  Basilisk V3 Pro ($serial): DPI set to $dpi"
                ;;
        esac
    done
else
    echo "  openrazer daemon not running; mouse DPI not set (see comment in this script)"
fi
