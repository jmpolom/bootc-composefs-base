#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2192,SC2329
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../lib/common.sh
source "$root/installers/lib/common.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected=$1 actual=$2 description=$3
    [[ $actual == "$expected" ]] || fail "$description (expected '$expected', got '$actual')"
}

assert_contains() {
    local expected=$1 description=$2 item
    for item in "${bootc_args[@]}"; do
        [[ $item == "$expected" ]] && return 0
    done
    fail "$description (missing '$expected')"
}

# The validation helpers call die; a subshell gives each expected failure its
# own process while allowing the rest of this test to continue.
die() {
    printf '%s\n' "$*" >&2
    exit 97
}

set_defaults
physical_var_path=/state/os/default/var
root_partition_type_guid=11111111-1111-1111-1111-111111111111
normalize_internal_volumes
assert_eq root "${vol_fs_label[2]}" 'default root filesystem label'
assert_eq root "${vol_partition_label[2]}" 'default root partition label'
assert_eq root_luks "${vol_luks_label[2]}" 'default root LUKS label'
assert_eq root "${vol_subvol[2]}" 'default root subvolume'

root_fs_label=system_root
root_subvol=system/root
root_partition_label=system_gpt
root_luks_label=system_luks
root_encrypted=true
luks_name=system
root_partition=/dev/mock-system-root
normalize_internal_volumes
assert_eq /dev/disk/by-partlabel/system_gpt "${vol_device[2]}" 'custom root partition label'
assert_eq /dev/mock-system-root "${vol_partition_resolved[2]}" 'custom root partition path'
assert_eq system_root "${vol_fs_label[2]}" 'custom root filesystem label'
assert_eq system/root "${vol_subvol[2]}" 'custom root subvolume'
assert_eq system_luks "${vol_luks_label[2]}" 'custom root LUKS label'
assert_eq system "${vol_luks[2]}" 'custom root mapper name'
vol_mount_options root_options 2
assert_eq 'subvol=system/root,compress=zstd,noatime' "$root_options" 'root mount options'
boot_filesystem_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
vol_luks_uuid_resolved=([2]=11111111-2222-3333-4444-555555555555)
bootc_args=()
append_common_kargs /state/os/default/var bootc-root-setup.service
assert_eq '--root-mount-spec=/dev/disk/by-label/system_root' "${bootc_args[0]}" 'normalized root mount source'
assert_eq '--karg=rootflags=subvol=system/root,compress=zstd,noatime' "${bootc_args[3]}" 'normalized root mount options'
assert_eq '--karg=rd.luks.name=11111111-2222-3333-4444-555555555555=system' "${bootc_args[5]}" 'normalized root mapper karg'

# Shortcut records are ordinary normalized records and no longer expose the
# compatibility switches to downstream lifecycle phases.
ext_vol_devices=()
ext_vol_mountpoint=()
ext_vol_fs=()
ext_vol_luks=()
ext_vol_opts=()
ext_vol_tpm=()
ext_vol_tpm_pcrs=()
ext_vol_recovery=()
ext_vol_existing=()
ext_vol_subvol=()
ext_vol_subvol_create=()
separate_var=true
normalize_ext_vol_shortcuts
[[ ${separate_var+x} != x ]] || fail 'separate_var leaked past normalization'
assert_eq /var "${ext_vol_mountpoint[0]}" 'separate_var mountpoint'
assert_eq system/root/state/os/default/var "${ext_vol_subvol[0]}" 'separate_var subvolume'
normalize_internal_volumes
assert_eq 2 "${vol_backing_index[3]}" 'shortcut root backing record'

# External records start at normalized index 3. Both subvolume policies must
# be evaluated from vol_* so a public index cannot accidentally validate the
# wrong record.
vol_validate_mount_format 3 || fail 'normalized Btrfs subvolume create policy rejected'
vol_subvol_create[3]=false
vol_validate_mount_format 3 || fail 'normalized Btrfs subvolume retain policy rejected'
vol_subvol[3]=
vol_subvol_create[3]=true
if (vol_validate_mount_format 3); then fail 'normalized empty subvolume accepted with create=true'; fi
vol_subvol[3]=containers
vol_subvol_create[3]=maybe
if (vol_validate_mount_format 3); then fail 'invalid normalized subvolume create policy accepted'; fi

# An explicit root-backed record follows the custom root filesystem label and
# subvolume rather than being treated as an independent disk.
ext_vol_devices=(/dev/disk/by-label/system_root)
ext_vol_mountpoint=(/var/lib/custom)
ext_vol_fs=(btrfs)
ext_vol_luks=()
ext_vol_opts=(compress=zstd)
ext_vol_tpm=(false)
ext_vol_tpm_pcrs=()
ext_vol_recovery=(false)
ext_vol_existing=(false)
ext_vol_subvol=(unrelated)
ext_vol_subvol_create=(false)
normalize_internal_volumes
[[ -z ${vol_backing_index[3]:-} ]] || fail 'unrelated subvolume incorrectly treated as root-backed'
ext_vol_subvol=(system/root/custom)
normalize_internal_volumes
assert_eq 2 "${vol_backing_index[3]}" 'custom root-backed relation'
assert_eq /dev/disk/by-label/system_root "${vol_source_resolved[3]}" 'custom root-backed source'
vol_mount_options custom_options 3
assert_eq 'compress=zstd,subvol=system/root/custom' "$custom_options" 'external subvolume mount options'

# Mount/subvolume policy is checked without devices or mounts.
vol_mountpoint[0]=/data
vol_fs[0]=btrfs
vol_existing[0]=false
vol_opts[0]=defaults
vol_subvol[0]=containers
vol_subvol_create[0]=true
vol_validate_mount_format 0 || fail 'valid Btrfs subvolume create policy rejected'
vol_subvol_create[0]=false
vol_validate_mount_format 0 || fail 'valid Btrfs subvolume retain policy rejected'
vol_subvol[0]=
vol_subvol_create[0]=true
if (vol_validate_mount_format 0); then fail 'empty subvolume accepted with create=true'; fi
vol_subvol=([0]=containers)
vol_subvol_create=([0]=false)
vol_opts=([0]=subvol=other)
if (vol_validate_mount_format 0); then fail 'explicit subvol option accepted'; fi
vol_opts=([0]=subvolid=5)
if (vol_validate_mount_format 0); then fail 'explicit subvolid option accepted'; fi
vol_fs[0]=ext4
vol_opts[0]=defaults
if (vol_validate_mount_format 0); then fail 'subvolume accepted for non-Btrfs filesystem'; fi
vol_mountpoint[0]=/state
vol_device[0]=/dev/mock
if (vol_validate_mount_target 0); then fail 'reserved /state mountpoint accepted'; fi
vol_mountpoint[0]=/data

# A requested subvolume verifies the actual backing type, not only config.
vol_fs[0]=btrfs
blkid() { printf '%s\n' ext4; }
if (vol_verify_subvolume 0); then fail 'non-Btrfs backing filesystem accepted'; fi
blkid() { printf '%s\n' btrfs; }
vol_verify_subvolume 0 || fail 'Btrfs backing filesystem rejected'
vol_subvol[0]=''
vol_opts[0]=defaults
vol_mount_options empty_subvolume_options 0
assert_eq defaults "$empty_subvolume_options" 'empty subvolume selects filesystem root'

# The formatter is one generic dispatch for all predefined and external fs types.
mkfs.btrfs() { printf 'btrfs\n' >>"$dispatch_log"; }
mkfs.ext4() { printf 'ext4\n' >>"$dispatch_log"; }
mkfs.vfat() { printf 'vfat\n' >>"$dispatch_log"; }
mkfs.xfs() { printf 'xfs\n' >>"$dispatch_log"; }
dispatch_log=$(mktemp)
vol_fs_label=([0]=boot_efi [1]=boot [2]=system_root [3]=data)
vol_fs=([0]=vfat [1]=ext4 [2]=btrfs [3]=xfs)
for index in 0 1 2 3; do vol_format_filesystem "$index" /dev/null; done
assert_eq $'vfat\next4\nbtrfs\nxfs' "$(<"$dispatch_log")" 'formatter dispatch'
rm -f -- "$dispatch_log"

bootc_args=()
append_volume_luks_kargs 01234567-89ab-cdef-0123-456789abcdef data_crypt true
assert_eq '--karg=rd.luks.uuid=01234567-89ab-cdef-0123-456789abcdef' "${bootc_args[0]}" 'common encrypted UUID argument'
assert_eq '--karg=rd.luks.name=01234567-89ab-cdef-0123-456789abcdef=data_crypt' "${bootc_args[1]}" 'common encrypted mapper argument'
assert_eq '--karg=rd.luks.options=01234567-89ab-cdef-0123-456789abcdef=tpm2-device=auto,x-initrd.attach' "${bootc_args[2]}" 'common encrypted options argument'

# The root and external records share the same normalized encrypted-karg
# emitter. Exercise the common boot argument path with an external record.
mock_validate_mount_target() { :; }
mock_append_external_var_karg() { bootc_args+=("--mock-var=$1:$2:$3"); }
installer_backend=mock
vol_source_resolved[2]=/dev/disk/by-label/system_root
vol_luks_uuid_resolved[2]=11111111-2222-3333-4444-555555555555
vol_install_phase[3]=postdeploy
vol_source_resolved[3]=/dev/mapper/data_crypt
vol_fs[3]=btrfs
vol_opts[3]=defaults
vol_subvol[3]=
vol_luks[3]=data_crypt
vol_luks_uuid_resolved[3]=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
vol_tpm[3]=false
bootc_args=()
append_common_kargs /state/os/default/var bootc-root-setup.service
assert_contains '--karg=rd.luks.name=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee=data_crypt' 'external encrypted karg'

# Existing encrypted records use the predictable lvc_<mapper> variable and
# share the normal activation/enrollment path without modifying their media.
work_root=$(mktemp -d)
vol_existing=([0]=true)
vol_luks=([0]=existing_data)
vol_device=([0]=/dev/null)
vol_mountpoint=([0]=/data)
vol_luks_label=([0]='')
vol_tpm=([0]=true)
vol_tpm_pcrs=([0]=7)
vol_recovery=([0]=false)
lvc_existing_data=fixture-password
cryptsetup() {
    case ${1:-} in
        open) return 0 ;;
        luksUUID) printf '%s\n' 01234567-89ab-cdef-0123-456789abcdef ;;
        *) return 0 ;;
    esac
}
systemd-cryptenroll() { return 0; }
vol_activate_luks 0
[[ ${lvc_existing_data+x} != x ]] || fail 'existing volume credential leaked after activation'
assert_eq existing_data "${vol_source_resolved[0]##*/}" 'existing encrypted mapper source'
assert_eq 01234567-89ab-cdef-0123-456789abcdef "${vol_luks_uuid_resolved[0]}" 'existing LUKS UUID'
rm -rf -- "$work_root"

printf 'storage mock checks passed\n'
