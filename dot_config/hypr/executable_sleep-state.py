#!/usr/bin/env python3
"""Text for hyprlock's sleep-state label.

Prints one short line, or nothing at all. Nothing is the normal case, so the
label is invisible unless a hibernation is actually involved.

Why this exists: during hibernation `user.slice` is frozen, so nothing in the
session can draw. systemd-sleep(8) is explicit that this "prevents the hooks in
/usr/lib/systemd/system-sleep/, or any other process for that matter, from
communicating with any user session process during sleep". A message therefore
has to be painted BEFORE the freeze and simply survive on screen, and the state
has to travel through a file rather than through any kind of IPC.

Writers of that file:
  - ~/.local/bin/hibernate-now                        -> "hibernating"
  - /usr/lib/systemd/system-sleep/hibernate-resume-stamp
        pre  + SYSTEMD_SLEEP_ACTION=hibernate         -> "hibernating"
        post + SYSTEMD_SLEEP_ACTION=hibernate         -> "resumed"
        post + anything else                          -> removes it

The file lives in $XDG_RUNTIME_DIR, which is tmpfs — so a machine that never
comes back from hibernation (flat battery) boots with no stale state. Note that
tmpfs *is* RAM and therefore part of the hibernation image, which is exactly why
a stamp written before the image is taken is still there after the resume.

Read by: hyprlock.conf, `text = cmd[update:2000] ...`
See ~/Documents/docs/suspend-then-hibernate-setup.md
"""

import os
import pathlib
import time

STAMP = "hyprlock-sleep-state"

# "resumed" is shown only briefly. Without a window it would still be on the
# lock screen hours later, and would reappear on the next idle lock of the same
# session — claiming a hibernation that is long past.
RESUMED_TTL_SECONDS = 600

MESSAGES = {
    "hibernating": "Hibernating — writing memory image, do not power off",
    "resumed": "Resumed from hibernation",
}


def stamp_path() -> pathlib.Path:
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return pathlib.Path(runtime) / STAMP


def message() -> str:
    try:
        raw = stamp_path().read_text().strip()
    except (OSError, ValueError):
        return ""
    if not raw:
        return ""

    state, _, written = raw.partition(" ")
    text = MESSAGES.get(state)
    if not text:
        return ""

    # "hibernating" never expires: the write is the last thing that happens
    # before power-off, so whatever is on screen has to stay there.
    if state != "resumed":
        return text

    try:
        age = time.time() - float(written)
    except ValueError:
        return ""
    return text if 0 <= age <= RESUMED_TTL_SECONDS else ""


if __name__ == "__main__":
    # Never traceback into the lock screen: no text beats a stack trace.
    try:
        print(message())
    except Exception:
        print()
