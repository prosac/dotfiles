#!/usr/bin/env python3
"""Keep workspace pinning in sync with the connected monitors.

Listens on Hyprland's event socket (.socket2.sock, same as reading-column.py)
and re-runs setup_workspaces.sh whenever the set of connected monitors changes,
so workspaces re-pin + migrate when HDMI/DP monitors come and go — without a
Hyprland reload.

Why this is *level-triggered*, not just edge-triggered
------------------------------------------------------
The old bash version reacted to each `monitoradded`/`monitorremoved` edge and
ran setup once per edge. That loses layout whenever an edge is dropped or a
transient fires: docking/undocking while carrying the laptop, and especially
starting a Google Meet screen-share, make Hyprland churn its outputs
(remove → add in quick succession). If only the `remove` edge is processed, the
layout gets stuck in the "undocked" state (everything on the laptop) even though
the big screen is physically back.

This version instead reconciles against the ACTUAL current monitor set:

  * Monitor events are coalesced with a short debounce, so a remove→add churn
    settles to a single reconcile that reflects the final state (we never flip
    through the transient "undocked" layout).
  * A periodic tick re-checks the monitor set even with no events, so a dropped
    `monitoradded` edge self-heals within PERIODIC seconds.
  * We only act (re-run setup + bounce swayosd) when the monitor SIGNATURE
    actually changed, so idle ticks and duplicate events are free.

Launched from hyprland.conf as `exec-once` (IPC/hyprctl-coupled glue lives in
exec-once, mirroring reading-column.py — not a systemd user service).
Event format on socket2 is "<event>>><payload>" — see https://wiki.hypr.land/IPC/
"""

import json
import os
import select
import socket
import subprocess
import sys
import syslog

# ── Tunables ──────────────────────────────────────────────────────────────────
DEBOUNCE = 0.6    # coalesce a burst of monitor events for this long, then settle (s)
PERIODIC = 15.0   # re-check the monitor set at least this often, edges or not (s)
# ────────────────────────────────────────────────────────────────────────────────

# Events that can change which monitors are connected.
RELEVANT = (
    "monitoradded", "monitoraddedv2",
    "monitorremoved", "monitorremovedv2",
)

SETUP = os.path.expanduser("~/.config/hypr/setup_workspaces.sh")


def log(msg):
    syslog.syslog(msg)


def monitor_signature():
    """Sorted tuple of connected monitor names — the same set setup keys off."""
    out = subprocess.run(
        ["hyprctl", "-j", "monitors"], capture_output=True, text=True, check=True
    ).stdout
    return tuple(sorted(m["name"] for m in json.loads(out)))


def run_setup():
    # setup_workspaces.sh skips its 2s startup wait when this is set (the initial
    # run is owned by the separate `exec` line in hyprland.conf).
    env = {**os.environ, "HYPRLAND_WORKSPACES_INITIALIZED": "1"}
    subprocess.run([SETUP], env=env, capture_output=True, text=True)
    # swayosd-server (GTK layer-shell) can wedge when Wayland outputs churn on
    # hot-plug: it stays alive but silently stops applying volume/brightness
    # (client still exits 0), so the media keys go dead. Bounce it so it
    # re-enumerates the current outputs.
    # See ~/Documents/docs/swayosd-media-keys-hotplug-fix.md
    subprocess.run(
        ["systemctl", "--user", "restart", "swayosd"], capture_output=True, text=True
    )


def socket_path():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not sig or not runtime:
        return None
    return os.path.join(runtime, "hypr", sig, ".socket2.sock")


def main():
    syslog.openlog("hyprland-workspace")
    path = socket_path()
    if not path or not os.path.exists(path):
        log(f"monitor-hotplug: socket not found at {path} — exiting")
        sys.exit(1)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)

    # Sync our view to reality without acting — the initial pin/migrate is done
    # by the separate `exec = setup_workspaces.sh` at session start.
    try:
        last_sig = monitor_signature()
    except Exception:
        last_sig = None
    log(f"monitor-hotplug: started (monitors: {' '.join(last_sig) if last_sig else '?'})")

    def reconcile(reason):
        nonlocal last_sig
        try:
            sig = monitor_signature()
        except Exception as exc:
            log(f"monitor-hotplug: monitor query failed: {exc}")
            return
        if sig == last_sig:
            return
        log(f"monitor-hotplug: monitors {last_sig} -> {sig} ({reason}) — rerunning setup")
        last_sig = sig
        try:
            run_setup()
        except Exception as exc:
            log(f"monitor-hotplug: setup error: {exc}")

    buf = b""
    dirty = False
    while True:
        timeout = DEBOUNCE if dirty else PERIODIC
        ready, _, _ = select.select([sock], [], [], timeout)
        if not ready:                       # timed out
            reconcile("settled" if dirty else "periodic")
            dirty = False
            continue
        data = sock.recv(65536)
        if not data:                        # Hyprland went away
            log("monitor-hotplug: event socket closed — exiting")
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            event = line.split(b">>", 1)[0].decode("utf-8", "replace")
            if event in RELEVANT:
                dirty = True


if __name__ == "__main__":
    main()
