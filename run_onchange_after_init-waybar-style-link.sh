#!/usr/bin/env bash
# Ensure ~/.config/waybar/style.css is a symlink to either style-dark.css or
# style-light.css depending on the current gsettings color-scheme.
# Without this, waybar fails to load because style.css is missing (chezmoi only
# manages the two variants — the active symlink is owned by toggle-color-scheme).
#
# chezmoi re-runs this whenever any of these files change.
#
# style-dark.css hash:  {{ include "dot_config/waybar/style-dark.css"  | sha256sum }}
# style-light.css hash: {{ include "dot_config/waybar/style-light.css" | sha256sum }}

set -eu

WAYBAR_DIR="$HOME/.config/waybar"
cd "$WAYBAR_DIR" || exit 0

# If there's a real file named style.css (e.g. leftover from before this split),
# remove it so we can replace it with a symlink.
if [ -e style.css ] && [ ! -L style.css ]; then
    rm -f style.css
fi

current=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo dark)
case "$current" in
    *light*) target=style-light.css ;;
    *)       target=style-dark.css  ;;
esac

ln -sfn "$target" style.css
