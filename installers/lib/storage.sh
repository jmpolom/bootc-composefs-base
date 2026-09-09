#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

declare -ag cleanup_mounts=()
declare -ag opened_luks_names=()
declare -ag temporary_luks_key_files=()
declare -ag temporary_credential_files=()
declare -ag external_credential_variables=()
# The public ext_vol_* arrays remain the compatibility interface for sourced
# configuration.  These aligned records are the internal representation used
# by the normalized storage model; vol_public_index maps an ext record back to
# its public array index (-1 for predefined volumes).
declare -ag vol_role=()
declare -ag vol_public_index=()
declare -ag vol_backing_index=()
declare -ag vol_device=()
declare -ag vol_parent_disk=()
declare -ag vol_partition_index=()
declare -ag vol_partition_size=()
declare -ag vol_partition_type=()
declare -ag vol_partition_label=()
declare -ag vol_mountpoint=()
declare -ag vol_fs=()
declare -ag vol_fs_label=()
declare -ag vol_opts=()
declare -ag vol_luks=()
declare -ag vol_luks_label=()
declare -ag vol_tpm=()
declare -ag vol_tpm_pcrs=()
declare -ag vol_recovery=()
declare -ag vol_existing=()
declare -ag vol_subvol=()
declare -ag vol_subvol_create=()
declare -ag vol_install_phase=()
declare -ag vol_source_resolved=()
declare -ag vol_luks_uuid_resolved=()
declare -ag vol_partition_resolved=()
declare -ag vol_label_resolved=()

# Convert the legacy state-subvolume switches into ordinary root-backed external volume
# records before any indexed-array or mount-target validation runs.  The
# generated records deliberately carry no provenance: every later storage
# operation sees the same shape whether a record came from a shortcut or was
# written explicitly by the user.
normalize_ext_vol_shortcuts() {
    local shortcut value target subvolume index insertion max_index array_name old_index
    local -a ext_volume_arrays=(
        ext_vol_devices ext_vol_mountpoint ext_vol_fs ext_vol_luks ext_vol_opts
        ext_vol_tpm ext_vol_tpm_pcrs ext_vol_recovery ext_vol_existing
        ext_vol_subvol ext_vol_subvol_create
    )

    for shortcut in separate_var separate_home separate_opt; do
        value=${!shortcut:-false}
        is_boolean "$value" || die "$shortcut must be true or false"
        [[ $value == true ]] || continue

        case "$shortcut" in
            separate_var)
                target=/var
                subvolume=${root_subvol}${physical_var_path}
                ;;
            separate_home)
                target=/var/home
                subvolume=${root_subvol}${physical_var_path}/home
                ;;
            separate_opt)
                target=/var/opt
                subvolume=${root_subvol}${physical_var_path}/opt
                ;;
        esac

        for index in "${!ext_vol_mountpoint[@]}"; do
            [[ ${ext_vol_mountpoint[$index]} != "$target" ]] ||
                die "$shortcut conflicts with an explicit external volume at $target"
        done

        insertion=${#ext_vol_devices[@]}
        max_index=$((insertion - 1))
        for array_name in "${ext_volume_arrays[@]}"; do
            declare -n array_ref="$array_name"
            for old_index in "${!array_ref[@]}"; do
                ((old_index > max_index)) && max_index=$old_index
                if [[ ${array_name} == ext_vol_mountpoint && ${array_ref[$old_index]} == "$target"/* && old_index -lt insertion ]]; then
                    insertion=$old_index
                fi
            done
        done
        for array_name in "${ext_volume_arrays[@]}"; do
            declare -n array_ref="$array_name"
            for ((old_index = max_index; old_index >= insertion; old_index--)); do
                if [[ ${array_ref[$old_index]+set} == set ]]; then
                    array_ref[old_index + 1]=${array_ref[$old_index]}
                else
                    unset "array_ref[$((old_index + 1))]"
                fi
            done
        done
        index=$insertion
        ext_vol_devices[index]=/dev/disk/by-label/$root_fs_label
        ext_vol_mountpoint[index]=$target
        ext_vol_fs[index]=btrfs
        ext_vol_opts[index]=$state_mount_options
        ext_vol_luks[index]=
        ext_vol_tpm[index]=false
        ext_vol_tpm_pcrs[index]=
        ext_vol_recovery[index]=false
        ext_vol_existing[index]=false
        ext_vol_subvol[index]=$subvolume
        ext_vol_subvol_create[index]=true
        log "Normalized $shortcut shortcut to root-backed external volume at $target (index $index)"
    done

    # Do not leave shortcut state available to any downstream phase.  The
    # normalized arrays are the sole representation after this point.
    unset separate_var separate_home separate_opt
}

# A root-backed record is the narrow exception to the ordinary external volume
# contract: it selects a Btrfs subvolume in the root filesystem rather than
# describing a new whole-disk filesystem.  Keep this classifier based only on
# the normalized record shape.  In particular, do not resolve the future
# /dev/disk/by-label/root path while validating it as an independent device.
label_for_mount() {
    local mount_point=$1
    local filesystem=$2
    local label
    case "$mount_point" in
        /root) label=roothome ;;
        /root/*) label=roothome_${mount_point#/root/} ;;
        /usr/local) label=usrlocal ;;
        /usr/local/*) label=usrlocal_${mount_point#/usr/local/} ;;
        *) label=${mount_point#/} ;;
    esac
    label=${label,,}
    label=${label//\//_}
    label=${label//[^a-z0-9_]/_}

    local limit
    limit=$(filesystem_label_limit "$filesystem")
    printf '%s\n' "${label:0:limit}"
}

filesystem_label_limit() {
    case "$1" in
        xfs) printf '%s\n' 12 ;;
        ext4) printf '%s\n' 16 ;;
        btrfs) printf '%s\n' 255 ;;
        *) die "unsupported external filesystem: $1" ;;
    esac
}

device_is_descendant_of() {
    local device=$1
    local ancestor=$2
    lsblk -nrpo NAME "$ancestor" | awk -v device="$device" '$1 == device { found=1 } END { exit !found }'
}

# Reject mount options that would make installer-created filesystems read-only
# or select an existing Btrfs subvolume.  Match comma-delimited option tokens
# exactly so option names and values that merely contain these strings remain
# valid.  The caller is responsible for rejecting ':' where its karg format
# uses colon-delimited mount-extra serialization.
validate_created_mount_options() {
    local options=$1
    local filesystem=$2
    local description=${3:-mount options}
    local -a option_tokens=()
    local option_token

    IFS=, read -r -a option_tokens <<< "$options"
    for option_token in "${option_tokens[@]}"; do
        case "$filesystem:$option_token" in
            btrfs:ro | btrfs:subvol=* | btrfs:subvolid=*)
                die "$description cannot contain installer-incompatible option: $option_token"
                ;;
            ext4:ro | xfs:ro)
                die "$description cannot contain installer-incompatible option: $option_token"
                ;;
        esac
    done
}

# Validate the indexes of one of the per external volume indexed arrays. Required
# arrays must be dense because all storage operations consume them by position;
# optional arrays may omit an entry, but an entry must still belong to a real
# external volume record.
validate_ext_vol_array_indexes() {
    local name=$1
    local count=$2
    local required=$3
    local index
    local -n values=$name

    for index in "${!values[@]}"; do
        [[ $index =~ ^[0-9]+$ ]] || die "$name has an invalid index: $index"
        ((index < count)) || die "${name}[$index] is outside external volume range 0..$((count - 1))"
    done

    if [[ $required == true ]]; then
        ((${#values[@]} == count)) || die "$name must match ext_vol_devices length"
        for ((index = 0; index < count; index++)); do
            [[ ${values[$index]+set} == set ]] || die "$name is missing required index: $index"
        done
    fi
}

validate_storage_label() {
    local label=$1 description=$2 limit=$3
    [[ $label =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
        die "$description must start with a lower-case letter or digit and contain only lower-case letters, digits, '_' or '-': $label"
    ((${#label} <= limit)) || die "$description is too long (maximum $limit characters): $label"
}

is_safe_relative_subvolume() {
    local path=${1:-} component
    [[ -n $path && $path != /* && $path != */ && $path != *//* ]] || return 1
    [[ $path != *[[:space:]]* && $path != *,* && $path != *:* && $path != *$'\n'* ]] || return 1
    IFS=/ read -r -a components <<< "$path"
    for component in "${components[@]}"; do
        [[ $component != . && $component != .. && -n $component ]] || return 1
    done
}

validate_root_volume_config() {
    validate_storage_label "$root_fs_label" root_fs_label 255
    validate_storage_label "$root_partition_label" root_partition_label 36
    validate_storage_label "$root_luks_label" root_luks_label 48
    [[ $root_partition_label != boot && $root_partition_label != boot_efi ]] ||
        die "root_partition_label must be distinct from the predefined boot partition labels"
    [[ $root_fs_label != boot && $root_fs_label != boot_efi ]] ||
        die "root_fs_label must be distinct from the predefined boot filesystem labels"
    is_safe_relative_subvolume "$root_subvol" ||
        die "root_subvol must be a normalized relative Btrfs subvolume path: $root_subvol"
    if [[ $root_encrypted == true ]]; then
        [[ $root_fs_label != "$root_luks_label" ]] ||
            die "root_fs_label and root_luks_label must be distinct when root encryption is enabled"
    fi
}

# Build aligned internal records from the public configuration arrays. Every
# subsequent lifecycle phase operates on this normalized description.
normalize_internal_volumes() {
    local index record_index count=${#ext_vol_devices[@]}

    vol_role=() vol_public_index=() vol_backing_index=() vol_device=() vol_parent_disk=()
    vol_partition_index=() vol_partition_size=() vol_partition_type=()
    vol_partition_label=() vol_mountpoint=() vol_fs=() vol_fs_label=()
    vol_opts=() vol_luks=() vol_luks_label=() vol_tpm=() vol_tpm_pcrs=()
    vol_recovery=() vol_existing=() vol_subvol=() vol_subvol_create=()
    vol_install_phase=() vol_source_resolved=() vol_luks_uuid_resolved=()
    vol_partition_resolved=() vol_label_resolved=()

    vol_role[0]=efi; vol_public_index[0]=-1; vol_backing_index[0]=
    vol_device[0]=/dev/disk/by-partlabel/boot_efi; vol_parent_disk[0]=${target_disk_real:-${target_disk:-}}
    vol_partition_index[0]=1; vol_partition_size[0]=$efi_size_mib
    vol_partition_type[0]=EF00; vol_partition_label[0]=boot_efi
    vol_mountpoint[0]=/boot/efi; vol_fs[0]=vfat; vol_fs_label[0]=boot_efi
    vol_opts[0]=defaults; vol_luks[0]=; vol_luks_label[0]=
    vol_tpm[0]=false; vol_tpm_pcrs[0]=; vol_recovery[0]=false
    vol_existing[0]=false; vol_subvol[0]=; vol_subvol_create[0]=false
    vol_install_phase[0]=predeploy; vol_partition_resolved[0]=${efi_partition:-}

    vol_role[1]=boot; vol_public_index[1]=-1; vol_backing_index[1]=
    vol_device[1]=/dev/disk/by-partlabel/boot; vol_parent_disk[1]=${target_disk_real:-${target_disk:-}}
    vol_partition_index[1]=2; vol_partition_size[1]=$boot_size_mib
    vol_partition_type[1]=BC13C2FF-59E6-4262-A352-B275FD6F7172
    vol_partition_label[1]=boot; vol_mountpoint[1]=/boot; vol_fs[1]=ext4
    vol_fs_label[1]=boot; vol_opts[1]=defaults; vol_luks[1]=; vol_luks_label[1]=
    vol_tpm[1]=false; vol_tpm_pcrs[1]=; vol_recovery[1]=false
    vol_existing[1]=false; vol_subvol[1]=; vol_subvol_create[1]=false
    vol_install_phase[1]=predeploy; vol_partition_resolved[1]=${boot_partition:-}

    vol_role[2]=root; vol_public_index[2]=-1; vol_backing_index[2]=
    vol_device[2]=/dev/disk/by-partlabel/$root_partition_label
    vol_parent_disk[2]=${target_disk_real:-${target_disk:-}}; vol_partition_index[2]=3
    vol_partition_size[2]=remainder; vol_partition_type[2]=$(root_partition_guid)
    vol_partition_label[2]=$root_partition_label; vol_mountpoint[2]=/
    vol_fs[2]=btrfs; vol_fs_label[2]=$root_fs_label; vol_opts[2]=subvol=$root_subvol,$root_mount_options
    vol_luks[2]=; [[ $root_encrypted == true ]] && vol_luks[2]=$luks_name
    vol_luks_label[2]=$root_luks_label; vol_tpm[2]=$root_tpm2
    vol_tpm_pcrs[2]=$root_tpm2_pcrs; vol_recovery[2]=$root_tpm2_recovery
    vol_existing[2]=false; vol_subvol[2]=$root_subvol; vol_subvol_create[2]=true
    vol_install_phase[2]=predeploy; vol_partition_resolved[2]=${root_partition:-}
    vol_source_resolved[2]=/dev/disk/by-label/$root_fs_label
    vol_label_resolved[2]=$root_fs_label

    for ((index = 0; index < count; index++)); do
        record_index=$((index + 3))
        vol_role[record_index]=ext
        vol_public_index[record_index]=$index
        vol_backing_index[record_index]=
        vol_device[record_index]=${ext_vol_devices[$index]}
        vol_parent_disk[record_index]=
        vol_partition_index[record_index]=
        vol_partition_size[record_index]=
        vol_partition_type[record_index]=
        vol_partition_label[record_index]=
        vol_mountpoint[record_index]=${ext_vol_mountpoint[$index]}
        vol_fs[record_index]=${ext_vol_fs[$index]}
        vol_fs_label[record_index]=
        vol_opts[record_index]=${ext_vol_opts[$index]:-defaults}
        vol_luks[record_index]=${ext_vol_luks[$index]:-}
        vol_luks_label[record_index]=
        vol_tpm[record_index]=${ext_vol_tpm[$index]:-false}
        vol_tpm_pcrs[record_index]=${ext_vol_tpm_pcrs[$index]:-}
        vol_recovery[record_index]=${ext_vol_recovery[$index]:-false}
        vol_existing[record_index]=${ext_vol_existing[$index]:-false}
        vol_subvol[record_index]=${ext_vol_subvol[$index]:-}
        vol_subvol_create[record_index]=${ext_vol_subvol_create[$index]:-false}
        vol_install_phase[record_index]=postdeploy
        # A root-labelled Btrfs subvolume is a relation to the root record,
        # not another destructive device.  The relation is resolved once here
        # and is consumed by every later storage phase.
        if vol_is_root_relation "$record_index"; then
            vol_backing_index[record_index]=2
            vol_source_resolved[record_index]=/dev/disk/by-label/$root_fs_label
            vol_fs_label[record_index]=$root_fs_label
            vol_label_resolved[record_index]=$root_fs_label
        fi
    done
}

vol_is_root_relation() {
    local index=$1 subvolume=${vol_subvol[$1]:-}
    [[ ${vol_device[$index]:-} == /dev/disk/by-label/$root_fs_label &&
        ${vol_fs[$index]:-} == btrfs && -z ${vol_luks[$index]:-} &&
        ${vol_tpm[$index]:-false} == false && -z ${vol_tpm_pcrs[$index]:-} &&
        ${vol_recovery[$index]:-false} == false ]] || return 1
    [[ $subvolume == "$root_subvol" || $subvolume == "$root_subvol"/* ]]
}

vol_validate_device() {
    local index=$1 device=${vol_device[$1]} existing=${vol_existing[$1]:-false}
    local real type mounted mapped
    vol_is_root_relation "$index" && return 0
    real=$(readlink -f -- "$device")
    [[ -b $real ]] || die "external volume device is not a block device: $device"
    type=$(lsblk -ndo TYPE "$real")
    if [[ $existing == false ]]; then
        [[ $type == disk ]] || die "external volume device must be a whole disk: $device"
    else
        case "$type" in disk | part | lvm | crypt | dm) ;; *) die "existing external volume device must be a disk, partition, LV, or mapper: $device" ;; esac
        if [[ -n ${vol_luks[$index]:-} ]]; then
            case $type in crypt | dm) die "existing encrypted external volume must use its underlying block device: $device" ;; esac
        fi
    fi
    if [[ $real == "$target_disk_real" ]] || device_is_descendant_of "$real" "$target_disk_real"; then
        die "external volume device reuses target_disk: $device"
    fi
    mounted=$(lsblk -nrpo MOUNTPOINTS "$real" | awk 'NF { print; exit }')
    [[ -z $mounted ]] || die "external volume disk has a mounted filesystem at $mounted"
    mapped=$(lsblk -nrpo TYPE "$real" | awk '$1 ~ /^(crypt|lvm|raid)/ { print; exit }')
    [[ -z $mapped ]] || die "external volume disk has an active mapped descendant of type $mapped"
    [[ ${volume_seen_devices[$real]:-} != 1 ]] || die "external volume device is listed more than once: $device"
    volume_seen_devices[$real]=1
}

vol_validate_mount_target() {
    local index=$1 point=${vol_mountpoint[$1]}
    is_normalized_absolute_path "$point" || die "external volume mountpoint must be absolute and normalized: $point"
    case ${vol_device[$index]} in *:* | *$'\n'*) die "external volume device cannot contain ':' or a newline: ${vol_device[$index]}" ;; esac
    case "$point" in
        /usr/local | /usr/local/*) ;; / | /boot | /boot/* | /etc | /etc/* | /usr | /usr/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /sysroot | /sysroot/* | /state | /state/*) die "external volume mountpoint is not a supported stateful path: $point" ;;
    esac
    validate_backend_mount_target "$point"
    [[ ${volume_seen_paths[$point]:-} != 1 ]] || die "external volume mountpoint is listed more than once: $point"
    volume_seen_paths[$point]=1
}

vol_validate_mount_format() {
    local index=$1 point=${vol_mountpoint[$1]} fs=${vol_fs[$1]} existing=${vol_existing[$1]:-false}
    local opts=${vol_opts[$1]:-defaults} subvol=${vol_subvol[$1]:-}
    local public_index=${vol_public_index[$1]:-$1}
    is_boolean "${vol_subvol_create[$index]:-false}" ||
        die "ext_vol_subvol_create[$public_index] must be true or false"
    if [[ $existing == false ]]; then
        case "$fs" in btrfs | ext4 | xfs) ;; *) die "external volume filesystem must be btrfs, ext4, or xfs: $point" ;; esac
        validate_created_mount_options "$opts" "$fs" "external volume options for $point"
    else
        [[ -n $fs ]] || die "external volume filesystem must not be empty for an existing volume: $point"
    fi
    case $fs in *:* | *$'\n'*) die "external volume filesystem cannot contain ':' or a newline" ;; esac
    [[ $opts != *:* ]] || die "external volume options cannot contain ':': $point"
    if [[ -n $subvol ]]; then
        [[ $fs == btrfs ]] || die "external volume subvolume requires a Btrfs filesystem: $point"
        is_safe_relative_subvolume "$subvol" || die "external volume subvolume must be a normalized relative Btrfs subvolume path: $subvol"
        case $opts in subvol=* | *,subvol=* | subvolid=* | *,subvolid=*) die "external volume options cannot contain subvol= or subvolid= when ext_vol_subvol is set" ;; esac
    fi
    if [[ ${vol_subvol_create[$index]:-false} == true ]]; then
        [[ -n $subvol ]] || die "ext_vol_subvol_create[$public_index] requires ext_vol_subvol[$public_index]"
    fi
}

vol_validate_mount() {
    vol_validate_mount_target "$1"
    vol_validate_mount_format "$1"
}

vol_validate_crypto() {
    local index=$1 luks=${vol_luks[$1]:-} tpm=${vol_tpm[$1]:-false} recovery=${vol_recovery[$1]:-false}
    local existing=${vol_existing[$1]:-false} point=${vol_mountpoint[$1]}
    local public_index=${vol_public_index[$1]:-$1}
    is_boolean "$tpm" || die "ext_vol_tpm[$public_index] must be true or false"
    is_boolean "$recovery" || die "ext_vol_recovery[$public_index] must be true or false"
    is_boolean "$existing" || die "ext_vol_existing[$public_index] must be true or false"
    vol_existing[index]=$existing
    [[ ${vol_tpm_pcrs[$index]:-} != *$'\n'* ]] || die "ext_vol_tpm_pcrs[$public_index] cannot contain a newline"
    if [[ $tpm == true ]]; then
        [[ -n $luks ]] || die "TPM enrollment requires encryption for external volume: $point"
        tpm_enrollment_requested=true
    elif [[ $recovery == true ]]; then
        die "TPM recovery enrollment requires ext_vol_tpm[$public_index]=true: $point"
    elif [[ -n ${vol_tpm_pcrs[$index]:-} ]]; then
        die "ext_vol_tpm_pcrs[$public_index] requires ext_vol_tpm[$public_index]=true"
    fi
    [[ -z $luks ]] && return 0
    [[ $luks =~ ^[a-z0-9][a-z0-9_]*$ ]] || die "ext_vol_luks[$public_index] must be lower case: $luks"
    ((${#luks} <= 127)) || die "external volume LUKS mapping name is too long: $luks"
    [[ -z ${volume_seen_luks[$luks]:-} ]] || die "external volume LUKS mapping name is duplicated: $luks"
    [[ ! -e /dev/mapper/$luks ]] || die "external volume LUKS mapping is already active: $luks"
    volume_seen_luks[$luks]=1
}

vol_resolve_record() {
    local index=$1 fs=${vol_fs[$1]} point=${vol_mountpoint[$1]} label
    local existing=${vol_existing[$1]:-false}
    if vol_is_root_relation "$index"; then
        vol_source_resolved[index]=/dev/disk/by-label/$root_fs_label
        vol_fs_label[index]=$root_fs_label
        vol_label_resolved[index]=$root_fs_label
        return 0
    fi
    [[ $existing == true ]] && { vol_source_resolved[index]=${vol_device[$index]}; return 0; }
    label=$(label_for_mount "$point" "$fs")
    [[ -z ${volume_seen_labels[$label]:-} ]] || die "external volume label is duplicated: $label"
    volume_seen_labels[$label]=1
    assert_label_available "/dev/disk/by-label/$label" "$(readlink -f -- "${vol_device[$index]}")"
    vol_fs_label[index]=$label
    vol_label_resolved[index]=$label
    vol_source_resolved[index]=/dev/disk/by-label/$label
    if [[ -n ${vol_luks[$index]:-} ]]; then
        local luks_label=${label:0:43}_luks
        [[ -z ${volume_seen_labels[$luks_label]:-} ]] || die "external volume LUKS label is duplicated: $luks_label"
        volume_seen_labels[$luks_label]=1
        vol_luks_label[index]=$luks_label
    fi
}

validate_vol_config() {
    local count=${#ext_vol_devices[@]} index earlier record_index required optional
    validate_root_volume_config
    for required in ext_vol_devices ext_vol_mountpoint ext_vol_fs; do validate_ext_vol_array_indexes "$required" "$count" true; done
    for optional in ext_vol_luks ext_vol_opts ext_vol_tpm ext_vol_tpm_pcrs ext_vol_recovery ext_vol_existing ext_vol_subvol ext_vol_subvol_create; do validate_ext_vol_array_indexes "$optional" "$count" false; done
    local -A volume_seen_devices=() volume_seen_labels=([boot_efi]=1 [boot]=1 ["$root_fs_label"]=1 ["$root_luks_label"]=1) volume_seen_paths=() volume_seen_luks=()
    volume_seen_luks["${luks_name:-root}"]=1
    if [[ $root_encrypted == true && -e /dev/mapper/${luks_name:-root} ]]; then
        die "configured root LUKS mapping is already active: ${luks_name:-root}"
    fi
    normalize_internal_volumes
    for ((index = 0; index < count; index++)); do
        record_index=$((index + 3))
        vol_validate_device "$record_index"
        vol_validate_mount "$record_index"
        vol_validate_crypto "$record_index"
        if [[ ${vol_existing[$record_index]} == false && ${vol_fs[$record_index]} == xfs ]]; then
            require_commands mkfs.xfs
        fi
        vol_resolve_record "$record_index"
    done
    for ((index = 0; index < count; index++)); do
        record_index=$((index + 3))
        for ((earlier = 0; earlier < index; earlier++)); do
            local earlier_record=$((earlier + 3))
            [[ ${vol_mountpoint[$earlier_record]} != "${vol_mountpoint[$record_index]}"/* ]] ||
                die "parent external volume ${vol_mountpoint[$earlier_record]} must precede ${vol_mountpoint[$record_index]}"
        done
    done
}
initialize_recovery_key_output() {
    [[ -n $recovery_key_output_file ]] || return 0

    local output_dir=${recovery_key_output_file%/*}
    [[ -n $output_dir ]] || output_dir=/
    mkdir -p "$output_dir"
    [[ ! -L $recovery_key_output_file ]] || die "recovery_key_output_file must not be a symlink"
    install -m 0600 /dev/null "$recovery_key_output_file"
}

capture_recovery_key() {
    local output_name=$1
    local device=$2
    shift 2
    local captured_output status

    if captured_output=$(SYSTEMD_COLORS=0 systemd-cryptenroll "$@" --recovery-key "$device"); then
        status=0
    else
        status=$?
    fi
    printf -v "$output_name" '%s' "$captured_output"
    return "$status"
}

test_recovery_key() {
    local key_name=$1
    local device=$2
    local status

    if printf '%s' "${!key_name}" | cryptsetup open --test-passphrase --key-file=- "$device"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

validate_recovery_key() {
    local key_name=$1
    local status

    if [[ ${!key_name} =~ ^[bcdefghijklnrtuv]{8}(-[bcdefghijklnrtuv]{8}){7}$ ]]; then
        status=0
    else
        status=1
    fi
    return "$status"
}

write_recovery_key_record() {
    local uuid_name=$1
    local key_name=$2
    local output_file=$3
    local status

    if printf '%s %s\n' "${!uuid_name}" "${!key_name}" >>"$output_file"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

create_ephemeral_luks_key() {
    local output_name=$1
    local generated_key_file

    generated_key_file=$(mktemp "$work_root/luks-key.XXXXXX")
    chmod 0600 "$generated_key_file"
    dd if=/dev/urandom of="$generated_key_file" bs=64 count=1 status=none
    temporary_luks_key_files+=("$generated_key_file")
    printf -v "$output_name" '%s' "$generated_key_file"
}

luks_key_file_for_volume() {
    local output_name=$1

    if [[ -n $luks_password_file ]]; then
        printf -v "$output_name" '%s' "$luks_password_file"
    elif [[ $luks_ephemeral_key == true ]]; then
        create_ephemeral_luks_key "$output_name"
    else
        printf -v "$output_name" '%s' ''
    fi
}

remove_temporary_luks_key() {
    local key_file=$1
    local index

    [[ $luks_ephemeral_key == true && -n $key_file ]] || return 0
    rm -f -- "$key_file"
    for ((index = 0; index < ${#temporary_luks_key_files[@]}; index++)); do
        if [[ ${temporary_luks_key_files[$index]} == "$key_file" ]]; then
            unset 'temporary_luks_key_files[index]'
            break
        fi
    done
}

vol_remove_credential() {
    local variable_name=$1
    unset "$variable_name"
}

remove_temporary_credential() {
    local key_file=$1
    local index

    [[ -n $key_file ]] || return 0
    rm -f -- "$key_file"
    for ((index = 0; index < ${#temporary_credential_files[@]}; index++)); do
        if [[ ${temporary_credential_files[$index]} == "$key_file" ]]; then
            unset 'temporary_credential_files[index]'
            break
        fi
    done
}

root_partition_guid() {
    if [[ -n ${root_partition_type_guid:-} ]]; then
        validate_canonical_guid "$root_partition_type_guid" root_partition_type_guid
        printf '%s\n' "$root_partition_type_guid"
        return
    fi

    case "$(uname -m)" in
        x86_64) printf '%s\n' '4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709' ;;
        aarch64) printf '%s\n' 'B921B045-1DF0-41C3-AF44-4C6F280D3FAE' ;;
        *) die "set root_partition_type_guid for architecture $(uname -m)" ;;
    esac
}

assert_label_available() {
    local path=$1
    local allowed_disk=${2:-$target_disk_real}
    [[ ! -e $path ]] && return

    local existing parent
    existing=$(readlink -f -- "$path")
    parent=$(lsblk -nrpo PKNAME "$existing" | head -n1)
    [[ $existing == "$allowed_disk" || $parent == "$allowed_disk" ]] ||
        die "global device label already belongs to another disk: $path"
}

wait_for_device() {
    local path=$1
    local remaining=30
    while ((remaining > 0)); do
        udevadm settle
        [[ -b $path ]] && return
        sleep 1
        ((remaining--))
    done
    die "timed out waiting for device path: $path"
}

verify_partition_path() {
    local path=$1
    local resolved parent
    resolved=$(readlink -f -- "$path")
    parent=$(lsblk -nrpo PKNAME "$resolved" | head -n1)
    [[ $parent == "$target_disk_real" ]] || die "$path does not belong to $target_disk"
}

vol_clear_parent() {
    local parent=$1
    log "Erasing storage parent $parent"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS "$parent"
    wipefs --all --force "$parent"
    sgdisk --zap-all "$parent"
}

vol_prepare_partitions() {
    local -A parents=()
    local parent index size
    local -a args=()
    for index in "${!vol_role[@]}"; do
        parent=${vol_parent_disk[$index]:-}
        [[ -n ${vol_partition_index[$index]:-} && -n $parent ]] || continue
        parents[$parent]=1
    done
    for parent in "${!parents[@]}"; do
        vol_clear_parent "$parent"
        args=()
        for index in "${!vol_role[@]}"; do
            [[ ${vol_parent_disk[$index]:-} == "$parent" && -n ${vol_partition_index[$index]:-} ]] || continue
            size=${vol_partition_size[$index]}
            if [[ $size == remainder ]]; then args+=("--new=${vol_partition_index[$index]}:0:0"); else args+=("--new=${vol_partition_index[$index]}:0:+${size}MiB"); fi
            args+=("--typecode=${vol_partition_index[$index]}:${vol_partition_type[$index]}" "--change-name=${vol_partition_index[$index]}:${vol_partition_label[$index]}")
        done
        sgdisk "${args[@]}" "$parent"
    done
    udevadm settle
    for index in "${!vol_role[@]}"; do
        [[ -n ${vol_partition_index[$index]:-} ]] || continue
        vol_partition_resolved[index]=/dev/disk/by-partlabel/${vol_partition_label[$index]}
        wait_for_device "${vol_partition_resolved[$index]}"
        verify_partition_path "${vol_partition_resolved[$index]}"
    done
}

enroll_luks_credentials() {
    local volume=$1
    local device=$2
    local luks_uuid=$3
    local tpm2=$4
    local tpm2_pcrs=$5
    local tpm2_recovery=$6
    local unlock_key_file=${7:-}

    [[ $tpm2 == true ]] || return 0

    local -a unlock_args=()
    [[ -n $unlock_key_file ]] && unlock_args+=("--unlock-key-file=$unlock_key_file")

    if [[ $tpm2_recovery == true ]]; then
        local recovery_key
        log "Enrolling a recovery key for $volume"
        capture_recovery_key recovery_key "$device" "${unlock_args[@]}"
        validate_recovery_key recovery_key ||
            die "systemd-cryptenroll returned an invalid recovery key for $volume"
        test_recovery_key recovery_key "$device" ||
            die "generated recovery key did not unlock $volume"
        write_recovery_key_record luks_uuid recovery_key "$recovery_key_output_file"
    fi

    local -a enroll_args=(--tpm2-device=auto)
    if [[ -n $tpm2_pcrs ]]; then
        enroll_args+=("--tpm2-pcrs=$tpm2_pcrs")
    fi
    log "Enrolling TPM2 unlock for $volume"
    systemd-cryptenroll "${unlock_args[@]}" "${enroll_args[@]}" "$device"
}

vol_format_filesystem() {
    local index=$1 device=$2 fs=${vol_fs[$1]} label=${vol_fs_label[$1]}
    case "$fs" in
        btrfs) mkfs.btrfs -f -L "$label" "$device" ;;
        ext4) mkfs.ext4 -F -L "$label" "$device" ;;
        xfs) mkfs.xfs -f -L "$label" "$device" ;;
        vfat) mkfs.vfat -F 32 -n "$label" "$device" ;;
        *) die "unsupported filesystem: $fs" ;;
    esac
}

vol_materialize_credential() {
    local output_name=$1 variable_name=$2
    local credential=${!variable_name-} file=''
    if [[ -n $credential ]]; then
        file=$(mktemp "$work_root/vol-key.XXXXXX"); chmod 0600 "$file"; printf '%s' "$credential" >"$file"; temporary_credential_files+=("$file")
    fi
    external_credential_variables+=("$variable_name")
    printf -v "$output_name" '%s' "$file"
}

vol_activate_luks() {
    local index=$1 existing=${vol_existing[$1]:-false} name=${vol_luks[$1]} device key_file='' uuid=''
    local -a open_args=(--type luks) format_args=(--type luks2 --label "${vol_luks_label[$index]}")
    device=${vol_partition_resolved[$index]:-${vol_device[$index]}}
    if [[ $existing == true ]]; then
        device=$(readlink -f -- "$device")
        vol_materialize_credential key_file "lvc_$name"
    else
        luks_key_file_for_volume key_file
        [[ -z $key_file ]] || format_args+=(--batch-mode --key-file "$key_file")
        log "Creating LUKS2 container ${vol_luks_label[$index]}"
        cryptsetup luksFormat "${format_args[@]}" "$device"
    fi
    [[ -z $key_file ]] || open_args+=(--key-file "$key_file")
    cryptsetup open "${open_args[@]}" "$device" "$name"
    opened_luks_names+=("$name")
    uuid=$(cryptsetup luksUUID "$device")
    [[ -n $uuid ]] || die "could not determine LUKS UUID for ${vol_mountpoint[$index]}"
    vol_luks_uuid_resolved[index]=$uuid
    vol_source_resolved[index]=/dev/mapper/$name
    enroll_luks_credentials "${vol_mountpoint[$index]}" "$device" "$uuid" "${vol_tpm[$index]}" "${vol_tpm_pcrs[$index]}" "${vol_recovery[$index]}" "$key_file"
    if [[ $existing == false && $luks_ephemeral_key == true ]]; then
        systemd-cryptenroll --wipe-slot=password "$device"
        remove_temporary_luks_key "$key_file"
    fi
    [[ $existing == true ]] || return 0
    [[ -z $key_file ]] || remove_temporary_credential "$key_file"
    vol_remove_credential "lvc_$name"
}

vol_verify_subvolume() {
    local index=$1 source=${vol_source_resolved[$1]:-} type
    [[ -n ${vol_subvol[$index]:-} ]] || return 0
    type=$(blkid -s TYPE -o value "$source")
    [[ $type == btrfs ]] || die "external volume subvolume requires a Btrfs backing filesystem at ${vol_mountpoint[$index]} (found ${type:-unknown})"
}

vol_prepare_existing() {
    local index
    for index in "${!vol_role[@]}"; do
        [[ ${vol_existing[$index]:-false} == true ]] || continue
        if [[ -n ${vol_luks[$index]:-} ]]; then vol_activate_luks "$index"; else vol_source_resolved[index]=${vol_device[$index]}; fi
        vol_verify_subvolume "$index"
    done
}

vol_prepare_filesystems() {
    local index device label filesystem_uuid
    for index in "${!vol_role[@]}"; do
        [[ ${vol_existing[$index]:-false} == false && -z ${vol_backing_index[$index]:-} ]] || continue
        [[ -n ${vol_partition_index[$index]:-} ]] || vol_clear_parent "$(readlink -f -- "${vol_device[$index]}")"
        device=${vol_partition_resolved[$index]:-${vol_device[$index]}}
        [[ -n ${vol_luks[$index]:-} ]] && vol_activate_luks "$index" && device=${vol_source_resolved[$index]}
        vol_format_filesystem "$index" "$device"
        label=${vol_fs_label[$index]}
        udevadm settle
        if [[ -n $label ]]; then
            wait_for_device "/dev/disk/by-label/$label"
            vol_source_resolved[index]=/dev/disk/by-label/$label
            filesystem_uuid=$(blkid -s UUID -o value "/dev/disk/by-label/$label")
            [[ -n $filesystem_uuid ]] || die "could not determine filesystem UUID for $label"
            case "$label" in
                boot) boot_filesystem_uuid=$filesystem_uuid ;;
                boot_efi) efi_filesystem_uuid=$filesystem_uuid ;;
            esac
        fi
        vol_label_resolved[index]=$label
    done
}

vol_create_subvolume() {
    local source=$1 path=$2 staging=$3 old_path migrated=false
    mkdir -p "$staging"
    mount -t btrfs -o subvolid=5 "$source" "$staging"
    cleanup_mounts+=("$staging")
    path=$staging/$path
    while [[ $path != "$staging" ]]; do
        [[ ! -L $path ]] || die "volume subvolume is a symlink: ${path#"$staging/"}"
        if [[ -e $path ]]; then [[ -d $path ]] || die "volume subvolume is not a directory: ${path#"$staging/"}"; fi
        path=${path%/*}; [[ -n $path ]] || path=$staging
    done
    path=$staging/${2}
    if ! btrfs subvolume show "$path" >/dev/null 2>&1; then
        if [[ -e $path ]]; then
            old_path="${path}.bootc-installer-old"
            [[ ! -e $old_path && ! -L $old_path ]] || die "temporary migration path already exists: $old_path"
            mv "$path" "$old_path"
            mkdir -p -- "$(dirname -- "$path")"
            migrated=true
        else
            mkdir -p -- "$(dirname -- "$path")"
        fi
        btrfs subvolume create "$path"
        if [[ $migrated == true ]]; then
            chown root:root "$path"; chmod 0755 "$path"
            cp -a --reflink=auto "$old_path/." "$path/"
            rm -rf -- "$old_path"
        fi
    fi
    umount "$staging"
    unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"
}

vol_prepare_subvolumes() {
    local index source
    for index in "${!vol_role[@]}"; do
        [[ ${vol_subvol_create[$index]:-false} == true ]] || continue
        source=${vol_source_resolved[$index]:-}
        [[ -n $source ]] || die "volume source is unavailable for ${vol_mountpoint[$index]}"
        vol_create_subvolume "$source" "${vol_subvol[$index]}" "$work_root/vol-$index-top"
    done
}

vol_mount_options() {
    local output=$1 index=$2 mount_options=${vol_opts[$2]:-defaults}
    [[ -z ${vol_subvol[$index]:-} || $mount_options == subvol=* || $mount_options == *,subvol=* ]] ||
        mount_options="$mount_options,subvol=${vol_subvol[$index]}"
    printf -v "$output" '%s' "$mount_options"
}

vol_mount_phase() {
    local phase=$1 index options target source point depth position candidate candidate_depth
    local -a order=()
    for index in "${!vol_role[@]}"; do
        [[ ${vol_install_phase[$index]} == "$phase" ]] || continue
        point=${vol_mountpoint[$index]}; depth=${point//[^\/]}; [[ $point == / ]] && depth=
        position=0
        for candidate in "${order[@]}"; do
            candidate_depth=${vol_mountpoint[$candidate]//[^\/]}; [[ ${vol_mountpoint[$candidate]} == / ]] && candidate_depth=
            ((${#candidate_depth} <= ${#depth})) || break
            ((position++))
        done
        order=("${order[@]:0:position}" "$index" "${order[@]:position}")
    done
    while ((${#order[@]})); do
        index=${order[0]}; order=("${order[@]:1}")
        source=${vol_source_resolved[$index]}; target=$install_root${vol_mountpoint[$index]}; vol_mount_options options "$index"
        mkdir -p "$target"
        mount -t "${vol_fs[$index]}" -o "$options" "$source" "$target"
        cleanup_mounts+=("$target")
    done
}

vol_prepare_storage() {
    vol_prepare_existing
    vol_prepare_partitions
    vol_prepare_filesystems
    vol_prepare_subvolumes
    vol_mount_phase predeploy
}
