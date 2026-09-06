# Upgrading a Fedora release on these machines

Written after taking `yoga` from Fedora 42 (EOL) to 44 on 2026-09-05. The order below
is the order things actually went wrong in, which is why it is the order to work in.

The compositor stack is the risk, not Fedora. Fedora's own upgrade is boring and well
tested; what breaks is third-party repos that have no build for the target release.

---

## 0. Decide the target

    curl -s https://bodhi.fedoraproject.org/releases/F44 -H 'Accept: application/json' \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state"], d["eol"])'

`archived` means no security updates. Check the release you are ON and the one you are
going TO. **Skip a release whose EOL is close** — going to N+1 three months before its
EOL buys one quarter and a second upgrade.

## 1. Check third-party repos BEFORE anything else

This is the step that decides whether the upgrade is possible at all. A copr with no
chroot for the target silently yields nothing — `skip_if_unavailable=True` means no
error, just a package that stops existing.

    dnf repo list --enabled

For each copr:

    curl -s "https://copr.fedorainfracloud.org/api_3/project?ownername=OWNER&projectname=PROJ" \
      | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin).get("chroot_repos",{})))'

Known state as of 2026-09:

| repo | chroots | note |
|---|---|---|
| `solopasha/hyprland` | rawhide only | **dead end** — do not carry it forward |
| `lionheartp/Hyprland` | 43, 44, 45 | the F43+ Hyprland source; hyprland 0.56.2 |
| `avengemedia/dms`, `/danklinux` | 43, 44, 45 | dms, quickshell, dgop, ghostty |
| `erikreider/swayosd`, `tofik/nwg-shell` | 43, 44, 45 | fine |
| `kwizart/kernel-longterm-6.12` | 43 only | drop it unless actually booting that kernel |
| `pgdev/ghostty` | **none at all** | ghostty comes from Terra / danklinux now |

`.chezmoidata/packages.yaml` already encodes this as `coprF43Plus` and
`repoOverridesF43Plus`. Trust it — it is right.

## 2. Remove what cannot come with you

Dead DKMS is the classic release-upgrade killer: it must rebuild against the new
kernel, and it fails at the worst moment.

    zpool list                    # no pools? then zfs-dkms is protecting nothing
    uname -r                      # actually booting the longterm kernel? usually not
    lsmod | grep vbox             # guest-additions on bare metal is cruft

Check nothing depends on a package before removing it:

    dnf repoquery --installed --whatrequires <pkg>

## 3. Swap the repos

Disable rather than delete, so a failed upgrade can be walked back:

    sudo dnf config-manager setopt copr:...:solopasha:hyprland.enabled=0

Add the replacement with `$releasever` in the baseurl so it activates on the new
release and stays inert until then. Keep `includepkgs` narrow so the copr cannot shadow
Fedora or Terra packages — the list in `repoOverridesF43Plus` is correct and sufficient;
verify with:

    # installed packages for which this copr is the ONLY source on the target
    comm -23 <(rpm -qa --qf '%{name}\n' | sort -u) <(everything-else-available) \
      | comm -12 - <(copr-provides)

## 4. Import repo GPG keys FIRST — this one cost the most time

`repo_gpgcheck=1` (Terra) means dnf must have the key in **its own repo keyring**, which
is separate from the rpmdb. `rpm --import` is not enough.

Worse: **`--assumeno` silently declines the key-import prompt.** A dry run then shows a
repo as present but empty, and every package it should have supplied appears to be
missing — producing cascading phantom dependency failures three layers away from the
real cause. On `yoga` this looked like four unrelated problems (a Python 3.13→3.14 ABI
chain, a blocked `waypaper` dependency, and an unsatisfiable `terra-release`). All four
were one missing key.

    sudo dnf --releasever=NN makecache --refresh     # interactive; answer y

Run it in a real terminal. Not through a non-TTY wrapper.

## 5. Dry run — the actual gate

    sudo dnf system-upgrade download --releasever=NN --assumeno 2>&1 | tee resolve.log

Read the log, not the tail:

- `Failed to resolve` — real. Fix and repeat.
- `Operation aborted by the user` — success; that is `--assumeno` declining.
- **Read the Removing: list in full.** It should be old kernels and nothing else.
  Anything surprising there is the upgrade telling you something.
- Watch for repo packages replacing real packages, e.g.
  `adoptium-temurin-java-repository` obsoleting `java-*-openjdk` — that swaps a JDK for
  a *repository definition*. Harmless if another JDK is installed; check first.

Do **not** audit by package name alone. Comparing installed names against target-repo
names over-reports badly: `basesystem`→`filesystem`, `nodejs`→`nodejs22`,
`gdk-pixbuf2-modules`→`gdk-pixbuf2`, `pandoc`→`pandoc-cli` are all renames dnf resolves
via `Obsoletes:` and a name comparison cannot see. The dry run is the only real answer.

## 6. Safety net — BOTH halves

See `docs/btrfs-rollback.md`. The half that is easy to miss:

**`/boot` is a separate partition, outside btrfs.** A root subvolume snapshot contains
no kernels, no initramfs, no bootloader entries. Restoring only the subvolume leaves old
userspace under a new kernel. Snapshot `root` **and** archive `/boot`.

Also check `/boot` has headroom — it is ~1G and a kernel set is ~180M. The upgrade adds
one before pruning the oldest.

## 7. Go

    sudo dnf system-upgrade download --releasever=NN     # ~4 GiB
    sudo dnf system-upgrade status                       # confirm staged
    sudo dnf system-upgrade reboot                       # applies; 20-40 min; keep power

Old kernels are retained, so the previous release's kernels remain as boot entries even
before touching the snapshot.

## 8. Afterwards

- Revert any per-machine workarounds that existed only because this machine was behind.
- Remove packages orphaned at the old release (`rpm -qa | grep fc<old>`).
- Rebuild anything locally built (`vendor=(none)`).
- Delete the snapshot and `/boot` archive once the new release is confirmed good.

---

## Snapshot tooling: what to use

**dotsnap is home-grown and covers only `/home`.** The gap it left is exactly the one
that mattered: nothing snapshotted `/` before a release upgrade.

The standard tool is **snapper** (`snapper-0.13.0` on F44, `0.11.0` on F42). It is what
this should move to:

- config per subvolume, timeline snapshots with real retention algorithms
- `snapper list` / `snapper undochange` / `snapper rollback`
- expects `.snapshots` to be a **subvolume**, which is precisely what the
  `tmpfiles.d` `v` line was trying to create and what the "plain directory, not a
  subvolume" warning is about. `v` will not convert an existing plain directory.

**The catch, and it is a real one:** there is *no packaged automatic dnf5 integration*
on Fedora today.

- `python3-dnf-plugin-snapper` exists but requires `python3-dnf-plugins-extras-common`
  — it is the **dnf4** plugin stack.
- There is **no `dnf5-plugin-snapper`**.
- The libdnf5 `actions.so` hook plugin is **not packaged** in Fedora (only
  `expired-pgp-keys.so` and `notify_packagekit.so` ship).

Fedora uses dnf5. So snapper will not snapshot automatically around transactions here;
that trigger stays explicit — a `mise` task or a systemd unit calling
`snapper create --description "pre-upgrade"`. Which is fine: pre-upgrade snapshots
should be deliberate anyway.

Also considered:

- **btrbk** — aimed at send/receive to another host. Genuinely useful *in addition*,
  for getting snapshots off the machine. Does not replace snapper for local rollback.
- **Timeshift** — expects Ubuntu-style `@`/`@home` subvolume naming. These machines use
  `root`/`home`. Do not use it here.

**Neither snapper nor any of these solves `/boot`.** It is not on btrfs. That archive
step stays manual regardless of tooling — which is the single most important thing on
this page.

If the strongest guarantee is ever wanted, the structural answer is an image-based
system (Silverblue/Kinoite), where upgrades are atomic and rollback is a boot menu
entry. That is a different machine model, not a tweak to this one.
