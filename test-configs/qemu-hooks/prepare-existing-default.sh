#!/usr/bin/env bash

# Prepare the retained encrypted Btrfs and XFS volumes used by both backends.
set -Eeuo pipefail
umask 077

target_device=${1:?target disk by-id path is required}
extra_device=${2:-${QEMU_PREINSTALL_EXTRA_DEVICE:?extra disk by-id path is required}}
work_dir=${QEMU_PREINSTALL_WORK_DIR:?runtime directory is required}
btrfs_partition=/dev/disk/by-partlabel/qemu_retained_btrfs
xfs_partition=/dev/disk/by-partlabel/qemu_retained_xfs
btrfs_key=$work_dir/qemu-retained-btrfs.key
xfs_key=$work_dir/qemu-retained-xfs.key
btrfs_uuid=$work_dir/qemu-retained-btrfs.uuid
xfs_uuid=$work_dir/qemu-retained-xfs.uuid
btrfs_mapper=qemu_retained_btrfs_seed
xfs_mapper=qemu_retained_xfs_seed
btrfs_dir=$(mktemp -d "$work_dir/qemu-retained-btrfs.XXXXXX")
xfs_dir=$(mktemp -d "$work_dir/qemu-retained-xfs.XXXXXX")

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    mountpoint -q "$xfs_dir" && umount "$xfs_dir"
    mountpoint -q "$btrfs_dir" && umount "$btrfs_dir"
    cryptsetup status "$xfs_mapper" >/dev/null 2>&1 && cryptsetup close "$xfs_mapper"
    cryptsetup status "$btrfs_mapper" >/dev/null 2>&1 && cryptsetup close "$btrfs_mapper"
    rmdir "$xfs_dir" "$btrfs_dir" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT INT TERM

[[ -b $target_device && -b $extra_device ]] || {
    echo "pre-install hook could not find the QEMU target or extra disk" >&2
    exit 1
}

wipefs --all --force "$extra_device"
sgdisk --zap-all "$extra_device"
sgdisk \
    --new=1:0:+8192MiB --typecode=1:8300 --change-name=1:qemu_retained_btrfs \
    --new=2:0:0 --typecode=2:8300 --change-name=2:qemu_retained_xfs \
    "$extra_device"
udevadm settle
[[ -b $btrfs_partition && -b $xfs_partition ]]

od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$btrfs_key"
od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$xfs_key"
chmod 0600 "$btrfs_key" "$xfs_key"

cryptsetup luksFormat --batch-mode --type luks2 --key-file "$btrfs_key" "$btrfs_partition"
cryptsetup open --type luks --key-file "$btrfs_key" "$btrfs_partition" "$btrfs_mapper"
mkfs.btrfs -f -L qemu_retained_btrfs "/dev/mapper/$btrfs_mapper"
mount -t btrfs "/dev/mapper/$btrfs_mapper" "$btrfs_dir"
btrfs subvolume create "$btrfs_dir/var"
mkdir -p "$btrfs_dir/var/qemu-existing-btrfs"
printf '%s\n' 'retained Btrfs seed marker' >"$btrfs_dir/var/qemu-existing-btrfs/seed-marker"
printf '%s\n' 'retained Btrfs conflict marker' >"$btrfs_dir/var/qemu-existing-btrfs/conflict-marker"
umount "$btrfs_dir"
cryptsetup close "$btrfs_mapper"

cryptsetup luksFormat --batch-mode --type luks2 --key-file "$xfs_key" "$xfs_partition"
cryptsetup open --type luks --key-file "$xfs_key" "$xfs_partition" "$xfs_mapper"
mkfs.xfs -f -L qemu_ret_xfs "/dev/mapper/$xfs_mapper"
mount -t xfs "/dev/mapper/$xfs_mapper" "$xfs_dir"
mkdir -p "$xfs_dir/qemu-existing-xfs"
printf '%s\n' 'retained XFS seed marker' >"$xfs_dir/qemu-existing-xfs/seed-marker"
printf '%s\n' 'retained XFS conflict marker' >"$xfs_dir/qemu-existing-xfs/conflict-marker"
umount "$xfs_dir"
cryptsetup close "$xfs_mapper"

cryptsetup luksUUID "$btrfs_partition" >"$btrfs_uuid"
cryptsetup luksUUID "$xfs_partition" >"$xfs_uuid"
chmod 0600 "$btrfs_uuid" "$xfs_uuid"
printf 'QEMU_PREINSTALL_RETAINED_BTRFS_UUID=%s\n' "$(<"$btrfs_uuid")"
printf 'QEMU_PREINSTALL_RETAINED_XFS_UUID=%s\n' "$(<"$xfs_uuid")"
