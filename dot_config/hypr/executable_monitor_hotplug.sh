#!/usr/bin/env bash

# Listens on Hyprland's event socket (.socket2.sock) for monitor add/remove
# events and re-runs setup_workspaces.sh so pinning + migration stay correct
# across hot-plugs.
#
# Event format on socket2 is "<event>>><payload>" — see
# https://wiki.hypr.land/IPC/

SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

if [[ ! -S "$SOCKET" ]]; then
    logger -t hyprland-workspace "monitor_hotplug: socket not found at $SOCKET — exiting"
    exit 1
fi

# Subsequent setup invocations don't need the startup sleep.
export HYPRLAND_WORKSPACES_INITIALIZED=1

ncat -U "$SOCKET" | while IFS= read -r line; do
    case "$line" in
        monitoradded\>\>*|monitorremoved\>\>*|monitoraddedv2\>\>*|monitorremovedv2\>\>*)
            logger -t hyprland-workspace "Hotplug event: $line — rerunning setup_workspaces.sh"
            # Brief debounce: Hyprland may emit add + a resolution event in
            # quick succession; let dust settle so monitors -j reflects reality.
            sleep 0.3
            ~/.config/hypr/setup_workspaces.sh
            ;;
    esac
done
