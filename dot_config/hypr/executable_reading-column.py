#!/usr/bin/env python3
"""Reading-column gaps for single-window workspaces.

Listens on Hyprland's event socket (.socket2.sock, same as monitor-hotplug.py)
and, whenever the window layout changes, reconciles per-workspace `gaps_out`:

  * AUTO (wide monitors only): a workspace holding exactly ONE tiled window on a
    monitor at least AUTO_MIN_WIDTH logical px wide is centered into an
    AUTO_WIDTH column, so a lone window doesn't sprawl across the whole
    ultrawide. Narrow screens (the 1440px laptop) are deliberately excluded —
    there a single window just gets the normal small default gaps.
  * MANUAL reading mode (Super+C -> `reading-column.py toggle`): flips a
    per-workspace override that forces a narrow READING_WIDTH column on ANY
    monitor, laptop included, for focused reading. The override is persisted in
    $XDG_RUNTIME_DIR and clears itself once the workspace is emptied.
  * Everything else (0 or 2+ tiled windows, or narrow monitor with no override)
    resets that workspace to the config default gaps, so normal tiling is
    untouched.

Margins are computed from the focused monitor's logical width, so a single
fixed rule (Hyprland's native `w[tv1]` smart-gaps) is deliberately NOT used —
it would leave a negative width on the narrow laptop. Live per-workspace gaps
are read back from `hyprctl workspacerules`, so state survives a daemon restart
and we only call hyprctl when something actually needs to change.

⚠️ Since Hyprland 0.56 these gaps are subtracted from the work area handed to the
layout (src/layout/space/Space.cpp), not applied per-window afterwards. So a
column makes dwindle see a NARROW, TALL screen and stack the next window
top/bottom instead of splitting left/right — `dwindle:split_width_multiplier`
(0.85 in hyprland.conf) is what keeps the AUTO column side-by-side, and it only
holds while AUTO_WIDTH stays close to the monitor height. Changing AUTO_WIDTH or
READING_WIDTH means re-checking that ratio. See §8 of
~/Documents/docs/hyprland-copr-migration.md.

Launched from hyprland.conf as `exec-once` (IPC/hyprctl-coupled glue lives in
exec-once, mirroring monitor-hotplug.py — not a systemd user service).
Event format on socket2 is "<event>>><payload>" — see https://wiki.hypr.land/IPC/
"""

import json
import os
import select
import socket
import subprocess
import sys
import syslog
import tempfile
from collections import defaultdict

# ── Tunables ────────────────────────────────────────────────────────────────
AUTO_WIDTH = 1250      # auto single-window column width on wide monitors, logical px
READING_WIDTH = 800    # manual reading column width (Super+C toggle), logical px
AUTO_MIN_WIDTH = 2000  # only auto-center when the monitor is at least this wide;
                       # the 1440px laptop opts out and keeps small default gaps.
VGAP = 24              # small top/bottom margin for any column, logical px
EDGE_MARGIN = 8        # never let a computed side margin fall below this
DEBOUNCE = 0.08        # coalesce bursts of events for this long (seconds)
# ─────────────────────────────────────────────────────────────────────────────

# Reading-mode override state, shared between the daemon and the `toggle`
# one-shot. A JSON list of workspace ids currently pinned to the reading column.
STATE_FILE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "hypr-reading-column.json"
)

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


def load_overrides():
    """Workspace ids currently in manual reading mode (empty set on any error)."""
    try:
        with open(STATE_FILE) as f:
            return {int(x) for x in json.load(f)}
    except Exception:
        return set()


def save_overrides(overrides):
    """Atomically persist the reading-mode override set (write temp + rename)."""
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(STATE_FILE), prefix=".rc-")
        with os.fdopen(fd, "w") as f:
            json.dump(sorted(overrides), f)
        os.replace(tmp, STATE_FILE)
    except Exception as exc:
        log(f"save_overrides error: {exc}")
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def column_gaps(logical_width, target):
    """Gaps that center a ~target-wide column, clamped for small screens."""
    effective = min(target, logical_width - 2 * EDGE_MARGIN)
    side = max(EDGE_MARGIN, round((logical_width - effective) / 2))
    return [VGAP, side, VGAP, side]


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
    overrides = load_overrides()

    logical = {m["id"]: m["width"] / m["scale"] for m in monitors}

    tiled = defaultdict(int)
    total = defaultdict(int)
    mon_of_ws = {}
    for c in clients:
        ws = c["workspace"]["id"]
        if ws <= 0 or not c.get("mapped", True):  # skip special/scratchpad + unmapped
            continue
        total[ws] += 1
        mon_of_ws.setdefault(ws, c["monitor"])
        if not c["floating"]:
            tiled[ws] += 1

    # Reading mode is "for this window": drop the flag once its workspace empties.
    stale = {ws for ws in overrides if total.get(ws, 0) == 0}
    if stale:
        overrides -= stale
        save_overrides(overrides)

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
    candidates = set(mon_of_ws) | set(current) | overrides
    for wsid in candidates:
        width = logical.get(mon_of_ws.get(wsid))
        single = tiled.get(wsid, 0) == 1 and width is not None
        if single and wsid in overrides:
            desired = column_gaps(width, READING_WIDTH)      # manual reading column, any monitor
        elif single and width >= AUTO_MIN_WIDTH:
            desired = column_gaps(width, AUTO_WIDTH)          # auto column, wide monitors only
        else:
            desired = list(DEFAULT_GAPS)                      # normal tiling
        if current.get(wsid, list(DEFAULT_GAPS)) != desired:
            apply(wsid, desired)
            log(f"ws {wsid}: gapsout -> {desired}")


def toggle():
    """Flip manual reading mode for the focused workspace, then apply at once."""
    try:
        wsid = int(hyprctl_json("activeworkspace")["id"])
    except Exception as exc:
        log(f"toggle: cannot read active workspace: {exc}")
        return
    if wsid <= 0:
        return
    overrides = load_overrides()
    if wsid in overrides:
        overrides.discard(wsid)
        log(f"reading mode OFF for ws {wsid}")
    else:
        overrides.add(wsid)
        log(f"reading mode ON for ws {wsid}")
    save_overrides(overrides)
    reconcile()


def socket_path():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not sig or not runtime:
        return None
    return os.path.join(runtime, "hypr", sig, ".socket2.sock")


def main():
    syslog.openlog("hyprland-reading-column")

    if len(sys.argv) > 1 and sys.argv[1] == "toggle":
        toggle()
        return

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
