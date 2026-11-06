# Dotfiles

My dotfiles, managed via [`chezmoi`](https://www.chezmoi.io). `zsh` + `oh-my-zsh`,
`btrfs` snapshots of `$HOME`, and a Hyprland desktop whose shell (bar, launcher,
notifications, lock screen, idle handling) is
[Dux Shell](https://github.com/duxlabs-dev/dux-shell), formerly DankMaterialShell,
on Quickshell. It is tailored to people who drive a form of `vim` or `emacs` with
evil-mode (e.g. Doom Emacs). `mise` is the task interface for the whole thing.
Centred on Fedora 43 and 44; 42 still works via fallback paths.

> These are **my** dotfiles, published so the setup is reproducible on my own
> machines and readable to anyone who finds a piece of it useful. There is no
> support promise, and several parts assume my hardware (dual monitor, FIDO2 key,
> Wacom tablet) or a password manager (1Password or Bitwarden). Read before you run. This is not a
> collaborative project: issues and pull requests are not taken. Fork it or copy
> what you need.

## Quick start

Fedora 43 is the primary target; F42 works via fallback paths, F44 takes the same
path as 43. First, chezmoi has to exist before it can clone its own source:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/bin
```

Then pick the path that matches the machine. **The difference matters** — one of
them overwrites files without asking.

### A. Fresh machine — deploy everything

```sh
# HTTPS on purpose: a fresh machine has no SSH key registered with GitHub yet.
~/bin/chezmoi init --apply https://github.com/prosac/dotfiles.git
```

`init` prompts for `name`, `email`, `machineClass`, `passwordManager` and
`mailSetup`. `--apply` then installs the baseline packages, so **expect an
interactive `sudo` prompt** — run it in a real terminal, not over a pipe.

`passwordManager` is `1password`, `bitwarden` or `none`. Both password managers
keep secrets off disk, and either one can sign git commits through its SSH agent:

- **1Password** gets the most: `.gitconfig` turns signing on by default, and the
  credential helpers for container registries, `glab` and npm all read from it,
  as do the mail credentials.
- **Bitwarden** (the flatpak) gets the `bw` CLI and its SSH agent. Signing is
  turned on per machine in `~/.config/git/local.gitconfig`, and logins keep using
  the FIDO2 key. The 1Password-only helpers above are not wired up for it.
- **`none`** skips all of it.

### B. Existing machine — look before you overwrite

⚠️ **`chezmoi apply` overwrites existing dotfiles in place. No diff, no prompt, no
backup.** On a machine that already has a working `.zshrc`, `.gitconfig` or
`.config/hypr`, `--apply` will replace them with mine. Split the clone from the
deploy instead:

```sh
# clone + prompt only. Touches no managed dotfile — it writes just its own
# ~/.config/chezmoi/chezmoi.toml and the source clone in ~/.local/share/chezmoi.
~/bin/chezmoi init https://github.com/prosac/dotfiles.git

# see exactly what would change, before anything does
chezmoi diff | less

# take it a piece at a time
chezmoi apply ~/.config/hypr
chezmoi apply ~/.zshrc
```

Two things worth knowing while you do that:

- **`chezmoi diff` on its own is safe, but a bare `chezmoi apply` is not just
  files.** It also runs the `run_onchange_after_*` scripts — installing packages,
  enabling COPRs, enabling system services, building the GTK theme. Applying a
  named path (`chezmoi apply ~/.zshrc`) does not trigger them; applying with no
  arguments does. That is usually what you want *eventually*, just not by accident.
- **To keep something the machine already has**, pull it into the source instead of
  applying over it: `chezmoi add ~/.config/foo`. That makes your existing file the
  tracked version rather than the other way round.

### Both paths

Continue with **[`bootstrap/SETUP.md`](bootstrap/SETUP.md)** for the one-time
privileged setup that `chezmoi apply` cannot do on its own: sudoers drop-in, btrfs
snapshot timer, FIDO2 login, power management, sleep hooks. Snapshots need `/home`
on btrfs — `findmnt -no FSTYPE --target /home` — and skipping that section on a
non-btrfs machine requires disabling nothing.

## Where things are

| file | what it is |
|---|---|
| [`bootstrap/SETUP.md`](bootstrap/SETUP.md) | one-time, per-machine, privileged setup — the sequel to the quick start above |
| [`PLAYBOOK.md`](PLAYBOOK.md) | day-to-day use: the edit/apply loop, source-file naming, templating, mise tasks, troubleshooting |
| `.chezmoidata/packages.yaml` | every package, COPR and dnf policy this machine installs |
| `mise run` | the task list — `ch:*` for chezmoi, `bootstrap:*` for privileged setup, `check:*` for verification |

## Sessions

Three session entries land at the greeter. The two Hyprland ones share one `hyprland.lua`:

- **Hyprland (DMS)** — what I actually use. Hyprland with the whole shell provided
  by Dux Shell, including its own lock screen and idle handling. Its Settings UI
  edits the Lua config directly. Set it up with `mise run bootstrap:dms-session`
  and verify it with `mise run check:dms-session`. The package, the command
  and the config directory still carry the old name: `dms`, `~/.config/dms`.
- **Hyprland** — the original stack: waybar, walker + elephant, swayosd,
  hypridle + hyprlock. Still installed and still starts, but no longer my daily
  driver, so expect rough edges.
- **niri** — scrollable tiling, sharing that original stack's daemons via
  `ConditionEnvironment=` gates. Same status as plain Hyprland.

## History

- **Ancient times – 2024** — many years of different Linux desktops and tiling
  window managers such as i3, and never much discipline about keeping the
  dotfiles organised. Most of the ideas and decisions collected here come from
  that time; what is new is writing them down in one place and managing them
  with chezmoi. In 2024 this repo held just a `.zshrc`, a `.zprofile` and a
  starship prompt.
- **April 2026** — rebuilt on chezmoi around Hyprland with waybar, first with fuzzel
  as the launcher, then walker + elephant.
- **June 2026** — a niri session alongside Hyprland, sharing the same daemons.
- **August 2026** — DankMaterialShell arrived as a third, opt-in session and
  quickly became the one I use. The masks that keep the original stack out of
  that session date from here.
- **September 2026** — the Hyprland config moved from `hyprland.conf` to Lua, so
  the shell's Settings UI can edit it.
- **October 2026** — DMS 2.0, renamed Dux Shell, moved its config to `~/.config/dms`.

The original waybar/walker stack stays in the repo because it still works and the
niri session depends on it, not because it gets attention.

## Caveats worth knowing before you copy anything

- **Hyprland comes from the `lionheartp/Hyprland` COPR**, which runs ahead of
  upstream and garbage-collects old builds. Plugins are ABI-pinned to the exact
  compositor build, so any update — even a release bump — unloads them.
- **`~/bin` and `~/.local/bin` are not on the Hyprland session's PATH** (it is
  `/usr/local/bin:/usr/bin`). Anything launched from a keybind needs a full path.
- Several `run_onchange_after_*` scripts call `sudo`. Read them before applying.
