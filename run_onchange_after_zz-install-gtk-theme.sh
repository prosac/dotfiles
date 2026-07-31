#!/usr/bin/env bash
# Builds the Graphite-teal-nord GTK theme that toggle-color-scheme selects.
#
# Fedora does not package Graphite, so it is built from source. Without this the
# whole light/dark switch silently no-ops for GTK apps: gsettings gtk-theme would
# name a theme that does not exist and GTK falls back to Adwaita, which never
# changes. See ~/Documents/docs/system-color-scheme-switching.md.
#
# `zz-` prefix: run_onchange_after_ scripts run in target-name order, and this
# one needs sassc + gtk-murrine-engine from install-packages.sh ("i" < "z").
#
# Re-runs automatically when this file changes; otherwise the guard below makes
# it a no-op. To force a rebuild (e.g. after an upstream theme update):
#   rm -rf ~/.local/share/themes/Graphite-teal-{Light,Dark}-nord && chezmoi apply
set -euo pipefail

THEMES_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/themes"
WORKDIR="${XDG_CACHE_HOME:-$HOME/.cache}/graphite-gtk-theme"
REPO=https://github.com/vinceliuice/Graphite-gtk-theme

# Must match the theme names in ~/.local/bin/toggle-color-scheme. Upstream builds
# the directory as <name><theme><color><size><tweak>, so `-t teal --tweaks nord`
# with `-c light dark` yields exactly these two.
WANT=(Graphite-teal-Light-nord Graphite-teal-Dark-nord)

missing=0
for t in "${WANT[@]}"; do
  [[ -d "$THEMES_DIR/$t" ]] || missing=1
done
if [[ "$missing" -eq 0 ]]; then
  echo "==> GTK theme: ${WANT[*]} already present — skipping."
  exit 0
fi

# install.sh would `sudo dnf install sassc` interactively if it is missing. We
# list it in .chezmoidata/packages.yaml instead, so fail loudly rather than
# stalling a non-interactive `chezmoi apply` on a password prompt.
if ! command -v sassc >/dev/null; then
  echo "install-gtk-theme: sassc not found — run install-packages first." >&2
  exit 1
fi

echo "==> GTK theme: building Graphite (teal, nord) into $THEMES_DIR..."
if [[ -d "$WORKDIR/.git" ]]; then
  git -C "$WORKDIR" fetch --depth 1 origin
  git -C "$WORKDIR" reset --hard origin/HEAD
else
  git clone --depth 1 "$REPO" "$WORKDIR"
fi

# NO -l/--libadwaita. That flag symlinks a *static* gtk.css into
# ~/.config/gtk-4.0/, and libadwaita only ever reads gtk.css — so it would pin
# every GTK4 app to one scheme and break the light/dark switch we are fixing.
# GTK4/libadwaita apps instead follow the portal's org.freedesktop.appearance.
mkdir -p "$THEMES_DIR"
"$WORKDIR/install.sh" -d "$THEMES_DIR" -t teal -c light dark --tweaks nord

for t in "${WANT[@]}"; do
  [[ -d "$THEMES_DIR/$t" ]] || { echo "install-gtk-theme: expected $t, not built." >&2; exit 1; }
done
echo "==> GTK theme: installed ${WANT[*]}"
