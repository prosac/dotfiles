#!/usr/bin/env bash
# Turns a soft lockup into a panic + automatic reboot, so the next wedge leaves
# a dump in pstore instead of a machine that needs the power button.
# Re-runs automatically when this file changes.
#
# Why: on 2026-09-28 the YT6801 NIC's MAC interrupt (eno1:mac, dwmac-motorcomm)
# stormed on one CPU after resume. The RCU stall that followed blocked every new
# terminal and the shutdown path for 10 minutes, and the only record was what
# the journal happened to flush. With softlockup_panic the kernel panics after
# 2 * watchdog_thresh (20 s) and efi_pstore keeps the panic's kmsg tail.
#
# Deliberately NOT softlockup_all_cpu_backtrace: efi_pstore keeps only the last
# kmsg_bytes (~10 KB), and 24 CPU backtraces would push the "Most frequent
# HardIRQs" summary -- the line that names the culprit -- out of the dump.
#
# Gated on the hardware rather than a hostname or machineClass (the repo is
# public, and machineClass cannot tell the two laptops apart). Where the NIC is
# absent the file is removed, so a machine that loses it reverts cleanly.
#
# After a panic reboot the initrd waits for the FIDO2 touch (rd.retry=604800),
# and the reset reason reads "software ... 0xCF9" (the kernel's own reboot) --
# the evidence is in /var/lib/systemd/pstore/, not in the reset reason.
#
# See ~/Documents/docs/yt6801-eno1-irq-storm-after-resume.md
set -euo pipefail

CONF=/etc/sysctl.d/99-lockup-panic.conf
YT6801="1f0a:6801"

if ! lspci -n -d "$YT6801" | grep -q .; then
  if [[ -f "$CONF" ]]; then
    sudo rm -f "$CONF"
    echo "==> No YT6801 NIC, removed $CONF (takes effect on reboot)"
  fi
  exit 0
fi

sudo tee "$CONF" > /dev/null << 'EOF'
# Installed by chezmoi (run_onchange_after_install-lockup-panic.sh).
# A soft lockup panics; the panic reboots after 10 s and leaves a pstore dump.
kernel.softlockup_panic = 1
kernel.panic = 10
EOF

sudo sysctl -q -p "$CONF"

echo "==> Installed $CONF: softlockup_panic=$(sysctl -n kernel.softlockup_panic) panic=$(sysctl -n kernel.panic)"
