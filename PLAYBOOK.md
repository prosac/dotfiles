# Playbook

Living reference for working with this chezmoi-managed dotfile repo.

## Mental model

Two directories, two directions.

```
~/.local/share/chezmoi/  ── chezmoi apply  ──▶  ~   (target = live home)
       (source repo)     ◀── chezmoi re-add ──
```

- **source → target** via `chezmoi apply`: renders templates, writes files.
- **target → source** via `chezmoi re-add`: captures edits you made to live files.
- `chezmoi diff` = what `apply` would change.
- `chezmoi status` = drift in either direction. `MM` on a file = *both* sides changed; you must pick.

There is no merge. Pick a direction per file.

### Direction discipline (foot-gun)

The cardinal rule: **the side you edited is the side you keep.** Crossing them silently destroys work.

- You edited the **live** file → run `chezmoi re-add` (captures into source).
- You edited the **source** file → run `chezmoi apply` (deploys to target).

Running the wrong command swaps in the *other* side's content. `re-add` after a source edit overwrites your source edit with the (older) target. `apply` after a live edit overwrites your live edit with the (older) source.

If you're not sure which side has the latest, run `chezmoi diff` first — it shows what `apply` would change. If the diff would discard work, run `re-add` first.

## Workflow loops

### Day-to-day

1. Edit live config directly (e.g. `~/.config/hypr/hyprland.conf`).
2. `mise run ch:status` — see what drifted.
3. `mise run ch:diff` — review the delta.
4. `mise run ch:readd` — capture into source.
5. `mise run ch:push -- "hyprland: add foo binding"` — stage all source changes, commit, push (gitleaks pre-commit runs).

Direct `chezmoi` commands work too; mise tasks are shortcuts + aide-memoire.

### Reviewing changes (what did I touch since yesterday?)

`dotreview` compares live `~/` against the most recent btrfs snapshot of `/home` and buckets the result by chezmoi-tracked vs untracked.

```sh
mise run dots:review                # against latest snapshot (default)
mise run dots:review -- 2026-04-25-1300   # against specific snapshot
mise run dots:snaps                 # list snapshots
```

Output buckets:
- **modified-tracked** — chezmoi knows it, you've changed it → `chezmoi re-add`
- **new-untracked** — new file, chezmoi doesn't know → `chezmoi add`
- **changed-untracked** — pre-existing but untracked, content differs → review by hand
- **removed** — was in snapshot, gone in live

Snapshots run hourly via `dotsnap.timer` (systemd user unit). One week of hourly snapshots are retained by default.

### New machine

```sh
# HTTPS, not SSH: a fresh machine has no key registered with GitHub yet, and
# 1Password is not set up at this point either. Switch the remote afterwards.
chezmoi init --apply https://github.com/prosac/dotfiles.git
chezmoi git -- remote set-url origin git@github.com:prosac/dotfiles.git   # once a key exists
mise run ch:hooks                 # install pre-commit hook in the cloned source
```

Then follow `bootstrap/SETUP.md` for the per-machine privileged setup (sudoers + snapshot timer + FIDO2 + sleep hooks). `README.md` carries the same sequence as a front-door quick start.

`chezmoi init` prompts for any personal values (name, email, machine-class, password-manager, mail-setup).

### Sync (multi-machine, same user)

```sh
mise run ch:sync                  # pull + apply
```

## Source file naming

| Prefix / suffix          | Target effect                          |
|--------------------------|----------------------------------------|
| `dot_X`                  | `.X` in target                         |
| `executable_X`           | `chmod +x` on target                   |
| `private_X`              | `chmod 600` on target                  |
| `run_once_X.sh`          | runs once per machine                  |
| `run_onchange_X.sh`      | runs when content hash changes         |
| `*.tmpl`                 | rendered as Go template at apply time  |

Example: `dot_config/waybar/config.jsonc.tmpl` → `~/.config/waybar/config.jsonc`, template-rendered.

## Mise tasks

All global (defined in `~/.config/mise/config.toml`, reachable from any cwd).

| Task                       | Does                                                              |
|----------------------------|-------------------------------------------------------------------|
| `ch:status`                | show drift                                                        |
| `ch:diff`                  | show pending changes                                              |
| `ch:apply`                 | source → target                                                   |
| `ch:readd`                 | target → source                                                   |
| `ch:managed` / `ch:unmanaged` | list managed / unmanaged files in target                       |
| `ch:cd`                    | print source path                                                 |
| `ch:git -- <args>`         | run git in source                                                 |
| `ch:sync`                  | pull + apply                                                      |
| `ch:push -- "msg"`         | stage all source changes, commit, push                            |
| `ch:scan`                  | gitleaks full scan                                                |
| `ch:hooks`                 | install pre-commit in source                                      |
| `dots:snap`                | take a btrfs snapshot now                                         |
| `dots:snaps`               | list snapshots                                                    |
| `dots:latest`              | print path to most recent snapshot                                |
| `dots:review [-- name]`    | bucketed diff against latest (or specified) snapshot              |
| `bootstrap:sudoers`        | install `/etc/sudoers.d/dotsnap` (one-time per machine)           |

Grows as workflows land.

## Conventions

- **Public repo** — no secret material, ever. Not in files, not in commit messages, not in commented-out example lines. Gitleaks pre-commit hook enforces this on every commit.
- **Templating policy — prefer native expansion.** When the target file format expands `$HOME`, `~`, or similar at runtime, use that. Reach for `{{ .chezmoi.homeDir }}` only when the format can't:
  - Shell files (`.zshrc`, `.zprofile`, `.profile`) → `$HOME`
  - Hyprland config → `~` (Hyprland expands it natively)
  - Waybar `exec` field → `$HOME` works (goes through `popen`)
  - Waybar `on-click` field → **must** use `{{ .chezmoi.homeDir }}` — GLib `g_spawn_command_line_async` does not expand env vars
  - JSON, TOML without env support, sudoers, etc. → chezmoi template
- **No hardcoded home paths.** Never `/home/<user>` in any committed file.
- **Per-machine files** go into `.chezmoiignore` (e.g. `monitors.conf`, `workspaces.conf` — managed by nwg-displays per host; `.config/systemd/user/*.wants` — systemd's enable state).
- **Identity** (name, email) comes from `chezmoi init` prompts, stored in local `~/.config/chezmoi/chezmoi.toml` (never committed). *Stage 3.*
- **Per-machine opt-ins** also live in those prompts and gate optional stacks. Today: `passwordManager` (`1password`/`bitwarden`/`none`) — only `1password` enables SSH-signed commits in `.gitconfig`; `mailSetup` (bool, default `false`) — gates the notmuch + lieer Gmail stack (Doom `:email notmuch`, `.notmuch-config`, `mail-sync` scripts, systemd timer, lieer venv installer, mail dnf packages). Re-prompt by deleting the relevant line from `~/.config/chezmoi/chezmoi.toml` and re-running `chezmoi init`.
- **Repo-only files** (README.md, PLAYBOOK.md, bootstrap/) live at source root and are listed in `.chezmoiignore` so they aren't applied to `~`.
- **One commit ≈ one logical change.** Don't mix drift-capture and feature additions.

## Adding a new file

```sh
chezmoi add ~/.config/foo/bar.conf               # plain (auto-detects executable bit)
chezmoi add --template ~/.config/foo/bar.conf    # promote to .tmpl
```

## Templating

Common built-ins:

```go-template
{{ .chezmoi.homeDir }}       → /home/jo
{{ .chezmoi.username }}      → jo
{{ .chezmoi.hostname }}      → fedora-2
{{ .chezmoi.os }}            → linux
{{ .chezmoi.osRelease.id }}  → fedora
```

Render-test a string:

```sh
chezmoi execute-template '{{ .chezmoi.homeDir }}'
```

Render-test a file (what `apply` would write):

```sh
chezmoi cat ~/.zshrc
```

## Troubleshooting

- **`MM` status** — both sides changed. Pick: `chezmoi apply <path>` (source wins) or `chezmoi re-add <path>` (target wins). No merge.
- **Edited source, ran `re-add`, lost the edit** — `re-add` is target → source. Use `apply` after editing source. See *Direction discipline* above.
- **Template error on apply** — `chezmoi apply -v` shows the failing file.
- **Rename** — do it in source with `git mv old new` so history is preserved.
- **Pre-commit hook blocks a commit** — inspect with `gitleaks git --staged --verbose`. Fix the leak; never `--no-verify`.
- **Pull fails with local source drift** — run `chezmoi re-add` first to capture live edits; commit; then `git pull --rebase`.
- **`apply` prompts for confirmation in a non-TTY context** — target was edited and source would overwrite. Run `re-add` first to capture the target edit, then continue.

## What's deliberately NOT in this repo

- `~/.ssh/`, `~/.gnupg/`, any key or token material.
- Browser profiles (`~/.mozilla/`, `~/.config/{Code,chromium,BraveSoftware}/`).
- Caches, histories (`.zsh_history`, `.bash_history`, `~/.cache/`).
- Monitor layouts / workspaces (per-machine, nwg-displays-managed).
- chezmoi's local state (`~/.config/chezmoi/chezmoistate.boltdb`).
- Anything listed in `.chezmoiignore`.

## One-time bootstrap steps

Some things `chezmoi apply` cannot do on its own. Run these once per machine.

### Walker + Elephant (replaces fuzzel)

`chezmoi apply` installs walker + elephant. The path it takes branches on the host's Fedora version:

- **F43+** — installed straight from the `errornointernet/walker` COPR.
- **F42** — that COPR has no F42 chroot, so the install script rebuilds walker + elephant SRPMs locally. Pulls in a Rust/GTK4 + Go build toolchain (`.chezmoidata/packages.yaml` → `dnfF42`) and runs the rebuild block in `run_onchange_after_install-packages.sh.tmpl`.

The selection is automatic via `.chezmoi.osRelease.versionID`; the same source state works on both versions.

After install, the Elephant systemd unit needs enabling and the leftover fuzzel state needs cleaning:

```sh
systemctl --user enable --now elephant.service
rm -rf ~/.config/fuzzel               # orphan from fuzzel removal
sudo dnf -y remove fuzzel             # only after walker is verified working
hyprctl reload                        # pick up `$menu = walker`
```

### DMS (DankMaterialShell) session — optional sandbox

A third session entry that runs the *same* Hyprland compositor and config as the default session, but replaces the whole shell — bar, notifications, OSD, polkit agent, launcher, **and the lock screen and idle daemon** — with a single DankMaterialShell Quickshell process. Nothing is mixed in: hypridle is masked, and hyprlock is then never launched (`hyprlock.service` is `static`, so hypridle's `lock_cmd` was its only trigger).

```sh
mise run bootstrap:dms-session        # one-time: installs /usr/share/wayland-sessions/hyprland-dms.desktop
```

Then log out and pick "Hyprland (DMS)" at GDM. To remove: `sudo rm /usr/share/wayland-sessions/hyprland-dms.desktop`.

**How it stays isolated.** A second *Hyprland* session cannot announce a distinct `XDG_CURRENT_DESKTOP` (it must stay `Hyprland` or xdg-desktop-portal-hyprland stops matching), so it cannot use the `ConditionEnvironment=` lever the niri session uses. Instead `~/.local/bin/hyprland-dms` masks the units DMS supersedes for the lifetime of the session.

⚠️ **Not with `systemctl --user --runtime mask`.** That writes into `/run/user/$UID/systemd/user/`, which is rank 8 in the user unit search path — *below* `~/.config/systemd/user/` at rank 5, where every one of these units actually lives. The real unit file shadows the symlink, so the mask is a **silent no-op**: nothing errors, the unit stays `enabled`, and it starts anyway. That produced a session with waybar on top of the DMS bar and two notification daemons. The masks go into `/run/user/$UID/systemd/user.control/` (rank 2) instead.

**Teardown does not rely on the manager dying.** The masks are global — systemd has no per-session masking — so the old design substituted *short lifetime* for scoping, and `loginctl enable-linger` (which a user-scoped rootless k3s is a real reason to want) would have removed that substitute and left the *default* session with no bar, no notifications, no polkit agent and no lock. `dms-session-cleanup.service` is `PartOf=graphical-session.target` and unmasks from its `ExecStop=`, so cleanup runs at every logout regardless of lingering, and regardless of whether the wrapper's EXIT trap fired (a SIGKILL skips it).

Verify a running session with `mise run check:dms-session`.

⚠️ **This breaks if lingering is ever enabled** (`loginctl enable-linger`, e.g. for rootless k3s): a user manager that outlives logout keeps `waybar.service` masked, and the *default* session then starts with no bar.

**Launcher/panel keys** are re-pointed at DMS by `dms-binds.service` → `~/.local/bin/dms-binds`, which runs `hyprctl keyword unbind/bind` inside the running compositor — so `hyprland.conf` is not edited and the default session's config *and code path* stay byte-identical. Super+D / Super+Space → DMS spotlight; plus Super+N notifications, Super+A control-center, Super+X powermenu, Super+Shift+V clipboard, Super+/ keybind cheatsheet. It refuses to run unless `dms.service` is active.

**Locking, and the FIDO2 stick.** `Super+Escape` still runs `loginctl lock-session` (hyprland.conf is untouched); logind's `Lock` signal now reaches DMS, which owns the lock screen here. The stick still unlocks with a **bare touch, no extra keypress**: rather than DMS's native security-key mode — where the key is a separate factor you start on demand with the passkey button — DMS is pointed at `/etc/pam.d/dms-fido2` as its *primary* PAM stack (`pam_u2f sufficient` + `pam_unix required`, the same effective stack as `hyprlock-fido2`). `lockPamInlineU2f` tells DMS that stack already provides the key, so it suppresses its own factor UI and the key is armed the instant the screen locks.

```sh
mise run bootstrap:pam-dms            # installs /etc/pam.d/dms-fido2 and asserts it is readable
```

⚠️ **That has a silent failure mode.** DMS only honours `lockPamPath` if it can *read* the file; otherwise it falls back down its chain to the `login` service — i.e. straight into the `pam_sss` double-prompt trap that this file exists to avoid, with nothing shown on screen. A missing file does not lock you out, it degrades you to the old three-Enter behaviour. The mise task above asserts both readability and that `settings.json` points at the right path.

**Idle** is DMS's `IdleService`, seeded to mirror the hypridle timings it replaces (lock at 600s, monitors off 30s later, lock-before-suspend). Timeouts are in **seconds**. `acSuspendTimeout` stays `0` on purpose — idle must never suspend this machine. The one thing not carried over is hypridle's 5-minute `brightnessctl` dim: DMS has no dim stage, and its 5s fade-to-lock is the nearest pre-lock warning.

Everything above is seeded once into `~/.config/DankMaterialShell/settings.json` (a `create_` file — DMS owns it at runtime). See the header comment in `dot_config/DankMaterialShell/create_settings.json.tmpl` for the full reasoning on every key.

**`matugen` is excluded at the dnf level** (`.chezmoidata/packages.yaml` → `packages.dnfExclude`). DMS only `Recommends:` it, but all of its template flags default ON and target exactly what `toggle-color-scheme` owns (GTK, Hyprland, ghostty, Qt6ct, Emacs) — several of them writing chezmoi-managed files, which would drift the *default* session too. `toggle-color-scheme` instead gained a guarded `sync_dms` arm so DMS follows the same switch.

`hypridle.conf` itself is never edited — it is shared with the default and niri sessions, which keep their 5-minute dim, 10-minute hyprlock and resume handling exactly as before. Masking the unit is what takes it out of this session.

**Wallpaper is DMS's in this session.** `awww.service` and `waypaper.service` are masked like the other superseded units, and Super+W is re-pointed at `dms ipc call dash toggle wallpaper` by `dms-binds`. Both halves are required: a mask alone cannot stop waypaper, which starts a daemon itself whenever `pgrep awww-daemon` comes back empty, so one keypress would put an unmanaged daemon on top of DMS's layer.

This used to say wallpaper was left alone because it is "entangled with `toggle-color-scheme`". It is not — `toggle-color-scheme` never references awww/swww/waypaper, and waypaper's `post_command` is empty. The entanglement that mattered was matugen's, and that is already handled by the dnf exclude plus the DMS template flags.

## Stages

- [x] **Stage 1** — Drift reconciliation, tooling (mise, gitleaks pre-commit), templating policy.
- [x] **Stage 2** — Session artifacts ingested (systemd user units, `~/.local/bin` scripts, desktop overrides). Btrfs snapshot infrastructure + sudoers bootstrap. `dotreview` tool.
- [x] **Stage 3** — `.chezmoi.toml.tmpl` prompts (name, email, machineClass). Templated `.gitconfig` + hyprland input device block (`{{ if eq .machineClass "laptop" }}`).
- [x] **Stage 4** — `run_onchange_after_install-packages.sh.tmpl` driven by `.chezmoidata/packages.yaml` (COPRs + dnf + mise/starship curl-installers).
