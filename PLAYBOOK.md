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

## Workflow loops

### Day-to-day

1. Edit live config directly (e.g. `~/.config/hypr/hyprland.conf`).
2. `mise run ch:status` — see what drifted.
3. `mise run ch:diff` — review the delta.
4. `mise run ch:readd` — capture into source.
5. `mise run ch:push -- "hyprland: add foo binding"` — commit + push (pre-commit hook runs gitleaks).

Direct `chezmoi` commands work too; mise tasks are shortcuts + aide-memoire.

### New machine

```sh
chezmoi init --apply git@github.com:prosac/dotfiles.git
mise run ch:hooks                 # install pre-commit hook in the cloned source
# mise run bootstrap:sudoers      # Stage 2 (btrfs snapshot sudoers drop-in)
```

`chezmoi init` prompts for any personal values (wired in Stage 3: name, email, machine-class).

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

| Task                   | Does                                                    |
|------------------------|---------------------------------------------------------|
| `ch:status`            | show drift                                              |
| `ch:diff`              | show pending changes                                    |
| `ch:apply`             | source → target                                         |
| `ch:readd`             | target → source                                         |
| `ch:managed`           | list managed files                                      |
| `ch:unmanaged`         | list unmanaged files in target                          |
| `ch:cd`                | print source path                                       |
| `ch:git -- <args>`     | run git in source                                       |
| `ch:sync`              | pull + apply                                            |
| `ch:push -- "msg"`     | commit + push                                           |
| `ch:scan`              | gitleaks full scan                                      |
| `ch:hooks`             | install pre-commit in source                            |

Grows as workflows land.

## Conventions

- **Public repo** — no secret material, ever. Not in files, not in commit messages, not in commented-out example lines. Gitleaks pre-commit hook enforces this on every commit.
- **No hardcoded home paths** — use `{{ .chezmoi.homeDir }}` (template) or `$HOME` (shell). Never `/home/<user>`.
- **Per-machine files** go into `.chezmoiignore`, not source (e.g. `monitors.conf`, `workspaces.conf` — managed by nwg-displays per host).
- **Identity** (name, email) comes from `chezmoi init` prompts, stored in local `~/.config/chezmoi/chezmoi.toml` (never committed). *Stage 3.*
- **One commit ≈ one logical change.** Don't mix drift-capture and feature additions.

## Adding a new file

```sh
chezmoi add ~/.config/foo/bar.conf               # plain
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
- **Template error on apply** — `chezmoi apply -v` shows the failing file.
- **Rename** — do it in source with `git mv old new` so history is preserved.
- **Pre-commit hook blocks a commit** — inspect with `gitleaks git --staged --verbose`. Fix the leak; never `--no-verify`.
- **Pull fails with local source drift** — run `chezmoi re-add` first to capture live edits; commit; then `git pull --rebase`.

## What's deliberately NOT in this repo

- `~/.ssh/`, `~/.gnupg/`, any key or token material.
- Browser profiles (`~/.mozilla/`, `~/.config/{Code,chromium,BraveSoftware}/`).
- Caches, histories (`.zsh_history`, `.bash_history`, `~/.cache/`).
- Monitor layouts / workspaces (per-machine, nwg-displays-managed).
- Anything listed in `.chezmoiignore`.

## Stages

- [x] **Stage 1** — Drift reconciliation, tooling (mise, gitleaks pre-commit), homeDir templating.
- [ ] **Stage 2** — Ingest session artifacts (systemd user units, `~/.local/bin` scripts, desktop overrides). Btrfs snapshot infrastructure + sudoers bootstrap.
- [ ] **Stage 3** — `.chezmoi.toml.tmpl` prompts (name, email, machine-class). Template `.gitconfig` + hyprland input device block.
- [ ] **Stage 4** — `run_onchange_install-packages.sh.tmpl` for dnf + COPR bootstrap.
