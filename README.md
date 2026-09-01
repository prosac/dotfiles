# Dotfiles

My dotfiles, managed via [`chezmoi`](https://www.chezmoi.io). `zsh` + `oh-my-zsh`,
`btrfs` snapshots of `$HOME`, and a Hyprland/niri desktop built around `elephant`,
`walker` and `waybar`, tailored to people who drive a form of `vim` or `emacs` with
evil-mode (e.g. Doom Emacs). `mise` is the task interface for the whole thing.
Centred on Fedora 42 and 43.

> These are **my** dotfiles, published so the setup is reproducible on my own
> machines and readable to anyone who finds a piece of it useful. There is no
> support promise, and several parts assume my hardware (dual monitor, FIDO2 key,
> Wacom tablet) or my accounts (1Password). Read before you run.

## Quick start (new machine)

Fedora 43 is the primary target; F42 works via fallback paths.

```sh
# 1. chezmoi has to exist before it can clone its own source
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/bin

# 2. clone + deploy. HTTPS on purpose: a fresh machine has no SSH key yet.
~/bin/chezmoi init --apply https://github.com/prosac/dotfiles.git
```

`init` prompts for `name`, `email`, `machineClass`, `passwordManager` and
`mailSetup`. `--apply` then installs the baseline packages, so **expect an
interactive `sudo` prompt** — run it in a real terminal, not over a pipe.

Once 1Password (or your SSH key) is set up, switch the remote so you can push:

```sh
chezmoi git -- remote set-url origin git@github.com:prosac/dotfiles.git
```

Then continue with **[`bootstrap/SETUP.md`](bootstrap/SETUP.md)** for the one-time
privileged setup that `chezmoi apply` cannot do on its own: sudoers drop-in, btrfs
snapshot timer, FIDO2 login, power management, sleep hooks.

## Where things are

| file | what it is |
|---|---|
| [`bootstrap/SETUP.md`](bootstrap/SETUP.md) | one-time, per-machine, privileged setup — the sequel to the quick start above |
| [`PLAYBOOK.md`](PLAYBOOK.md) | day-to-day use: the edit/apply loop, source-file naming, templating, mise tasks, troubleshooting |
| `.chezmoidata/packages.yaml` | every package, COPR and dnf policy this machine installs |
| `mise run` | the task list — `ch:*` for chezmoi, `bootstrap:*` for privileged setup, `check:*` for verification |

## Sessions

Three session entries land at the greeter, all sharing one `hyprland.conf`:

- **Hyprland** — the default: waybar, walker, swayosd, hypridle + hyprlock.
- **niri** — scrollable tiling, sharing the same daemons via `ConditionEnvironment=` gates.
- **Hyprland (DMS)** — the same compositor with the entire shell replaced by
  [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell), including
  its own lock screen and idle handling. Opt-in: `mise run bootstrap:dms-session`.
  Verify a session with `mise run check:dms-session`.

## Caveats worth knowing before you copy anything

- **Hyprland comes from the `lionheartp/Hyprland` COPR**, which runs ahead of
  upstream and garbage-collects old builds. Plugins are ABI-pinned to the exact
  compositor build, so any update — even a release bump — unloads them.
- **`~/bin` and `~/.local/bin` are not on the Hyprland session's PATH** (it is
  `/usr/local/bin:/usr/bin`). Anything launched from a keybind needs a full path.
- Several `run_onchange_after_*` scripts call `sudo`. Read them before applying.
