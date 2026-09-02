#!/usr/bin/env bash
# Seed ~/.config/hypr/monitors.conf on a machine that does not have one yet.
#
# hyprland.conf sources it unconditionally:
#
#     source = ~/.config/hypr/monitors.conf
#
# and Hyprland has no optional-source keyword. The file is nwg-displays' output
# and therefore per-machine, so it is listed in .chezmoiignore and a fresh
# machine starts without it -- which means the very first Hyprland login greets
# you with the on-screen Error Overlay:
#
#     Config error in file ~/.config/hypr/hyprland.conf at line 27:
#       source= globbing error: found no match
#
# Nothing is broken by it (the monitor still comes up on Hyprland's defaults),
# but it is the first thing you see on a new machine and it looks like the
# config is wrong when it is merely incomplete. Same shape as the waybar
# style.css symlink next door: chezmoi manages everything except the one
# per-machine artefact another tool owns, so this seeds that artefact.
#
# NEVER overwrites an existing file. nwg-displays rewrites it wholesale on every
# save, and clobbering a real multi-monitor layout with a guess would be a far
# worse bug than the error message this exists to remove.
set -eu

CONF="$HOME/.config/hypr/monitors.conf"

if [ -e "$CONF" ]; then
  exit 0
fi

mkdir -p "$(dirname "$CONF")"

{
  echo "# Seeded by run_onchange_after_init-hypr-monitors.sh because this machine"
  echo "# had no monitors.conf and hyprland.conf sources it unconditionally."
  echo "#"
  echo "# nwg-displays owns this file and overwrites it wholesale on save -- run it"
  echo "# to set an actual layout. Per-machine, so it is in .chezmoiignore."
} > "$CONF"

# Prefer the live layout when there is a compositor to ask. `chezmoi apply` is
# just as likely to run from a TTY or during first bootstrap, where hyprctl
# either is not there or has no socket to talk to -- in that case an empty but
# PRESENT file is still the whole fix, because it is the missing file, not the
# missing monitor rule, that Hyprland complains about.
#
# python calls hyprctl itself rather than being fed by a pipe: the program has to
# arrive on stdin via a quoted heredoc (so the shell leaves its quoting alone),
# and stdin cannot also carry the JSON.
if command -v hyprctl >/dev/null 2>&1 && hyprctl -j monitors >/dev/null 2>&1; then
  python3 - >> "$CONF" <<'PY' || true
import json, subprocess
out = subprocess.run(["hyprctl", "-j", "monitors"],
                     capture_output=True, text=True).stdout
for m in json.loads(out):
    print(f"monitor={m['name']},{m['width']}x{m['height']}"
          f"@{m['refreshRate']:.5f},{m['x']}x{m['y']},{m['scale']}")
PY
fi

# Report what actually landed, not what was attempted. An earlier version said
# "seeded from the running compositor" unconditionally after a `|| true`, so a
# python that failed outright still reported success -- the file was created, so
# the error message was gone either way and nothing would have caught it.
if grep -q '^monitor=' "$CONF"; then
  echo "  seeded $CONF from the running compositor ($(grep -c '^monitor=' "$CONF") output(s))"
else
  echo "  seeded $CONF as a placeholder (no layout read; run nwg-displays to set one)"
fi
