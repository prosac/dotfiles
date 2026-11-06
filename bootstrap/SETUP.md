# Bootstrap — one-time per-machine setup

## 0. Install chezmoi (chicken-and-egg)

Chezmoi has to exist before it can clone its own source. The official one-liner:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/bin
```

Then add `~/bin` to `$PATH` if it isn't already (it is, after Step 1 deploys `.zshrc`).

```sh
# HTTPS, not SSH: this machine has no key registered with GitHub yet.
chezmoi init --apply https://github.com/prosac/dotfiles.git
```

On my own machines, once 1Password is working (Step 2a), I point the remote at SSH:
`chezmoi git -- remote set-url origin git@github.com:prosac/dotfiles.git`. This repo
takes no outside pushes or PRs. Anyone else should fork it or copy pieces.

`init` prompts for `name`, `email`, `machineClass` (laptop/desktop), `passwordManager` (`1password`/`bitwarden`/`none` — only `1password` turns commit signing on in `.gitconfig`; with `bitwarden` its SSH agent signs once signing is enabled in `~/.config/git/local.gitconfig`), and `mailSetup` (bool, default `false` — set `true` to deploy the notmuch + lieer Gmail stack: scripts, systemd timer, Doom `:email notmuch`, lieer venv, mail dnf packages). On `apply`, the `run_onchange_after_install-packages.sh.tmpl` script runs (see Step 4 below) — interactive `sudo` will be required.

### 0a. Signing key (only on `passwordManager = 1password`)

`.gitconfig` sets `commit.gpgsign = true` but deliberately does **not** carry
`user.signingKey` — this repo is public, and a hardcoded key made every clone
come preconfigured to sign as someone else. Put it in the untracked local file
that `.gitconfig` already `[include]`s at the end (so it wins):

```sh
mkdir -p ~/.config/git
cat > ~/.config/git/local.gitconfig <<'EOF'
[user]
	signingKey = ssh-ed25519 AAAA... you@example.com
EOF

# Same key again, for verifying signatures (gpg.ssh.allowedSignersFile):
printf '%s %s\n' you@example.com 'ssh-ed25519 AAAA...' > ~/.config/git/allowed-signers
```

The public key is in 1Password next to the private one (`op read` the item, or
copy it from `github.com/<you>.keys`). Skip this and the first commit on the
machine fails with `user.signingkey needs to be set`.

## 1. Install pre-commit hook in the cloned source

```sh
mise run ch:hooks
```

## 2. Btrfs dotfile snapshots (optional but recommended)

**Requires `/home` on btrfs.** That is the Fedora default for a fresh install, but a
machine upgraded across many releases may well still be on ext4 — check first:

```sh
findmnt -no FSTYPE --target /home     # btrfs -> do this section; anything else -> skip it
```

**On a non-btrfs `/home`, skip this whole section.** Nothing else depends on it, and
you do not need to disable anything: `dotsnap` checks the filesystem itself and exits
0 with a message, so `dotsnap.timer` (which `enable-session-services.sh` enables
unconditionally) is a harmless no-op. That check exists precisely because the failure
mode was bad — `dotsnap.service` carries `OnFailure=notify-failure@%n.service` and the
timer is hourly, so a snapshot that merely *failed* on ext4 would put a desktop
notification on screen every hour, forever. Note `ConditionPathIsMountPoint=/home` in
the unit does **not** protect you here: `/home` is very often its own mount on ext4 too.

```sh
# Create the snapshot tree via a tmpfiles.d drop-in: /home/.snapshots as a btrfs
# subvolume (so it is excluded from snapshots of /home) + a user-owned hourly/.
# systemd recreates it every boot, so this cannot be silently missing later.
mise run bootstrap:tmpfiles

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

`dotsnap.service` carries `OnFailure=notify-failure@%n.service`, so a failed run
raises a desktop notification instead of only landing in the journal. That
template unit is reusable — add the same `OnFailure=` line to any user unit whose
silent failure would matter.

## 2a. FIDO2 login (pam_u2f)

```sh
mise run bootstrap:pam-u2f        # pam_u2f.conf, THEN authselect with-pam-u2f
mise run bootstrap:u2f-enroll     # once per key, with that key plugged in
mise run check:fido2              # verify the whole chain
```

**Two packages, and the split is the trap.** Fedora ships the module in `pam-u2f`
but the enrolment tool in a separate `pamu2fcfg`. Both are in
`.chezmoidata/packages.yaml`; a machine provisioned before 2026-10-01 has neither.

⚠️ **A missing module fails SILENTLY.** `pam_u2f` is `sufficient` in every stack it
appears in, so an absent `.so` does not fail authentication — it falls through to
fingerprint or password. The only evidence is one journal line per unlock:

```
PAM unable to dlopen(/usr/lib64/security/pam_u2f.so)
```

The second laptop ran exactly that way from its F44 rebuild until 2026-10-01 — 96 such lines in
the final week — with `/etc/pam.d/dms-fido2` faithfully referencing a module that
was not on the machine. `bootstrap:pam-u2f` now refuses to run rather than
configure a stack around an absent module.

**Order is load-bearing, which is why one task does both halves.**
`/etc/security/pam_u2f.conf` must exist *before* the PAM line does:
`userverification = 1` lives only there, and with the line present but the file
missing, pam_u2f falls back to the authenticator's default — a bare touch, so mere
possession of the key is enough.

⚠️ **authselect silently drops hand-added module options.** `/etc/pam.d/system-auth`
is generated — never hand-edit it. `with-pam-u2f` emits a fixed `pam_u2f.so cue`, so
`userverification` has to live in `/etc/security/pam_u2f.conf` or the next
authselect run reverts it. That is what happened on 2026-08-05.

### The profile is per machine, keyed to `fingerprintReader`

There is no single correct answer here, and until 2026-10-01 this section gave the
no-reader answer as though there were.

| `fingerprintReader` | authselect features | resulting auth order |
|---|---|---|
| `false` (e.g. bum) | `with-pam-u2f` | u2f → password; the key arms instantly |
| `true` (e.g. a laptop with a reader) | `with-pam-u2f` + `with-fingerprint` | fprintd → u2f → password |

⚠️ **Do not enable `with-fingerprint` on a machine with no fprintd device.** It
inserts `pam_fprintd.so` *ahead* of `pam_u2f.so`, so every authentication
dbus-activates `fprintd`, enumerates nothing, fails (plus the
`pam_faildelay.so delay=2000000` two-second penalty), and only then reaches the
FIDO2 key. Symptom: the first Enter appears to do nothing, the second reports a
failed login, and only then does the key light up.

On a machine that *does* have one, `with-fingerprint` is correct: the reader becomes
the fast path and the key the fallback — the same trade-off, and the same ordering,
that `bootstrap/pam/dms-fido2` chose deliberately for the lock screen.
`bootstrap:pam-u2f` reports a mismatch between the flag and the live profile but
never changes `with-fingerprint` itself, since that alters every login path and so
stays an explicit decision.

**Neither stick is a fprintd device.** The VeriMark Guard's sensor is on-key FIDO2
user verification (`fprintd-list` shows "No devices available"), and the TrustKey
G310 does UV on-key too — enrolling it with `-V` records `+verification` and asks for
no PIN, despite its `clientPin` option. Only a builtin reader (e.g. a Goodix MOC) is
a fprintd device.

### Enrolment is deliberately NOT managed

The authfile holds per-machine, per-key credentials produced by touching hardware:
it cannot be rendered from a template, and this repo is **public** — key handles are
not secrets, but they are machine fingerprints and do not belong here. chezmoi
manages the packages, `pam_u2f.conf` and the PAM stacks; `bootstrap:u2f-enroll` is
the reproducible path to the credential, which stays local.

The format is **one line per user**, credentials colon-separated:

```
<user>:<handle1>,<key1>,<type1>,<opts1>:<handle2>,<key2>,<type2>,<opts2>:...
```

so an additional key must *extend* that line. `pamu2fcfg` emits no trailing
newline, which is what makes `pamu2fcfg -n` appendable inline; a line that begins
with `:` matches no user and is ignored in silence. `bootstrap:u2f-enroll` handles
that, backs the file up first, and validates every credential carries
`+verification` before replacing it — so a half-finished registration cannot cost
you the keys you already had.

## 2b. USB autosuspend exclusions + power management

```sh
mise run bootstrap:udev
```

Installs `/etc/udev/rules.d/50-usb-no-autosuspend.rules`, holding
`power/control=on` for the FIDO2 key (`047d:8055`) and the dock hubs
(`05e3:0610`, `05e3:0620`), then re-triggers it so no reboot is needed.

⚠️ **Do not install TLP.** These exclusions used to live in `USB_DENYLIST` in
`/etc/tlp.conf`, which silently protected nothing: `power-profiles-daemon`
declares `Conflicts=tlp.service`, so systemd skipped `tlp.service`
(`ConditionResult=no`, no journal entry, unit still showing `enabled`) from
2025-12-31 onward. TLP is also `preset=disabled` on Fedora and cannot manage this
laptop's charge limiting anyway — that lives at
`/sys/devices/platform/tuxedo_keyboard/charging_profile`, not the standard sysfs,
and TUXEDO Control Center (`tccd`) owns it.

## 2c. Wacom tablet / OpenTabletDriver

```sh
mise run bootstrap:opentabletdriver
```

Installs `/etc/udev/rules.d/70-opentabletdriver.rules` and re-triggers it, then
reports whether each Wacom HID node actually carries an ACL for `$USER`.

⚠️ **The `70-` prefix is load-bearing — never renumber this above 73.**
`/usr/lib/udev/rules.d/73-seat-late.rules` holds the only line that converts a
`uaccess` tag into a real ACL (`TAG=="uaccess", … RUN{builtin}+="uaccess"`).
Rules run in filename order, so a `99-*` file sets the tag after the builtin
that consumes it has already run. **The failure looks like success:**
`udevadm info` cheerfully reports `TAGS=:uaccess:seat:` on the device while
`getfacl` shows no user entry and the node stays `root:root 0600`. Upstream
OTD ships its rules as `99-*`, which walks straight into this. Always verify
with `getfacl /dev/hidraw*`, never with `TAGS`.

⚠️ **The Flathub OpenTabletDriver ships no udev rules** — its tree contains zero
`.rules` files, and Fedora has no OTD package to supply them. Without this rule
the daemon runs unprivileged against a `root:root 0600` `/dev/hidraw*` node,
cannot open it, and the GUI reports *no tablet detected* while the tablet keeps
working normally through the kernel `wacom` driver. That split — hardware works,
app sees nothing — is the whole symptom. The Flatpak's `devices=all` is a red
herring: it lets the sandbox reach `/dev`, but cannot grant permissions the user
does not already hold.

The rule does two things. It tags Wacom hidraw + USB nodes `uaccess` so the seat
user gets an ACL, and it sets `LIBINPUT_IGNORE_DEVICE=1` on the Wacom *input*
devices so the kernel driver's events stop reaching the compositor. The second
half is required because OTD never unbinds the kernel driver — it reads the same
device in parallel and emits its own pointer via `/dev/uinput`, so without the
mute both drivers move the cursor.

⚠️ **Consequence: the tablet is inert unless the OTD daemon runs.** That is what
`opentabletdriver.service` (user unit, `graphical-session.target`) is for; it is
enabled by `run_onchange_after_enable-session-services.sh` whenever the Flatpak
is installed. If the pen ever goes dead, check that service first.

Power management stack on Fedora 43 — pick the native one and only that one:

```sh
sudo dnf swap power-profiles-daemon tuned-ppd
sudo systemctl enable --now tuned tuned-ppd
```

`tuned` + `tuned-ppd` is Fedora's default since F41; `tuned-ppd` re-implements
the `org.freedesktop.UPower.PowerProfiles` / `net.hadess.PowerProfiles` D-Bus API
so desktop power-profile switching keeps working. `power-profiles-daemon` and
`tuned-ppd` both provide the virtual `ppd-service`, so exactly one can be
installed.

## 2c. Lid close → plain suspend (+ hibernate prerequisites)

```sh
mise run bootstrap:sleep
```

Makes lid-close a plain `suspend` on battery and AC, sets up everything
hibernation needs (swap subvolume labels, resume args), and sets UPower's
critical-battery action to `Hibernate` at 4%. Hibernation itself is **manual**:
`Super+Ctrl+Escape` → `~/.local/bin/hibernate-now`.

⚠️ **Do not make lid-close escalate to hibernate.** It was tried
(`HandleLidSwitch=suspend-then-hibernate`, 2026-08-11) and reversed the next day.
On 2026-08-12 the 60-minute timer woke the machine **inside a closed backpack**,
the hibernate wedged mid-freeze, no image was ever written, and it sat at full
power for 44 minutes with `tccd` — fan control, which is user space — frozen
along with everything else. It came out too hot to hold. The structural problem
is not the wedge: the design wakes a sealed, unattended laptop to run the most
fragile operation in the kernel with every watchdog frozen and nobody watching.
Note that hibernate had been tested successfully twice that day, both times from
an awake desk session — which does **not** exercise the escalation path.
Full incident: `~/Documents/docs/suspend-then-hibernate-setup.md`.

⚠️ **This also turns zram OFF, and that is deliberate.** zram-generator gives
zram swap priority 100 against the disk swapfile's -1, so it is first in line
for every swap-out — including the reclaim that hibernation's image
preallocation depends on, where swapping into RAM-backed swap frees no RAM.
Measured on 2026-08-12 with the container workload up: `pswpout 0`, zram DATA
4 KiB, memory-pressure total 38 µs, 51 GiB available. It was doing nothing, and
its four real use cases (low RAM, slow storage, no disk swap, SSD write-wear)
none of them apply to 61 GiB + NVMe + a 64 GiB swapfile. Revert by deleting
`/etc/systemd/zram-generator.conf` and running `systemctl daemon-reload`.
Details: `~/Documents/docs/zram-swap-tuning.md`.

⚠️ **This laptop has no deep/S3 state, so a closed lid still goes flat.**
`/sys/power/mem_sleep` reads `[s2idle]` with no alternative, so a plain suspend
keeps RAM powered at ~1 W — a flat 67.8 Wh battery in under three days. Three
long weekends were lost that way (2026-07-23, 2026-07-31, 2026-08-06); each of
those boots' journals ends on `PM: suspend entry (s2idle)` with no resume line.
This cost is **accepted**: a flat battery loses unsaved work, a wedged hibernate
in a bag cooks the hardware. Hibernate deliberately before long storage.

⚠️ **The swap subvolume needs an SELinux label, and it is not obvious.**
`btrfs subvolume create` leaves the new subvolume's root inode with no security
xattr, so `/swap` comes up `unlabeled_t`. `systemd-logind` is then denied
`search` on it and hibernation fails with a bare `Call to Hibernate failed:
Access denied` — **with no polkit log entry**, which sends you hunting for a
permissions problem that does not exist. The AVC is the only evidence:

```sh
journalctl -b 0 | grep 'avc:.*denied.*swap'
```

Only the **file** is `swapfile_t`. Fedora declares `swapfile_t` as a file type,
so labelling the **directory** `swapfile_t` merely moves the identical denial to
a new `tcontext`. The directory needs an ordinary traversable type (`root_t`).
Do **not** accept `audit2allow`'s suggestion here — it proposes
`allow systemd_logind_t unlabeled_t:dir search`, granting logind search on every
unlabeled directory on the system to work around one missing label.

The `semanage fcontext` rules live in the SELinux policy store, **not** in
chezmoi, which is why the task reapplies them rather than relying on a dotfile.

Verify hibernation genuinely happened rather than trusting a zero exit — a
successful cycle **preserves boot_id and uptime** (the restored image carries
the kernel's own), and the pre-snapshot kernel's `Creating image` / `Wrote
image` lines can never appear in the restored log. The real proof:

```sh
journalctl -b 0 | grep -E 'HibernateLocation|hibernation (entry|exit)'
```

`efivarfs: removing variable HibernateLocation-*` is written only after a
successful resume.

## 3. Baseline packages

Already handled automatically by `run_onchange_after_install-packages.sh.tmpl` during the first `chezmoi apply` (Step 0). To re-trigger it manually after editing `.chezmoidata/packages.yaml`:

```sh
mise run ch:apply
```

The script enables COPRs, runs `dnf install`, and curl-installs `mise` if absent. All steps idempotent.

`starship` is **not** curl-installed any more (it used to be piped from
`starship.rs/install.sh` into a **root** shell, unattended). It is declared in the
`[tools]` block of `~/.config/mise/config.toml` and installed by the script via
`mise install starship`, which resolves it through aqua — checksum-verified, into
`~/.local/share/mise`, with no root anywhere in the path.

## 4. User services — mostly automatic

⚠️ **Do not hand-enable the session units.** `run_onchange_after_enable-session-services.sh`
runs as part of `chezmoi apply` and already enables waybar, awww + waypaper (wallpaper),
hypridle + hypridle-niri, nm-applet, mate-polkit, elephant, swayosd, wayland-noti,
opentabletdriver, kando and `dotsnap.timer` — each guarded so a missing binary is
skipped rather than fatal. Enabling them by hand is at best redundant.

`hyprpaper` is **not** part of this setup. The wallpaper stack is `awww.service`
(daemon) + `waypaper.service` (restore-on-login), driven by waypaper's native `awww`
backend. Enabling hyprpaper alongside it puts two wallpaper daemons on one output.

Left for you, because they are genuinely per-machine:

```sh
systemctl --user enable --now wired.service   # notification daemon, default session only
# hyprlock.service — invoked on demand by hypridle, no enable needed
```

To check what actually came up in a session: `mise run check:dms-session` (DMS), or
`systemctl --user list-units --state=failed` (any session).
