# Bootstrap — one-time per-machine setup

After `chezmoi init --apply git@github.com:prosac/dotfiles.git`, run these
to enable everything that needs root or systemd.

## 1. Install pre-commit hook in the cloned source

```sh
mise run ch:hooks
```

## 2. Btrfs dotfile snapshots (optional but recommended)

Requires `/home` on btrfs (Fedora default).

```sh
# Create the snapshot directory tree (root-owned parent, user-owned hourly/).
sudo mkdir -p /home/.snapshots/hourly
sudo chown $USER:$USER /home/.snapshots/hourly

# Install the sudoers drop-in that allows snapshot create/delete without password.
mise run bootstrap:sudoers

# Enable the hourly timer.
systemctl --user daemon-reload
systemctl --user enable --now dotsnap.timer

# Sanity check
mise run dots:snap        # one-shot snapshot
mise run dots:snaps       # list snapshots
```

Retention default: 168 hourly snapshots (~1 week). Override with
`DOTSNAP_RETAIN=N` in the timer environment if you want more/less.

## 3. Enable other user services as needed

These ship as units but aren't auto-enabled (your call per machine):

```sh
systemctl --user enable --now waybar.service
systemctl --user enable --now hyprpaper.service
systemctl --user enable --now hypridle.service
systemctl --user enable --now wired.service
systemctl --user enable --now nm-applet.service
systemctl --user enable --now polkit-mate-authentication-agent-1.service
systemctl --user enable --now kando.service
# hyprlock.service — invoked on demand by hypridle, no enable needed
```
