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
chezmoi init --apply git@github.com:prosac/dotfiles.git
mise run ch:hooks                 # install pre-commit hook in the cloned source
```

Then follow `bootstrap/SETUP.md` for the per-machine privileged setup (sudoers + snapshot timer + enabling user services).

`chezmoi init` prompts for any personal values (Stage 3: name, email, machine-class).

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

## Stages

- [x] **Stage 1** — Drift reconciliation, tooling (mise, gitleaks pre-commit), templating policy.
- [x] **Stage 2** — Session artifacts ingested (systemd user units, `~/.local/bin` scripts, desktop overrides). Btrfs snapshot infrastructure + sudoers bootstrap. `dotreview` tool.
- [ ] **Stage 3** — `.chezmoi.toml.tmpl` prompts (name, email, machine-class, mouse-device). Template `.gitconfig` + hyprland input device block.
- [ ] **Stage 4** — `run_onchange_install-packages.sh.tmpl` for dnf + COPR bootstrap.
