#!/usr/bin/env bash

# Wait for monitors to be initialized
sleep 2

# Workspace layout
#   1: Web     (chromium pinned; gmail/chat live as tabs)
#   2: Code    (emacs pinned; org-mode notes live here)
#   3: Term    (terminals — many of them, dwindle splits or grouped tabs)
#   4: Term
#   5: Term
#   6: Aux     (manuscript, file manager, misc one-offs)

# Get connected monitors
MONITORS=$(hyprctl monitors -j 2>/dev/null)

if ! echo "$MONITORS" | grep -q '"name": "HDMI-A-1"'; then
    # HDMI-A-1 not connected — everything on the laptop screen.
    hyprctl keyword workspace 1,monitor:eDP-1,default:true,persistent:true
    hyprctl keyword workspace 2,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 3,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 4,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 5,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 6,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 7,monitor:eDP-1
    hyprctl keyword workspace 8,monitor:eDP-1
    hyprctl keyword workspace 9,monitor:eDP-1
    hyprctl keyword workspace 10,monitor:eDP-1

    logger -t hyprland-workspace "HDMI-A-1 not detected. All workspaces assigned to eDP-1."
else
    # Docked: heavy-use workspaces (Web, Code) on the big screen,
    # secondary (Term, Aux) on the laptop.
    hyprctl keyword workspace 1,monitor:HDMI-A-1,default:true,persistent:true
    hyprctl keyword workspace 2,monitor:HDMI-A-1,persistent:true
    hyprctl keyword workspace 3,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 4,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 5,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 6,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 7,monitor:HDMI-A-1
    hyprctl keyword workspace 8,monitor:HDMI-A-1
    hyprctl keyword workspace 9,monitor:HDMI-A-1
    hyprctl keyword workspace 10,monitor:HDMI-A-1

    logger -t hyprland-workspace "HDMI-A-1 detected. ws1-2 on HDMI-A-1, ws3-6 on eDP-1."
fi

# Rename AFTER persistent rules — renameworkspace only works on existing workspaces,
# so it has to come after the persistent:true keyword has materialized them.
hyprctl dispatch renameworkspace 1 "1:Web"
hyprctl dispatch renameworkspace 2 "2:Code"
hyprctl dispatch renameworkspace 3 "3:Term"
hyprctl dispatch renameworkspace 4 "4:Term"
hyprctl dispatch renameworkspace 5 "5:Term"
hyprctl dispatch renameworkspace 6 "6:Aux"
