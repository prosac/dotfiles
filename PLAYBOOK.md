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
| `check:quickshell`         | does `qs` still load against the installed Qt?                    |
| `bootstrap:quickshell-rebuild` | rebuild quickshell after a qt6 update broke the DMS session   |
| `bootstrap:flatpak-mount-ordering` | order `flatpak-add-fedora-repos` after the disk holding `/var/lib/flatpak` |

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
- **Logged into "Hyprland (DMS)" and there is no bar / no notifications / no lock** — a Qt update probably orphaned quickshell's private symbols. `mise run check:quickshell`, then `mise run bootstrap:quickshell-rebuild`. See *quickshell is ABI-pinned to Qt*.
- **A user unit fails in a restart loop after a machine migration** — `~/.config/systemd/user/*.wants/` is per-machine state that travels with `~/.config`, so a unit can arrive already enabled on a host that never had its dependency. The `enable_if_exists` guards in `run_onchange_after_enable-session-services.sh` only run at apply time; the durable fix is an `ExecCondition=` in the unit itself, as `opentabletdriver.service` has.
- **Hyprland's on-screen Error Overlay greets a new machine** — run `hyprctl configerrors`, which is the same list without the red box. Both known causes are things chezmoi deliberately does not manage, so they only ever bite a fresh host: `source= globbing error` is the missing per-machine `monitors.conf` (seeded now by `run_onchange_after_init-hypr-monitors.sh`; run `nwg-displays` for a real layout), and `Invalid dispatcher … "hyprtasking:toggle"` means the plugin is not loaded — `~/.local/bin/hyprtasking-rebuild` clones and builds it, and needs `hyprland-devel` at the *same version* as `hyprland`.
- **"Your system does not have hyprland-guiutils installed"** — a startup warning from Hyprland itself, not from anything in this repo, and separate from the Error Overlay. `hyprland-guiutils` (renamed upstream from `hyprland-qtutils`) ships `hyprland-dialog` and friends, which Hyprland shells out to for anything it cannot draw itself — the permission prompts most of all. `hyprland` only `Recommends:` it, so dnf never pulls it in. It is in `packages.yaml` now; `mise run ch:apply` installs it. Silencing it instead with `misc:disable_hyprland_guiutils_check = true` leaves those dialogs unable to appear.

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

⚠️ **That has two silent failure modes**, and the mise task checks for both.

*The file is missing or unreadable.* DMS only honours `lockPamPath` if it can *read* the file. Otherwise (dms 1.5.3) it runs `dms auth resolve-lock` and writes its own fallback stack to `~/.local/state/DankMaterialShell/pam/dankshell` — a copy of system-auth, so it carries both the `pam_sss` double prompt and the 2s `pam_faildelay` this file exists to avoid, and no `pam_u2f` at all. Nothing is shown on screen. A missing file does not lock you out, it degrades you to the old three-Enter behaviour. (Older versions fell back to the `login` service; the destination changed, the trap did not.)

*The file was installed under a session that was already running.* `customPamWatcher` in DMS's `Pam.qml` is a `FileView` with no `watchChanges`, and only `u2fConfigWatcher` is re-read per lock — so whether to use `lockPamPath` is decided **once**, when `dms.service` starts. Install the file into a live session and every check still passes, because the filesystem really is fine, while the lock screen keeps using the fallback until logout. Fix with `systemctl --user restart dms.service`. This only ever bites on the machine where you just discovered the file was missing — i.e. exactly when you most believe you have fixed it.

Which one is live is visible in the journal, and nowhere else:

```
dms[…]: Starting pam session … with config "dms-fido2" in dir "/etc/pam.d"          # healthy
dms[…]: Starting pam session … with config "dankshell" in dir "…/state/…/pam"       # degraded
```

**Idle** is DMS's `IdleService`, seeded to mirror the hypridle timings it replaces (lock at 600s, monitors off 30s later, lock-before-suspend). Timeouts are in **seconds**. `acSuspendTimeout` stays `0` on purpose — idle must never suspend this machine. The one thing not carried over is hypridle's 5-minute `brightnessctl` dim: DMS has no dim stage, and its 5s fade-to-lock is the nearest pre-lock warning.

Everything above is seeded once into `~/.config/DankMaterialShell/settings.json` (a `create_` file — DMS owns it at runtime). See the header comment in `dot_config/DankMaterialShell/create_settings.json.tmpl` for the full reasoning on every key.

**`matugen` is excluded at the dnf level** (`.chezmoidata/packages.yaml` → `packages.dnfExclude`). DMS only `Recommends:` it, but all of its template flags default ON and target exactly what `toggle-color-scheme` owns (GTK, Hyprland, ghostty, Qt6ct, Emacs) — several of them writing chezmoi-managed files, which would drift the *default* session too. `toggle-color-scheme` instead gained a guarded `sync_dms` arm so DMS follows the same switch.

`hypridle.conf` itself is never edited — it is shared with the default and niri sessions, which keep their 5-minute dim, 10-minute hyprlock and resume handling exactly as before. Masking the unit is what takes it out of this session.

**Wallpaper is DMS's in this session.** `awww.service` and `waypaper.service` are masked like the other superseded units, and Super+W is re-pointed at `dms ipc call dash toggle wallpaper` by `dms-binds`. Both halves are required: a mask alone cannot stop waypaper, which starts a daemon itself whenever `pgrep awww-daemon` comes back empty, so one keypress would put an unmanaged daemon on top of DMS's layer.

This used to say wallpaper was left alone because it is "entangled with `toggle-color-scheme`". It is not — `toggle-color-scheme` never references awww/swww/waypaper, and waypaper's `post_command` is empty. The entanglement that mattered was matugen's, and that is already handled by the dnf exclude plus the DMS template flags.

#### quickshell is ABI-pinned to Qt

⚠️ **A routine `dnf update` that touches only Qt can leave this session with no shell at all.** quickshell links Qt's *private* API. Those symbols carry a version tag (`Qt_6.11_PRIVATE_API`) but no stability promise, so a qt6-qtbase update *inside the same 6.11.x series* can orphan them:

```
qs: symbol lookup error: qs: undefined symbol:
  _ZN23QUntypedPropertyBindingC1EP23QPropertyBindingPrivate, version Qt_6.11_PRIVATE_API
```

That is exit 127, which takes `dms.service` with it. systemd retries 5 times in 8 seconds, hits the start limit and stops. Happened on 2026-09-02: `qt6-qtbase 6.11.2-2` landed at 10:36 and the 11:35 login had no bar, no notifications, no OSD, no tray, no polkit agent and no lock screen.

**Waiting for the COPR does not fix it.** `avengemedia/danklinux` rebuilds when it notices, not when Fedora ships Qt, and the rebuild usually carries the **same n-v-r** — so `dnf upgrade` sees nothing to do and the broken binary stays installed. There is no version to pin and no bump to wait for.

```sh
mise run check:quickshell             # does qs still load? (also prints what it was last built against)
mise run bootstrap:quickshell-rebuild # rebuild against the installed Qt + reinstall (sudo)
```

The rebuild reinstalls over the same n-v-r rather than tagging the result `.local`: a same-n-v-r `dnf reinstall` is one atomic rpm transaction, where an EVR bump would be an upgrade that could leave the machine with **no** quickshell if it failed halfway — and losing the shell is the thing being defended against. The cost is that `rpm -q` cannot tell you whether the installed build is the COPR one or yours, so `~/.cache/quickshell-rebuild/built-against.json` records the Qt versions it was built against instead.

**The session no longer dies from this.** `~/.local/bin/hyprland-dms` runs `quickshell-rebuild --check` *before* it masks anything. If `qs` cannot even print its version, the wrapper leaves the default shell stack alone and logs why to the journal (`journalctl --user -t hyprland-dms`), so you get an ordinary Hyprland session — waybar, wayland-noti, swayosd, nm-applet, mate-polkit, hypridle/hyprlock — instead of an empty screen. The check fails *open*: if the script is missing or unrunnable, DMS starts as before. Repair needs sudo, so it is deliberately never attempted at login — a GDM session entry point has nowhere to prompt for a password.

## Stages

- [x] **Stage 1** — Drift reconciliation, tooling (mise, gitleaks pre-commit), templating policy.
- [x] **Stage 2** — Session artifacts ingested (systemd user units, `~/.local/bin` scripts, desktop overrides). Btrfs snapshot infrastructure + sudoers bootstrap. `dotreview` tool.
- [x] **Stage 3** — `.chezmoi.toml.tmpl` prompts (name, email, machineClass). Templated `.gitconfig` + hyprland input device block (`{{ if eq .machineClass "laptop" }}`).
- [x] **Stage 4** — `run_onchange_after_install-packages.sh.tmpl` driven by `.chezmoidata/packages.yaml` (COPRs + dnf + mise/starship curl-installers).
