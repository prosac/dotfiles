#!/usr/bin/env bash

# Wait for monitors to be initialized
sleep 2

# Get connected monitors
MONITORS=$(hyprctl monitors -j 2>/dev/null)

# Check if HDMI-A-1 is connected
if ! echo "$MONITORS" | grep -q '"name": "HDMI-A-1"'; then
    # HDMI-A-1 is NOT connected, move all named workspaces (1-6) to eDP-1
    hyprctl keyword workspace 1,monitor:eDP-1,persistent:true
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
    # HDMI-A-1 is connected: workspaces 1-2 on eDP-1, 3-10 on HDMI-A-1
    hyprctl keyword workspace 1,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 2,monitor:eDP-1,persistent:true
    hyprctl keyword workspace 3,monitor:HDMI-A-1,default:true,persistent:true
    hyprctl keyword workspace 4,monitor:HDMI-A-1,persistent:true
    hyprctl keyword workspace 5,monitor:HDMI-A-1,persistent:true
    hyprctl keyword workspace 6,monitor:HDMI-A-1,persistent:true
    hyprctl keyword workspace 7,monitor:HDMI-A-1
    hyprctl keyword workspace 8,monitor:HDMI-A-1
    hyprctl keyword workspace 9,monitor:HDMI-A-1
    hyprctl keyword workspace 10,monitor:HDMI-A-1
    
    logger -t hyprland-workspace "HDMI-A-1 detected. Workspaces 1-2 on eDP-1, 3-10 on HDMI-A-1."
fi
