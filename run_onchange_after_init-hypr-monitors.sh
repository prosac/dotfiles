#!/usr/bin/env bash
# Seed ~/.config/hypr/monitors.lua on a machine that does not have one yet.
#
# hyprland.lua loads it only if it exists (a `require` of a missing module is a
# Lua error that aborts the rest of the config), so a missing file no longer
# breaks anything -- the monitor comes up on Hyprland's defaults. But the file is
# nwg-displays' output and therefore per-machine, so it is listed in
# .chezmoiignore and a fresh machine starts without it; seeding it from the live
# layout means the first login looks like the last one. Same shape as the
# waybar style.css symlink next door: chezmoi manages everything except the one
# per-machine artefact another tool owns, so this seeds that artefact.
#
# History: this used to seed monitors.conf for hyprland.conf, whose unconditional
# `source =` put "source= globbing error: found no match" in the on-screen Error
# Overlay of every first login.
#
# NEVER overwrites an existing file. nwg-displays rewrites it wholesale on every
# save, and clobbering a real multi-monitor layout with a guess would be a far
# worse bug than a default layout.
set -eu

CONF="$HOME/.config/hypr/monitors.lua"

if [ -e "$CONF" ]; then
  exit 0
fi

mkdir -p "$(dirname "$CONF")"

{
  echo "-- Seeded by run_onchange_after_init-hypr-monitors.sh because this machine"
  echo "-- had no monitors.lua."
  echo "--"
  echo "-- nwg-displays owns this file and overwrites it wholesale on save -- run it"
  echo "-- to set an actual layout. Per-machine, so it is in .chezmoiignore."
} > "$CONF"

# Prefer the live layout when there is a compositor to ask. `chezmoi apply` is
# just as likely to run from a TTY or during first bootstrap, where hyprctl
# either is not there or has no socket to talk to -- in that case the
# placeholder is harmless.
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
    print(f'hl.monitor({{ output = "{m["name"]}", '
          f'mode = "{m["width"]}x{m["height"]}@{m["refreshRate"]:.5f}", '
          f'position = "{m["x"]}x{m["y"]}", scale = {m["scale"]} }})')
PY
fi

# Report what actually landed, not what was attempted. An earlier version said
# "seeded from the running compositor" unconditionally after a `|| true`, so a
# python that failed outright still reported success.
if grep -q '^hl.monitor' "$CONF"; then
  echo "  seeded $CONF from the running compositor ($(grep -c '^hl.monitor' "$CONF") output(s))"
else
  echo "  seeded $CONF as a placeholder (no layout read; run nwg-displays to set one)"
fi
