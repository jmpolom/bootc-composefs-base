#!/usr/bin/env bash

# This trusted hook runs inside the Fedora CoreOS live guest, immediately before
# Podman invokes the installer.  The host harness copies it into the guest; the
# first two arguments and matching environment variables are stable by-id paths.
set -Eeuo pipefail
umask 077

target_device=${1:?target disk by-id path is required}
extra_device=${2:-${QEMU_PREINSTALL_EXTRA_DEVICE:?extra disk by-id path is required}}
work_dir=${QEMU_PREINSTALL_WORK_DIR:?runtime directory is required}
key_file=$work_dir/qemu-existing-composefs-var.key
uuid_file=$work_dir/qemu-existing-composefs-var.uuid
seed_mapper=qemu_existing_seed
seed_dir=$(mktemp -d "$work_dir/qemu-existing-composefs-var.XXXXXX")

cleanup() {
    local status=$?
    set +e
    umount "$seed_dir" >/dev/null 2>&1 || true
    cryptsetup close "$seed_mapper" >/dev/null 2>&1 || true
    rmdir "$seed_dir" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT INT TERM

[[ -b $target_device && -b $extra_device ]] || {
    echo "pre-install hook could not find the QEMU target or extra disk" >&2
    exit 1
}
printf '%s' "$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')" >"$key_file"
chmod 0600 "$key_file"
cryptsetup luksFormat --batch-mode --type luks2 --key-file "$key_file" "$extra_device"
cryptsetup open --type luks --key-file "$key_file" "$extra_device" "$seed_mapper"
mkfs.btrfs -f -L qemu_existing_var "/dev/mapper/$seed_mapper"
mount -t btrfs "/dev/mapper/$seed_mapper" "$seed_dir"
btrfs subvolume create "$seed_dir/var"
mkdir -p "$seed_dir/var/qemu-existing"
printf '%s\n' 'composefs existing-volume seed retained' >"$seed_dir/var/qemu-existing/seed-marker"
printf '%s\n' 'composefs existing-volume conflict marker retained' \
    >"$seed_dir/var/qemu-existing/conflict-marker"
cryptsetup luksUUID "$extra_device" >"$uuid_file"
chmod 0600 "$uuid_file"
printf 'QEMU_PREINSTALL_EXISTING_UUID=%s\n' "$(<"$uuid_file")"
