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
