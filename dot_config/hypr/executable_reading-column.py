#!/usr/bin/env python3
"""Auto reading-column gaps for single-window workspaces.

Listens on Hyprland's event socket (.socket2.sock, same as monitor_hotplug.sh)
and, whenever the window layout changes, reconciles per-workspace `gaps_out`:

  * A workspace holding exactly ONE tiled window is centered into a reading
    column: the side margins are computed so the window is TARGET_WIDTH logical
    pixels wide, with a small VGAP top/bottom. On the 3440px ultrawide this
    leaves ~1095px of wallpaper each side; on the 1440px laptop the same target
    naturally yields much smaller (~95px) margins.
  * Any other count (0 or 2+ tiled windows) resets that workspace to the
    config default gaps, so normal tiling is untouched.

Margins are computed from the focused monitor's logical width, so a single
fixed rule (Hyprland's native `w[tv1]` smart-gaps) is deliberately NOT used —
it would leave a negative width on the narrow laptop. Live per-workspace gaps
are read back from `hyprctl workspacerules`, so state survives a daemon restart
and we only call hyprctl when something actually needs to change.

Launched from hyprland.conf as `exec-once` (IPC/hyprctl-coupled glue lives in
exec-once, mirroring monitor_hotplug.sh — not a systemd user service).
Event format on socket2 is "<event>>><payload>" — see https://wiki.hypr.land/IPC/
"""

import json
import os
import select
import socket
import subprocess
import sys
import syslog
from collections import defaultdict

# ── Tunables ────────────────────────────────────────────────────────────────
TARGET_WIDTH = 1250   # desired reading-column width, logical px (same on every monitor)
VGAP = 24             # small top/bottom margin, logical px
EDGE_MARGIN = 8       # never let a computed side margin fall below this
DEBOUNCE = 0.08       # coalesce bursts of events for this long (seconds)
# ─────────────────────────────────────────────────────────────────────────────

# Events that can change the tiled-window count of a workspace or monitor geometry.
RELEVANT = (
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "changefloatingmode", "fullscreen",
    "monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2",
)


def log(msg):
    syslog.syslog(msg)


def hyprctl_json(*args):
    out = subprocess.run(
        ["hyprctl", "-j", *args], capture_output=True, text=True, check=True
    ).stdout
    return json.loads(out)


def default_gaps():
    """Read the config default gaps_out (e.g. "8 8 8 8" or "8") as a 4-list."""
    try:
        custom = hyprctl_json("getoption", "general:gaps_out")["custom"]
        vals = [int(v) for v in custom.split()]
    except Exception:
        vals = [8]
    if len(vals) == 1:
        vals *= 4
    return (vals + vals[-1:] * 4)[:4]


DEFAULT_GAPS = default_gaps()


def side_margin(logical_width):
    """Side margin that leaves a ~TARGET_WIDTH-wide window, clamped for small screens."""
    effective = min(TARGET_WIDTH, logical_width - 2 * EDGE_MARGIN)
    return max(EDGE_MARGIN, round((logical_width - effective) / 2))


def apply(wsid, gaps):
    t, r, b, l = gaps
    subprocess.run(
        ["hyprctl", "keyword", "workspace", f"{wsid}, gapsout:{t} {r} {b} {l}"],
        capture_output=True, text=True,
    )


def reconcile():
    clients = hyprctl_json("clients")
    monitors = hyprctl_json("monitors")
    rules = hyprctl_json("workspacerules")

    logical = {m["id"]: m["width"] / m["scale"] for m in monitors}

    tiled = defaultdict(int)
    mon_of_ws = {}
    for c in clients:
        ws = c["workspace"]["id"]
        if ws <= 0 or not c.get("mapped", True):  # skip special/scratchpad + unmapped
            continue
        mon_of_ws.setdefault(ws, c["monitor"])
        if not c["floating"]:
            tiled[ws] += 1

    # Current per-workspace gaps we've set previously (read live state).
    current = {}
    for r in rules:
        try:
            wsid = int(r.get("workspaceString"))
        except (TypeError, ValueError):
            continue
        if wsid > 0 and r.get("gapsOut"):
            current[wsid] = list(r["gapsOut"])

    # Candidates: workspaces that have windows, plus any we previously touched.
    candidates = set(mon_of_ws) | set(current)
    for wsid in candidates:
        if tiled.get(wsid, 0) == 1 and mon_of_ws.get(wsid) in logical:
            side = side_margin(logical[mon_of_ws[wsid]])
            desired = [VGAP, side, VGAP, side]
        else:
            desired = list(DEFAULT_GAPS)
        if current.get(wsid, list(DEFAULT_GAPS)) != desired:
            apply(wsid, desired)
            log(f"ws {wsid}: gapsout -> {desired}")


def socket_path():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not sig or not runtime:
        return None
    return os.path.join(runtime, "hypr", sig, ".socket2.sock")


def main():
    syslog.openlog("hyprland-reading-column")
    path = socket_path()
    if not path or not os.path.exists(path):
        log(f"socket not found at {path} — exiting")
        sys.exit(1)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    log("started")

    reconcile()  # get the current layout right immediately

    buf = b""
    dirty = False
    while True:
        timeout = DEBOUNCE if dirty else None
        ready, _, _ = select.select([sock], [], [], timeout)
        if not ready:                 # debounce window elapsed
            if dirty:
                try:
                    reconcile()
                except Exception as exc:  # never let one bad event kill the daemon
                    log(f"reconcile error: {exc}")
                dirty = False
            continue
        data = sock.recv(65536)
        if not data:                  # Hyprland went away
            log("event socket closed — exiting")
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            event = line.split(b">>", 1)[0].decode("utf-8", "replace")
            if event in RELEVANT:
                dirty = True


if __name__ == "__main__":
    main()
