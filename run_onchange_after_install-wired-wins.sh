#!/usr/bin/env bash
# Makes a plugged-in LAN cable always carry the traffic: wired default route
# metric 100, Wi-Fi 600 (NM's own defaults, made explicit), and a dispatcher
# hook that removes any per-profile route-metric pin when a device comes up.
# Re-runs automatically when this file changes.
#
# Why: per-profile values beat the global defaults, and something keeps pinning
# them -- on 2026-09-04 (every Wi-Fi profile 100, wired 300) and again on
# 2026-10-05 15:45:56, source unknown both times. The cable then sat up at
# 1 Gb/s while all traffic went over the Wi-Fi repeater. The hook undoes such a
# pin and logs the old value (journalctl -t wired-wins), so the next one is dated.
#
# Not gated: on a machine without a cable the hook only ever finds nothing to do.
#
# See ~/Documents/docs/wifi-slow-despite-cable-scan-latency.md
set -euo pipefail

CONF=/etc/NetworkManager/conf.d/90-wired-wins.conf
HOOK=/etc/NetworkManager/dispatcher.d/90-wired-wins

sudo tee "$CONF" > /dev/null << 'EOF'
# Installed by chezmoi (run_onchange_after_install-wired-wins.sh).
# Defaults for profiles whose route-metric is -1: the cable wins over Wi-Fi.
[connection-wired-wins-ethernet]
match-device=type:ethernet
ipv4.route-metric=100
ipv6.route-metric=100

[connection-wired-wins-wifi]
match-device=type:wifi
ipv4.route-metric=600
ipv6.route-metric=600
EOF

sudo tee "$HOOK" > /dev/null << 'EOF'
#!/usr/bin/python3
# Installed by chezmoi (run_onchange_after_install-wired-wins.sh).
# On any device "up": an active ethernet/Wi-Fi profile with a pinned
# route-metric would override 90-wired-wins.conf, so reset it to -1.
import subprocess
import sys
import syslog

TYPES = {"802-3-ethernet", "802-11-wireless"}
KEYS = ("ipv4.route-metric", "ipv6.route-metric")


def nmcli(*args):
    return subprocess.run(["nmcli", *args], capture_output=True, text=True,
                          timeout=5, check=True).stdout


def main():
    if len(sys.argv) < 3 or sys.argv[2] != "up":
        return
    syslog.openlog("wired-wins")
    for line in nmcli("-t", "-f", "UUID,TYPE,DEVICE,NAME", "con", "show", "--active").splitlines():
        uuid, ctype, device, name = line.split(":", 3)
        if ctype not in TYPES:
            continue
        values = nmcli("-g", ",".join(KEYS), "con", "show", uuid).split()
        if all(v == "-1" for v in values):
            continue
        nmcli("con", "modify", uuid, *(a for k in KEYS for a in (k, "-1")))
        nmcli("dev", "reapply", device)
        syslog.syslog(syslog.LOG_WARNING,
                      f"reset pinned route-metric {values} on {name!r} ({device}) to default")


main()
EOF
sudo chmod 755 "$HOOK"
sudo restorecon "$CONF" "$HOOK"
sudo nmcli general reload conf

echo "==> Installed $CONF and $HOOK"
