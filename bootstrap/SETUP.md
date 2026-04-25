# Bootstrap — one-time per-machine setup

## 0. Install chezmoi (chicken-and-egg)

Chezmoi has to exist before it can clone its own source. The official one-liner:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/bin
```

Then add `~/bin` to `$PATH` if it isn't already (it is, after Step 1 deploys `.zshrc`).

```sh
chezmoi init --apply git@github.com:prosac/dotfiles.git
```

`init` prompts for `name`, `email`, and `machineClass` (laptop/desktop). On `apply`, the `run_onchange_after_install-packages.sh.tmpl` script runs (see Step 4 below) — interactive `sudo` will be required.

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

## 3. Baseline packages

Already handled automatically by `run_onchange_after_install-packages.sh.tmpl` during the first `chezmoi apply` (Step 0). To re-trigger it manually after editing `.chezmoidata/packages.yaml`:

```sh
mise run ch:apply
```

The script enables COPRs, runs `dnf install`, and curl-installs `mise` and `starship` if absent. All steps idempotent.

## 4. Enable other user services as needed

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
