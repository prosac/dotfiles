#!/usr/bin/env bash

# Idempotent: safe to re-run on monitor hotplug (see monitor_hotplug.sh).
# Sets persistent workspace → monitor pinning and migrates any already-existing
# workspaces to their target monitor (workspace rules alone don't move populated
# workspaces, only freshly-created ones).

# Workspace layout
#   1: Web     (chromium pinned; gmail/chat live as tabs)
#   2: Code    (emacs pinned; org-mode notes live here)
#   3: Term    (terminals — many of them, dwindle splits or grouped tabs)
#   4: Term
#   5: All The Things (the app under development; pinned by class)
#   6: Aux     (manuscript, file manager, misc one-offs)

# First invocation at session start: monitors may still be initializing.
# Subsequent invocations from the hotplug listener don't need this wait.
if [[ -z "$HYPRLAND_WORKSPACES_INITIALIZED" ]]; then
    sleep 2
    export HYPRLAND_WORKSPACES_INITIALIZED=1
fi

if hyprctl monitors -j | jq -e '.[] | select(.name == "HDMI-A-1")' >/dev/null; then
    # Docked: primary workspaces (Web, Code, the three Terms) on the big screen,
    # auxiliary workspaces on the laptop.
    declare -A WS_MONITOR=(
        [1]=HDMI-A-1 [2]=HDMI-A-1 [3]=HDMI-A-1 [4]=HDMI-A-1 [5]=HDMI-A-1
        [6]=eDP-1    [7]=eDP-1    [8]=eDP-1    [9]=eDP-1    [10]=eDP-1
    )
    LOG_MSG="HDMI-A-1 detected. ws1-5 on HDMI-A-1, ws6-10 on eDP-1."
else
    # Undocked — everything on the laptop screen.
    declare -A WS_MONITOR=(
        [1]=eDP-1 [2]=eDP-1 [3]=eDP-1 [4]=eDP-1 [5]=eDP-1
        [6]=eDP-1 [7]=eDP-1 [8]=eDP-1 [9]=eDP-1 [10]=eDP-1
    )
    LOG_MSG="HDMI-A-1 not detected. All workspaces assigned to eDP-1."
fi

# 1) Set rules. default:true on ws1, persistent:true on the always-visible six
#    so they materialize even when empty.
#
#    Under hyprland.lua `hyprctl keyword` is refused ("keyword can't work with
#    non-legacy parsers"), so rules go through `hyprctl eval`. Re-issuing
#    hl.workspace_rule for the same workspace merges into the existing rule, so
#    running this on every hotplug does not accumulate duplicates.
for ws in 1 2 3 4 5 6 7 8 9 10; do
    rule="workspace = \"$ws\", monitor = \"${WS_MONITOR[$ws]}\""
    [[ $ws -eq 1 ]] && rule="$rule, default = true"
    [[ $ws -le 6 ]] && rule="$rule, persistent = true"
    hyprctl eval "hl.workspace_rule({ $rule })" >/dev/null
done

# 2) Rename — must come AFTER persistent:true has materialized the workspaces.
#    `hyprctl dispatch` takes a Lua dispatcher expression under hyprland.lua.
rename() {  # $1=id $2=name
    hyprctl dispatch "hl.dsp.workspace.rename({ workspace = $1, name = \"$2\" })" >/dev/null
}
rename 1 "1:Web"
rename 2 "2:Code"
rename 3 "3:Term"
rename 4 "4:Term"
rename 5 "5:All The Things"
rename 6 "6:Aux"

# 3) Migrate any already-existing workspaces sitting on the wrong monitor.
#    Rules only affect newly-created workspaces — without this, hotplug leaves
#    populated workspaces stranded on the previous monitor.
for ws in 1 2 3 4 5 6 7 8 9 10; do
    target="${WS_MONITOR[$ws]}"
    current=$(hyprctl workspaces -j | jq -r --argjson id "$ws" '.[] | select(.id == $id) | .monitor')
    if [[ -n "$current" && "$current" != "$target" ]]; then
        hyprctl dispatch "hl.dsp.workspace.move({ workspace = $ws, monitor = \"$target\" })" >/dev/null
    fi
done

logger -t hyprland-workspace "$LOG_MSG"
