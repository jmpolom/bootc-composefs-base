#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2154
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source "$root/installers/lib/common.sh"
die() { printf '%s\n' "$*" >&2; exit 97; }
assert_eq() { [[ $1 == "$2" ]] || die "$3 (expected '$1', got '$2')"; }
assert_rejected() {
    local label=$1
    shift
    if ("$@"); then die "$label was accepted"; fi
}
reject_short_list() {
    vol_list=(vol_root vol_boot)
    record_names_valid
}
target_disk=/dev/mock-target
physical_var_path=/state/os/default/var
vol_list=(vol_root vol_boot vol_esp vol_data)
declare -A vol_root=([action]=create [parent_disk]=$target_disk [partition_number]=3 [partition_size]=remainder [partition_type]=guid [partition_label]=root [mountpoint]=/ [fs]=btrfs [fs_label]=root [mount_options]=compress=zstd [encryption]=none [credential]=none [subvol]=root [subvol_action]=create [phase]=predeploy)
declare -A vol_boot=([action]=create [parent_disk]=$target_disk [partition_number]=2 [partition_size]=1024 [partition_type]=guid [partition_label]=boot [mountpoint]=/boot [fs]=ext4 [fs_label]=boot [mount_options]=defaults [encryption]=none [credential]=none [subvol_action]=none [phase]=predeploy)
declare -A vol_esp=([action]=create [parent_disk]=$target_disk [partition_number]=1 [partition_size]=600 [partition_type]=guid [partition_label]=boot_efi [mountpoint]=/boot/efi [fs]=vfat [fs_label]=boot_efi [mount_options]=defaults [encryption]=none [credential]=none [subvol_action]=none [phase]=predeploy)
declare -A vol_data=([action]=create [device]=/dev/data [mountpoint]=/data [fs]=xfs [fs_label]=data [mount_options]=defaults [encryption]=none [credential]=none [subvol_action]=none [phase]=postdeploy)
record_names_valid

minimum_size_root=$(mktemp -d)
minimum_size_target=$minimum_size_root/target
minimum_size_other=$minimum_size_root/other
touch "$minimum_size_target" "$minimum_size_other"
declare -A vol_sized=([action]=create [parent_disk]=$minimum_size_target [partition_number]=4 [partition_size]=1024)
declare -A vol_other=([action]=create [parent_disk]=$minimum_size_other [partition_number]=5 [partition_size]=4096)
declare -A vol_direct=([action]=create [device]=/dev/data)
declare -A vol_retained=([action]=retain [device]=/dev/retained)
declare -A vol_relation=([action]=relation [backing]=vol_sized)
vol_list=(vol_sized vol_other vol_direct vol_retained vol_relation)
minimum_size=$(target_disk_minimum_size "$(readlink -f -- "$minimum_size_target")" $((2048 * 1024 * 1024)))
assert_eq "$((3072 * 1024 * 1024))" "$minimum_size" \
    'target minimum size ignores direct, retained, relation, and other-disk records'
rm -rf -- "$minimum_size_root"
vol_list=(vol_root vol_boot vol_esp vol_data)

validate_volume_record vol_root
assert_eq create "${vol_root[action]}" 'named root record'
assert_eq /boot "${vol_boot[mountpoint]}" 'named boot record'
assert_eq /boot/efi "${vol_esp[mountpoint]}" 'named ESP record'
vol_mount_options options vol_root
assert_eq compress=zstd,subvol=root "$options" 'named mount options'

separate_var=true
normalize_volume_shortcuts
assert_eq vol_var "${vol_list[4]}" 'generated relation name'
assert_eq relation "${vol_var[action]}" 'generated relation action'
assert_eq vol_root "${vol_var[backing]}" 'generated relation backing'

if (vol_root[action]=bad; validate_volume_record vol_root); then die 'invalid action accepted'; fi
if (vol_root[phase]=bad; validate_volume_record vol_root); then die 'invalid phase accepted'; fi
vol_root[action]=create
vol_root[phase]=predeploy
if (vol_data[fs_label]=; validate_volume_record vol_data); then die 'missing filesystem label accepted'; fi
vol_data[fs_label]=data
vol_data[subvol_action]=select
if (validate_volume_record vol_data); then die 'non-Btrfs subvolume accepted'; fi
vol_data[subvol_action]=none

vol_data[fs]=btrfs
vol_data[fs_label]=data
vol_data[encryption]=luks-create
vol_data[luks_name]=data-name
vol_data[luks_label]=data_luks
vol_data[credential]='env'
if (validate_volume_record vol_data); then die 'missing env identifier was accepted'; fi
vol_data[luks_name]=data_name
vol_data[credential]=none
vol_data[encryption]=none
vol_data[fs]=xfs
if (vol_data[mount_options]=bad:option; validate_volume_record vol_data); then die 'mount delimiter accepted'; fi

declare -A vol_a=([action]=relation [backing]=vol_b [mountpoint]=/a [fs]=btrfs [subvol]=a [subvol_action]=select)
declare -A vol_b=([action]=relation [backing]=vol_a [mountpoint]=/b [fs]=btrfs [subvol]=b [subvol_action]=select)
vol_list+=(vol_a vol_b)
if (validate_relation_graph); then die 'relation cycle accepted'; fi

vol_list=(vol_root vol_boot vol_esp)
vol_root[subvol]=custom-root
physical_var_path=/state/custom/var
separate_home=true
normalize_volume_shortcuts
assert_eq custom-root/state/custom/var/home "${vol_home[subvol]}" 'non-default root relation identity'

# Record declarations, required ordering, uniqueness, and missing fields.
assert_rejected 'short volume list' reject_short_list
if (vol_list=(vol_root vol_boot vol_esp vol_data vol_data); record_names_valid); then
    die 'duplicate record name accepted'
fi
if (vol_list=(vol_boot vol_root vol_esp); record_names_valid); then
    die 'wrong core record order accepted'
fi
vol_list=(vol_root vol_boot vol_esp vol_data)
if (unset 'vol_data[device]'; validate_volume_record vol_data); then
    die 'missing create device accepted'
fi
vol_data[device]=/dev/data

# All public mode enums and valid combinations are accepted; invalid combinations reject.
vol_data[action]=retain
vol_data[fs]=xfs
vol_data[encryption]=none
unset 'vol_data[luks_name]' 'vol_data[luks_label]'
vol_data[credential]=none
vol_data[subvol_action]=none
validate_volume_record vol_data
vol_data[encryption]=luks-open
vol_data[luks_name]=retained_data
vol_data[credential]=prompt
validate_volume_record vol_data
credential_file=$(mktemp)
printf secret >"$credential_file"
vol_data[encryption]=luks-create
vol_data[luks_name]=created_data
vol_data[luks_label]=created_luks
vol_data[credential]='file'
vol_data[credential_file]=$credential_file
vol_data[action]=create
validate_volume_record vol_data
vol_data[credential]=ephemeral
vol_data[tpm2]=true
vol_data[recovery]=true
vol_data[fs]=btrfs
vol_data[subvol]=data
vol_data[subvol_action]=create
validate_volume_record vol_data
if (vol_data[recovery]=true; vol_data[tpm2]=false; validate_volume_record vol_data); then
    die 'recovery without TPM accepted'
fi
rm -f -- "$credential_file"

# Explicit relation backing and shortcut conflicts are validated before lifecycle work.
declare -A vol_relation=([action]=relation [backing]=vol_root [mountpoint]=/data-rel \
    [fs]=btrfs [subvol]=custom-root/data [subvol_action]=select)
vol_list+=(vol_relation)
validate_relation_graph
if (vol_relation[backing]=vol_missing; validate_relation_graph); then
    die 'missing relation backing accepted'
fi
vol_list=(vol_root vol_boot vol_esp vol_data)
if (separate_var=true; normalize_volume_shortcuts); then
    :
fi
vol_data[mountpoint]=/var
if (separate_var=true; normalize_volume_shortcuts); then
    die 'shortcut mountpoint conflict accepted'
fi
vol_data[mountpoint]=/data

# Environment credentials materialize into a temporary file and erase the variable immediately.
work_root=$(mktemp -d)
vol_data[action]=retain
vol_data[encryption]=luks-open
vol_data[luks_name]=env_data
vol_data[credential]='env'
export lvc_env_data=environment-secret
volume_credential materialized vol_data
[[ ! -v lvc_env_data ]] || die 'environment credential was not erased'
assert_eq environment-secret "$(<"$materialized")" 'environment credential materialization'
rm -rf -- "$work_root" "$materialized"
work_root=$(mktemp -d)

# Encrypted activation, recovery-before-TPM ordering, and ephemeral password cleanup.
crypto_log=$(mktemp)
cryptsetup() {
    printf 'cryptsetup %s\n' "$*" >>"$crypto_log"
    if [[ $1 == luksUUID ]]; then
        printf '11111111-2222-3333-4444-555555555555\n'
    fi
    return 0
}
systemd-cryptenroll() {
    printf 'cryptenroll %s\n' "$*" >>"$crypto_log"
    if [[ $* == *--recovery-key* ]]; then
        printf 'bcdefghi-jklnrtuv-bcdefghi-jklnrtuv-bcdefghi-jklnrtuv-bcdefghi-jklnrtuv\n'
    fi
    return 0
}
blkid() {
    if [[ $* == *TYPE* ]]; then printf '%s\n' "${mock_fs:-btrfs}"; else printf 'uuid\n'; fi
    return 0
}
mock_fs=xfs
retained_key=$(mktemp)
printf retained-secret >"$retained_key"
declare -A vol_retained=([action]=retain [device]=/dev/retained [mountpoint]=/retained [fs]=xfs
    [encryption]=luks-open [luks_name]=retained_xfs [credential]=file [credential_file]=$retained_key
    [subvol_action]=none)
vol_list=(vol_retained)
vol_prepare_existing
assert_eq /dev/mapper/retained_xfs "${vol_retained[_source]}" 'retained encrypted mapper'
assert_eq uuid "${vol_retained[_fs_uuid]}" 'retained filesystem UUID'
rm -f -- "$retained_key"
mock_fs=btrfs
declare -A vol_crypto=([action]=create [device]=/dev/crypto [mountpoint]=/crypto [fs]=btrfs
    [fs_label]=crypto [encryption]=luks-create [luks_name]=crypto_name [luks_label]=crypto_luks
    [credential]=ephemeral [tpm2]=true [recovery]=true [subvol_action]=none)
vol_list=(vol_crypto)
recovery_output_root=$(mktemp -d)
recovery_key_output_file=$recovery_output_root/nested/recovery.keys
initialize_recovery_key_output
[[ -f $recovery_key_output_file && ! -L $recovery_key_output_file ]] || die 'recovery output was not initialized'
recovery_symlink=$recovery_output_root/recovery-link
ln -s "$recovery_key_output_file" "$recovery_symlink"
if (recovery_key_output_file=$recovery_symlink; initialize_recovery_key_output); then
    die 'recovery output symlink was accepted'
fi
recovery_mode=$(stat -c '%a' "$recovery_key_output_file" 2>/dev/null || stat -f '%Lp' "$recovery_key_output_file")
assert_eq 600 "$recovery_mode" 'recovery output permissions'
recovery_uuid=11111111-2222-3333-4444-555555555555
capture_recovery_key captured_recovery /dev/recovery
validate_recovery_key captured_recovery || die 'valid recovery key was rejected'
test_recovery_key captured_recovery /dev/recovery || die 'valid recovery key failed unlock test'
write_recovery_key_record recovery_uuid captured_recovery "$recovery_key_output_file" ||
    die 'recovery key record write failed'
if (captured_recovery=invalid; validate_recovery_key captured_recovery); then
    die 'invalid recovery key was accepted'
fi
if (captured_recovery=invalid; write_recovery_key_record recovery_uuid captured_recovery "$recovery_key_output_file"); then
    die 'invalid recovery key record was written'
fi
assert_eq 1 "$(wc -l <"$recovery_key_output_file" | tr -d ' ')" 'recovery record remains atomic after rejection'
vol_crypto[_partition_device]=/dev/crypto
vol_activate_luks vol_crypto
grep -q 'cryptenroll --recovery-key' "$crypto_log" || die 'recovery enrollment missing'
grep -q 'cryptenroll --wipe-slot=password' "$crypto_log" || die 'ephemeral cleanup missing'
first_recovery=$(grep -n -- '--recovery-key' "$crypto_log" | head -n1 | cut -d: -f1)
first_tpm=$(grep -n -- '--tpm2-device=auto' "$crypto_log" | head -n1 | cut -d: -f1)
first_wipe=$(grep -n -- '--wipe-slot=password' "$crypto_log" | head -n1 | cut -d: -f1)
((first_recovery < first_tpm && first_tpm < first_wipe)) || die 'TPM/recovery/cleanup order changed'
assert_eq 2 "$(wc -l <"$recovery_key_output_file" | tr -d ' ')" 'one recovery record per enrollment'
rm -f -- "$crypto_log"; rm -rf -- "$recovery_output_root"
vol_data[fs]=xfs

dispatch_log=$(mktemp)
mkfs.btrfs() { printf btrfs >>"$dispatch_log"; }
mkfs.ext4() { printf ext4 >>"$dispatch_log"; }
mkfs.vfat() { printf vfat >>"$dispatch_log"; }
mkfs.xfs() { printf xfs >>"$dispatch_log"; }
for record in vol_esp vol_boot vol_root vol_data; do vol_format_filesystem "$record" /dev/null; done
assert_eq vfatext4btrfsxfs "$(<"$dispatch_log")" 'unified filesystem dispatch'; rm -f "$dispatch_log"

bootc_args=(); append_volume_luks_kargs uuid mapper true
assert_eq '--karg=rd.luks.name=uuid=mapper' "${bootc_args[1]}" 'unified encrypted kargs'

# Mount ordering and options are shared by predeploy and postdeploy paths.
install_root=$(mktemp -d)
mount_log=$(mktemp)
mount() { printf '%s\n' "${6}" >>"$mount_log"; }
cleanup_mounts=()
vol_list=(vol_root vol_boot vol_esp)
vol_root[_source]=/dev/root
vol_boot[_source]=/dev/boot
vol_esp[_source]=/dev/esp
vol_mount_phase predeploy
assert_eq "$install_root/ $install_root/boot $install_root/boot/efi " "$(tr '\n' ' ' <"$mount_log")" 'mount depth order'
rm -f -- "$mount_log"; rm -rf -- "$install_root"

# A relation without a subvolume is valid when it mounts the backing filesystem.
# Keep this lifecycle check under set -u so optional relation fields stay guarded.
install_root=$(mktemp -d)
state_root=$(mktemp -d)
state_target=$state_root/relation
mkdir -p "$state_target"
work_root=$(mktemp -d)
declare -A vol_state_root=([action]=create [fs]=btrfs [subvol]=root [mountpoint]=/ [phase]=predeploy)
declare -A vol_state_relation=([action]=relation [backing]=vol_state_root [fs]=btrfs
    [mountpoint]=/relation [phase]=postdeploy [_source]=/dev/state)
cleanup_mounts=()
vol_list=(vol_state_root vol_state_relation)
vol_mount_filesystem() { :; }
cp() { :; }
umount() { :; }
vol_migrate_mounts "$state_root" "$state_root/var"
assert_eq "$state_target" "${cleanup_mounts[0]}" 'relation without subvolume migrated'
cleanup_mounts=()
rm -rf -- "$install_root" "$state_root" "$work_root"

# Backend callbacks produce distinct /var kargs while common handling remains shared.
mock_append_external_var_karg() { bootc_args+=("mock-var=$1:$2:$3"); }
composefs_append_external_var_karg() { bootc_args+=("composefs-var=$1:$2:$3"); }
ostree_append_external_var_karg() { bootc_args+=("ostree-var=$1:$2:$3"); }
vol_list=(vol_root vol_boot vol_esp vol_data)
vol_data[mountpoint]=/var
vol_data[phase]=postdeploy
vol_data[subvol_action]=none
vol_root[_source]=/dev/root
vol_data[_source]=/dev/data
boot_filesystem_uuid=boot-uuid
installer_backend=mock
bootc_args=()
append_common_kargs /state/mock/var mock-root.service
assert_eq '--root-mount-spec=/dev/root' "${bootc_args[0]}" 'root mount spec'
assert_eq 'mock-var=/dev/data:xfs:defaults' "${bootc_args[4]}" 'shared backend var karg'
for backend in composefs ostree; do
    installer_backend=$backend
    bootc_args=()
    append_common_kargs /state/mock/var mock-root.service
    assert_eq "$backend-var=/dev/data:xfs:defaults" "${bootc_args[4]}" "$backend var karg"
done
vol_data[mountpoint]=/data
printf 'storage mock checks passed\n'
