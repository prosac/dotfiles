#!/usr/bin/env bash
# Installs system-sleep hooks for generic Wayland GPU recovery on resume.
# Re-runs automatically when this file changes.
set -euo pipefail

HOOK=/usr/lib/systemd/system-sleep/wayland-gpu-wakefix
OLD_HOOK=/usr/lib/systemd/system-sleep/chromium-gpu-restart

sudo tee "$HOOK" > /dev/null << 'EOF'
#!/bin/bash
case "$1/$2" in
  post/suspend|post/hibernate|post/hybrid-sleep|post/suspend-then-hibernate)
    # Kill GPU subprocess for all Chromium-based apps (Chrome, Electron: VS Code, Discord, Slack, etc.)
    pkill -f -- "--type=gpu-process" || true
    # Kill WebKit renderer/network processes (GNOME Web, Evolution, some Flatpaks)
    pkill -f "WebKitNetworkProcess" || true
    pkill -f "WebKitWebProcess" || true
    # Force Hyprland to repaint all windows after GPU processes respawn
    sleep 1
    HYPRLAND_INSTANCE_SIGNATURE=$(ls /tmp/hypr/ 2>/dev/null | head -1) \
      hyprctl dispatch forcerendererreload 2>/dev/null || true
    ;;
esac
EOF

sudo chmod +x "$HOOK"

# Remove old chromium-specific hook if still present
[[ -f "$OLD_HOOK" ]] && sudo rm "$OLD_HOOK"

echo "==> Installed $HOOK"

# ---------------------------------------------------------------------------
# Hibernation state for hyprlock's sleep-state label.
# ---------------------------------------------------------------------------
STAMP_HOOK=/usr/lib/systemd/system-sleep/hibernate-resume-stamp

sudo tee "$STAMP_HOOK" > /dev/null << 'EOF'
#!/bin/bash
# Records hibernation state so the lock screen can mention it.
#
# $1 is pre|post. SYSTEMD_SLEEP_ACTION carries the *leg* being processed --
# "suspend", "hibernate", or "suspend-after-failed-hibernate" -- and is the only
# way to tell a suspend-then-hibernate escalation from a plain suspend, since $2
# reads "suspend-then-hibernate" for every leg. Falls back to $2 on a systemd too
# old to set it, which then lands harmlessly in the post:* clear branch.
#
# user.slice is frozen while this runs, so no IPC with hyprlock is possible --
# see systemd-sleep(8). Writing a file needs no reply, which is why this works
# where `hyprctl` cannot.
STAMP=hyprlock-sleep-state

write_state() {
  for dir in /run/user/*; do
    [ -d "$dir" ] || continue
    printf '%s %s\n' "$1" "$(date +%s)" > "$dir/$STAMP" 2>/dev/null || continue
    # Hand ownership to the session user so hibernate-now can replace it later.
    chown --reference="$dir" "$dir/$STAMP" 2>/dev/null || true
    chmod 0644 "$dir/$STAMP" 2>/dev/null || true
  done
}

clear_state() {
  for dir in /run/user/*; do
    rm -f "$dir/$STAMP" 2>/dev/null || true
  done
}

case "$1:${SYSTEMD_SLEEP_ACTION:-$2}" in
  pre:hibernate)  write_state hibernating ;;
  post:hibernate) write_state resumed ;;
  post:*)         clear_state ;;
esac
EOF

sudo chmod +x "$STAMP_HOOK"

echo "==> Installed $STAMP_HOOK"

# ---------------------------------------------------------------------------
# FIDO2 authenticator reset on resume.
# ---------------------------------------------------------------------------
FIDO_HOOK=/usr/lib/systemd/system-sleep/fido2-resume-reset

sudo tee "$FIDO_HOOK" > /dev/null << 'EOF'
#!/usr/bin/env python3
"""USB-reset the FIDO2 authenticator on resume, so PAM meets a live device.

The key does NOT survive s2idle. Measured across six resume cycles on
2026-08-12/13: the kernel logs no disconnect and no re-enumeration on resume, so
the device stays in the tree looking present while being functionally dead. The
only thing that revived it was physically unplugging and reinserting it.

Why that is worse than it sounds. /etc/pam.d/hyprlock-fido2 is:

    auth  sufficient  pam_u2f.so cue
    auth  required    pam_unix.so

A dead-but-present device makes pam_u2f BLOCK rather than fail, so pam_unix is
never reached and the password fallback disappears with it. The lock screen looks
frozen: the key does nothing and typing does nothing. That is distinct from the
documented "three Enters" symptom, where pam_u2f finishes (CTAP timeout, ~31s)
and correctly falls through. pam_u2f has no timeout option -- `nodetect` does not
help either, since the default check-only probe and the full authentication block
in the same place -- so this cannot be fixed in the PAM stack. The device has to
be alive before PAM touches it.

USBDEVFS_RESET is used rather than a `power/control` change (autosuspend is
already held off by /etc/udev/rules.d/50-usb-no-autosuspend.rules, and the key
still died) and rather than deauthorize/reauthorize via `authorized`, which only
re-binds the driver and re-reads descriptors. The reset is a real port reset --
`usb N-M: reset full-speed USB device number D using xhci_hcd` -- and is the
closest available equivalent to the replug that is known to work.

⚠️ Do NOT use the `remove` sysfs attribute here. It detaches the device with no
automatic rescan on a root port, so it would leave the key gone until a physical
replug -- strictly worse than the bug.

Expected side benefit, not yet confirmed against a real occurrence: the lock
screen arms its PAM transaction BEFORE the suspend (hypridle's
before_sleep_cmd), so a stale transaction is already holding the old handle on
resume. Resetting the device should invalidate that handle, turning the hang into
a prompt failure -- which restores the password fallback and lets hyprlock's
retry loop re-arm the key.

Runs on post/* only. Never fails the resume: every error is swallowed, because a
sleep hook that exits non-zero is a worse problem than an unreset key.

See ~/Documents/docs/fido2-login-latency-power-management.md
"""

import fcntl
import os
import sys
import syslog

USBDEVFS_RESET = 0x5514  # _IO('U', 20)

# (idVendor, idProduct) -- Kensington VeriMark Guard Fingerprint Key.
TARGETS = {("047d", "8055")}

SYSFS_USB = "/sys/bus/usb/devices"


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def usb_targets():
    """Yield /dev/bus/usb node paths for every connected target device."""
    try:
        entries = sorted(os.listdir(SYSFS_USB))
    except OSError:
        return
    for name in entries:
        d = os.path.join(SYSFS_USB, name)
        vid, pid = read(f"{d}/idVendor"), read(f"{d}/idProduct")
        if (vid, pid) not in TARGETS:
            continue
        bus, dev = read(f"{d}/busnum"), read(f"{d}/devnum")
        if not (bus and dev):
            continue
        yield name, f"/dev/bus/usb/{int(bus):03d}/{int(dev):03d}"


def reset(node):
    fd = os.open(node, os.O_WRONLY)
    try:
        fcntl.ioctl(fd, USBDEVFS_RESET, 0)
    finally:
        os.close(fd)


def main():
    # $1 is pre|post, $2 is the sleep action. Only resume is interesting.
    if len(sys.argv) < 2 or sys.argv[1] != "post":
        return 0

    syslog.openlog("fido2-resume-reset", facility=syslog.LOG_DAEMON)
    found = False
    for name, node in usb_targets():
        found = True
        try:
            reset(node)
            syslog.syslog(syslog.LOG_INFO, f"reset {name} at {node}")
        except OSError as e:
            # Not fatal: the key may have been unplugged during the suspend.
            syslog.syslog(syslog.LOG_WARNING, f"reset {name} failed: {e}")
    if not found:
        syslog.syslog(syslog.LOG_INFO, "no FIDO2 authenticator connected, nothing to reset")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never fail a resume
        try:
            syslog.syslog(syslog.LOG_ERR, f"unexpected error: {e}")
        except Exception:
            pass
        sys.exit(0)
EOF

sudo chmod +x "$FIDO_HOOK"

echo "==> Installed $FIDO_HOOK"

# ---------------------------------------------------------------------------
# DRM debug capture around every modeset window (suspend/resume AND idle DPMS).
# ---------------------------------------------------------------------------
# Renamed from drm-debug-resume-capture on 2026-09-15: the 09-15 occurrence had
# no suspend at all, so "resume" was the wrong name for the class.
OLD_DRM_HOOK=/usr/lib/systemd/system-sleep/drm-debug-resume-capture
DRM_HOOK=/usr/lib/systemd/system-sleep/drm-debug-modeset-capture
DRM_UNIT=/etc/systemd/system/drm-debug-modeset-watch.service

sudo tee "$DRM_HOOK" > /dev/null << 'EOF'
#!/usr/bin/env python3
"""Arm drm.debug across every window in which a modeset may be attempted, so
the next failed one leaves a filable kernel trace.

Three times now (2026-09-07 HDMI-A-1, 2026-09-10 eDP-1, 2026-09-15 eDP-1)
amdgpu answered `Invalid argument` to an atomic modeset and logged NOTHING
about why: the only record was aquamarine's own error line. The reason lives
behind drm.debug, which has to be on *before* the commit is attempted -- after
the fact there is nothing to read.

TWO TRIGGERS, because the class is not resume-specific:

  1. suspend/resume -- this file is a system-sleep hook, run with pre|post.
  2. idle DPMS off -> on -- this file is ALSO the ExecStart of
     drm-debug-modeset-watch.service, which polls the DRM connectors and arms
     the same window when an output powers down.

Trigger 2 is the one that was missing, and it is the more frequent of the two:
the 09-15 occurrence happened after an overnight *idle* with no sleep
transition anywhere in the journal, so a sleep hook could never have seen it.

Why not just set drm.debug=0x14 on the kernel cmdline: it is far too loud to
leave on permanently. Both triggers bound the window to the interval in which
the display pipeline is actually being reconfigured.

⚠️ Why the sleep disarm is DEFERRED rather than done inline in the post hook.
Sleep hooks run while user.slice is still frozen -- from the 09-10 journal:

    08:33:34  System returned from sleep operation 'suspend'
    08:33:34  fido2-resume-reset: reset 5-1          <- post hooks
    08:33:35  Successfully thawed unit 'user.slice'  <- compositor unfreezes
    08:33:35  Operation 'suspend' finished

The compositor cannot attempt its modeset until the thaw, i.e. strictly after
every post hook has returned. Disarming inline would close the window before the
commit we are trying to capture; sleeping inline would instead delay the resume
for everything else. So `post` schedules a transient timer that re-invokes this
script with --disarm, and returns immediately. The watch path has no such
constraint -- it is a daemon, so it just waits.

⚠️ The watch window is open for as long as the displays are off, which for an
overnight idle is ~12 h. That is deliberate: the failure lands at the *end* of
the idle, on the wake commit, so a timeout that closed the window early would
close it exactly before the thing worth capturing. What bounds the journal is
the volume valve (MAX_WINDOW_LINES), not a clock. With the outputs off the
kernel is nearly silent, so a quiet night costs a few dozen lines.

At disarm the kernel log for the window is scanned and a one-line verdict goes
to syslog, so a bad wake is discoverable without knowing to go looking. The
journal is persistent here, so the full trace survives a reboot:

    journalctl -t drm-debug-modeset-capture -b
    journalctl -k --since '<armed timestamp from the syslog line>'

Retire this once the trace is captured and the bug is filed -- it is a
diagnostic, not a fix. See
~/Documents/docs/hyprland-resume-hdmi-modeset-failure-lock-invisible.md

Never fails a resume: every error is swallowed, because a sleep hook that exits
non-zero is a worse problem than a missing trace.
"""

import glob
import os
import subprocess
import sys
import syslog
import time

# DRM_UT_KMS (0x04) + DRM_UT_ATOMIC (0x10). Add DRM_UT_DP (0x100) -> 0x114 if
# link training rather than atomic validation becomes the suspect.
MASK = "0x14"

# Must comfortably outlast the thaw plus the compositor's modeset attempts. The
# 09-10 failure landed within ~1 s of the thaw; 09-07 retried for minutes.
DISARM_DELAY = 30

DEBUG_PARAM = "/sys/module/drm/parameters/debug"
STATE = "/run/drm-debug-modeset-capture.state"
UNIT = "drm-debug-modeset-disarm"

# --- watch-mode tuning ------------------------------------------------------
POLL_INTERVAL = 2
# A connector must hold a state for this many consecutive polls before it counts,
# so the transient disabled/enabled flapping *inside* a modeset is not mistaken
# for the end state.
SETTLE_POLLS = 3
# Safety valve on journal volume rather than on wall-clock (see the module
# docstring). 40k kernel lines is far more than a quiet night and far less than
# a runaway.
MAX_WINDOW_LINES = 40000
VOLUME_CHECK_INTERVAL = 300


def log(level, msg):
    try:
        syslog.syslog(level, msg)
    except Exception:
        pass


def write_param(value):
    with open(DEBUG_PARAM, "w") as f:
        f.write(f"{value}\n")


def read_param():
    with open(DEBUG_PARAM) as f:
        return f.read().strip()


def arm(owner):
    previous = read_param()
    # Someone (a manual capture, a cmdline setting, the other trigger) already
    # turned it on -- do not take ownership, or our disarm would silently undo
    # their window.
    if previous not in ("0", ""):
        log(syslog.LOG_INFO, f"drm.debug already {previous}, leaving it alone")
        return False
    write_param(MASK)
    with open(STATE, "w") as f:
        f.write(f"{previous} {int(time.time())} {owner}\n")
    log(syslog.LOG_INFO, f"armed drm.debug={MASK} for the {owner} window")
    return True


def read_state():
    """-> (previous, since, owner) or None. Tolerates the pre-owner format."""
    try:
        with open(STATE) as f:
            parts = f.read().split()
    except OSError:
        return None
    if len(parts) == 2:
        return parts[0], parts[1], "sleep"
    if len(parts) == 3:
        return parts[0], parts[1], parts[2]
    return None


def schedule_disarm():
    st = read_state()
    if st is None or st[2] != "sleep":
        # Either arm() declined, or the watch path already owns this window and
        # will close it when the outputs come back. Closing someone else's
        # window here would drop the trace we are trying to keep.
        return
    subprocess.run(
        ["systemd-run", f"--on-active={DISARM_DELAY}", f"--unit={UNIT}",
         "--description=Close the drm.debug modeset capture window",
         os.path.abspath(__file__), "--disarm", "sleep"],
        check=True, capture_output=True,
    )
    log(syslog.LOG_INFO, f"disarm scheduled in {DISARM_DELAY}s (after user.slice thaws)")


def kernel_lines(since):
    out = subprocess.run(
        ["journalctl", "-k", "--no-pager", "-q", "-o", "cat", "--since", f"@{since}"],
        check=False, capture_output=True, text=True,
    ).stdout
    return out.splitlines()


def scan(since):
    """Report whether the captured window contains a rejected commit."""
    lines = kernel_lines(since)
    hits = [ln for ln in lines
            if "*ERROR*" in ln or "atomic_check" in ln.lower()]
    if hits:
        log(syslog.LOG_WARNING,
            f"{len(hits)} DRM error/atomic_check lines in the window -- "
            f"trace: journalctl -k --since @{since}")
        log(syslog.LOG_WARNING, f"first: {hits[0][-200:]}")
    else:
        log(syslog.LOG_INFO, f"clean window, no DRM errors (from @{since})")


def disarm(expect_owner=None):
    st = read_state()
    if st is None:
        return
    previous, since, owner = st
    if expect_owner is not None and owner != expect_owner:
        return  # not our window to close
    write_param(previous or "0")
    if since:
        scan(since)
    try:
        os.unlink(STATE)
    except OSError:
        pass
    log(syslog.LOG_INFO, f"drm.debug restored to {previous or '0'}")


# --- watch mode -------------------------------------------------------------

def connectors():
    """Every real DRM connector's (name, status, enabled, dpms)."""
    out = []
    for path in sorted(glob.glob("/sys/class/drm/card*-*")):
        name = os.path.basename(path)
        if "Writeback" in name:
            continue

        def attr(a):
            try:
                with open(os.path.join(path, a)) as f:
                    return f.read().strip()
            except OSError:
                return ""

        out.append({
            "name": name,
            "status": attr("status"),
            "enabled": attr("enabled"),
            "dpms": attr("dpms"),
        })
    return out


def is_lit(c):
    return c["enabled"] == "enabled" and c["dpms"] == "On"


def describe(conns):
    return " ".join(f"{c['name']}={c['enabled']}/{c['dpms'] or '-'}" for c in conns
                    if c["status"] == "connected")


def watch():
    """Arm around every DPMS-off -> DPMS-on transition on a connected output.

    The window opens when a connected output stops being lit and closes
    DISARM_DELAY seconds after every connected output is lit again. If one
    output comes back and another stays dark, that IS the failure -- the window
    is closed immediately so the trace is scanned while it is fresh, and the
    verdict names the recovery command.
    """
    log(syslog.LOG_INFO, "watching DRM connectors for DPMS transitions")
    armed = False
    dark_since = None
    lit_since = None
    stuck_polls = 0
    last_volume_check = 0.0

    while True:
        conns = connectors()
        live = [c for c in conns if c["status"] == "connected"]
        if not live:
            time.sleep(POLL_INTERVAL)
            continue

        dark = [c for c in live if not is_lit(c)]
        lit = [c for c in live if is_lit(c)]
        now = time.time()

        if dark and not armed:
            dark_since = dark_since or now
            if now - dark_since >= SETTLE_POLLS * POLL_INTERVAL:
                if arm("idle-dpms"):
                    armed = True
                dark_since = None
        elif not dark:
            dark_since = None

        # The failure signature: one connected output lit, another stuck dark.
        if armed and lit and dark:
            stuck_polls += 1
            if stuck_polls == SETTLE_POLLS:
                # "card1-eDP-1" -> "eDP-1", the name hyprctl actually takes.
                outs = [c["name"].split("-", 1)[1] for c in dark]
                fix = "; ".join(f"hyprctl dispatch dpms off {o}; "
                                f"hyprctl dispatch dpms on {o}" for o in outs)
                log(syslog.LOG_WARNING,
                    f"output(s) {' '.join(outs)} stuck dark while {describe(lit)} "
                    f"came back -- modeset likely refused; recover with: {fix}")
                disarm("idle-dpms")
                armed = False
                stuck_polls = 0
                lit_since = None
                time.sleep(POLL_INTERVAL)
                continue
        else:
            stuck_polls = 0

        # Normal close: everything is lit again.
        if armed and not dark:
            lit_since = lit_since or now
            if now - lit_since >= DISARM_DELAY:
                disarm("idle-dpms")
                armed = False
                lit_since = None
        else:
            lit_since = None

        # Volume valve.
        if armed and now - last_volume_check >= VOLUME_CHECK_INTERVAL:
            last_volume_check = now
            st = read_state()
            if st and st[2] == "idle-dpms":
                count = len(kernel_lines(st[1]))
                if count > MAX_WINDOW_LINES:
                    log(syslog.LOG_WARNING,
                        f"window produced {count} kernel lines (> {MAX_WINDOW_LINES}) "
                        f"-- disarming early to protect the journal")
                    disarm("idle-dpms")
                    armed = False

        time.sleep(POLL_INTERVAL)


def main():
    syslog.openlog("drm-debug-modeset-capture", facility=syslog.LOG_DAEMON)
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--disarm":
        # Owner is passed by the transient timer so a deferred sleep disarm
        # cannot close a window the watch path opened in the meantime.
        disarm(sys.argv[2] if len(sys.argv) > 2 else None)
        return 0
    if arg == "--watch":
        watch()
        return 0
    # $1 is pre|post, $2 is the sleep action.
    if arg == "pre":
        arm("sleep")
    elif arg == "post":
        schedule_disarm()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as e:  # never fail a resume
        try:
            syslog.syslog(syslog.LOG_ERR, f"unexpected error: {e}")
        except Exception:
            pass
        sys.exit(0)
EOF

sudo chmod +x "$DRM_HOOK"

# The old resume-only name would otherwise keep running alongside the new one
# and fight it for ownership of drm.debug.
[[ -f "$OLD_DRM_HOOK" ]] && sudo rm -f "$OLD_DRM_HOOK"

sudo tee "$DRM_UNIT" > /dev/null << EOF
[Unit]
Description=Arm drm.debug around idle DPMS transitions to capture refused modesets
Documentation=file://$HOME/Documents/docs/hyprland-resume-hdmi-modeset-failure-lock-invisible.md
# Deliberately NOT Conflicts=systemd-suspend.service: that would stop the
# watcher at suspend and nothing would bring it back after resume, which is
# exactly when it is needed. The arm()/disarm() owner field is what keeps the
# sleep hook and this daemon from closing each other's windows.

[Service]
Type=simple
ExecStart=$DRM_HOOK --watch
Restart=on-failure
RestartSec=5
# Needs to write /sys/module/drm/parameters/debug and read the kernel journal.
ProtectSystem=strict
# ProtectSystem=strict leaves the API subtrees (/dev, /proc, /sys) writable, so
# /sys/module/drm/parameters/debug stays reachable; /run holds the state file.
ProtectKernelTunables=no
ReadWritePaths=/run
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now drm-debug-modeset-watch.service

echo "==> Installed $DRM_HOOK (sleep hook + $DRM_UNIT watch)"
