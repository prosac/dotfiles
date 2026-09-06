# Rolling back a bad system upgrade (btrfs)

The root subvolume is snapshotted before risky upgrades, and `/boot` is archived
separately. **Both are required**: `/boot` is its own partition, outside btrfs, so a
root snapshot contains no kernels, initramfs, or bootloader entries. Restoring only
the subvolume leaves old userspace under a newer kernel.

## Layout

Flat top level (`mount -o subvolid=5`): `root` -> `/`, `home` -> `/home`.
fstab mounts by NAME (`subvol=root`), so rollback is a rename, not `set-default`.

## Find the devices (never hardcode them)

    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
    blkid | grep crypto_LUKS      # the LUKS partition
    blkid | grep -i 'TYPE="vfat"' # the ESP

## Taking the safety net, before the upgrade

    LUKS=/dev/mapper/$(ls /dev/mapper | grep '^luks-')
    sudo mkdir -p /mnt/btrfs && sudo mount -o subvolid=5 "$LUKS" /mnt/btrfs
    sudo btrfs subvolume snapshot -r /mnt/btrfs/root /mnt/btrfs/root-pre-<target>-<date>
    sudo tar --zstd -C / -cf /mnt/btrfs/boot-pre-<target>-<date>.tar.zst boot

Verify: the snapshot reports `ro=true`, and the archive lists one `vmlinuz` and one
`initramfs` per installed kernel plus the `loader/entries/*.conf`.

## Rolling back — from a LIVE USB only

Never from the running system: renaming the live root subvolume leaves the next boot
unable to find `subvol=root`.

1. Unlock and mount the top level:

       sudo cryptsetup open /dev/<luks-partition> recovered
       sudo mount -o subvolid=5 /dev/mapper/recovered /mnt

2. Set the broken root aside, branch a WRITABLE copy from the read-only snapshot
   (no `-r` — that is why the snapshot is read-only: retries always start clean):

       sudo mv /mnt/root /mnt/root-broken
       sudo btrfs subvolume snapshot /mnt/root-pre-<target>-<date> /mnt/root

3. Restore /boot. Mount the ESP BEFORE extracting, or the `boot/efi/*` entries land in
   the empty mountpoint underneath and vanish once it is mounted properly:

       sudo mkdir -p /mnt/bootpart
       sudo mount /dev/<boot-partition> /mnt/bootpart
       sudo mount /dev/<esp-partition>  /mnt/bootpart/efi
       sudo rm -rf /mnt/bootpart/{vmlinuz*,initramfs*,loader,.vmlinuz*}
       sudo tar --zstd -xf /mnt/boot-pre-<target>-<date>.tar.zst \
            -C /mnt/bootpart --strip-components=1

   `--strip-components=1` drops the archive's `boot/` prefix.

4. Reboot. Once satisfied: `sudo btrfs subvolume delete /mnt/root-broken`, and delete
   the snapshot and archive when the upgrade is confirmed good.

## Before you need it

Keep a live USB on hand, and keep a copy of this OFF the machine it describes.
