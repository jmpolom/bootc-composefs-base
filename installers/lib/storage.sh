#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

declare -ag cleanup_mounts=()
declare -ag opened_luks_names=()
declare -ag temporary_luks_key_files=()
declare -ag temporary_credential_files=()
declare -ag external_credential_variables=()
declare -ag ext_vol_labels_resolved=()
declare -ag ext_vol_sources_resolved=()
declare -ag ext_vol_luks_uuids=()
declare -ag ext_vol_luks_labels=()

# Convert the legacy state-subvolume switches into ordinary root-backed external volume
# records before any indexed-array or mount-target validation runs.  The
# generated records deliberately carry no provenance: every later storage
# operation sees the same shape whether a record came from a shortcut or was
# written explicitly by the user.
normalize_ext_vol_shortcuts() {
    local shortcut value target subvolume index insertion_index max_index array_name
    local -n array_ref
    local -a ext_vol_array_names=(
        ext_vol_devices ext_vol_mountpoint ext_vol_fs
        ext_vol_luks ext_vol_opts ext_vol_tpm ext_vol_tpm_pcrs
        ext_vol_recovery ext_vol_existing
    )

    for shortcut in separate_var separate_home separate_opt; do
        value=${!shortcut:-false}
        is_boolean "$value" || die "$shortcut must be true or false"
        [[ $value == true ]] || continue

        case "$shortcut" in
            separate_var)
                target=/var
                subvolume=root${physical_var_path}
                ;;
            separate_home)
                target=/var/home
                subvolume=root${physical_var_path}/home
                ;;
            separate_opt)
                target=/var/opt
                subvolume=root${physical_var_path}/opt
                ;;
        esac

        for index in "${!ext_vol_mountpoint[@]}"; do
            [[ ${ext_vol_mountpoint[$index]} != "$target" ]] ||
                die "$shortcut conflicts with an explicit external volume at $target"
        done

        # Insert a generated parent immediately before the first explicit
        # descendant.  Otherwise append after the highest defined index.  Use
        # all arrays when finding the append position so malformed optional
        # indexes cannot be overwritten and hidden by normalization.
        max_index=-1
        for array_name in "${ext_vol_array_names[@]}"; do
            declare -n array_ref="$array_name"
            for index in "${!array_ref[@]}"; do
                if ((index > max_index)); then
                    max_index=$index
                fi
            done
        done
        insertion_index=$((max_index + 1))
        for index in "${!ext_vol_mountpoint[@]}"; do
            if [[ ${ext_vol_mountpoint[$index]} == "$target"/* ]] &&
                ((index < insertion_index)); then
                insertion_index=$index
            fi
        done

        # Shift every array independently so sparse holes remain holes.  An
        # assignment through ${array[@]} would densify the arrays and could
        # make a required missing index appear valid.
        for array_name in "${ext_vol_array_names[@]}"; do
            declare -n array_ref="$array_name"
            local -a shifted=()
            local old_index new_index
            for old_index in "${!array_ref[@]}"; do
                if ((old_index >= insertion_index)); then
                    new_index=$((old_index + 1))
                else
                    new_index=$old_index
                fi
                shifted[new_index]=${array_ref[old_index]}
            done
            array_ref=()
            for new_index in "${!shifted[@]}"; do
                array_ref[new_index]=${shifted[new_index]}
            done
        done

        index=$insertion_index
        ext_vol_devices[index]=/dev/disk/by-label/root
        ext_vol_mountpoint[index]=$target
        ext_vol_fs[index]=btrfs
        ext_vol_opts[index]="subvol=$subvolume,$state_mount_options"
        ext_vol_luks[index]=
        ext_vol_tpm[index]=false
        ext_vol_tpm_pcrs[index]=
        ext_vol_recovery[index]=false
        ext_vol_existing[index]=false
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
root_backed_ext_vol_subvolume() {
    local index=$1
    local device=${ext_vol_devices[$index]:-}
    local filesystem=${ext_vol_fs[$index]:-}
    local options=${ext_vol_opts[$index]:-}
    local luks_name=${ext_vol_luks[$index]:-}
    local tpm2=${ext_vol_tpm[$index]:-false}
    local tpm2_pcrs=${ext_vol_tpm_pcrs[$index]:-}
    local tpm2_recovery=${ext_vol_recovery[$index]:-false}
    local existing=${ext_vol_existing[$index]:-false}
    local expected_prefix="root${physical_var_path:-}"
    local subvolume=
    local option_token
    local -a root_backed_option_tokens=()

    [[ $device == /dev/disk/by-label/root && $filesystem == btrfs && $existing == false ]] || return 1
    [[ -z $luks_name && $tpm2 == false && -z $tpm2_pcrs &&
        $tpm2_recovery == false ]] || return 1

    IFS=, read -r -a root_backed_option_tokens <<< "$options"
    for option_token in "${root_backed_option_tokens[@]}"; do
        if [[ $option_token == subvol=* ]]; then
            [[ -z $subvolume ]] || return 1
            subvolume=${option_token#subvol=}
        fi
    done
    [[ -n $subvolume && ($subvolume == "$expected_prefix" || $subvolume == "$expected_prefix"/*) ]] ||
        return 1
    printf '%s\n' "$subvolume"
}

is_root_backed_ext_vol() {
    root_backed_ext_vol_subvolume "$1" >/dev/null
}

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
            [[ -v "values[$index]" ]] || die "$name is missing required index: $index"
        done
    fi
}

# Arrays in this function are initialized dynamically by ensure_indexed_array.
# shellcheck disable=SC2154
validate_ext_vol_config() {
    local count=${#ext_vol_devices[@]}
    local required_array optional_array
    for required_array in ext_vol_devices ext_vol_mountpoint ext_vol_fs; do
        validate_ext_vol_array_indexes "$required_array" "$count" true
    done
    for optional_array in ext_vol_luks ext_vol_opts ext_vol_tpm ext_vol_tpm_pcrs \
        ext_vol_recovery ext_vol_existing; do
        validate_ext_vol_array_indexes "$optional_array" "$count" false
    done

    local root_luks_name=${luks_name:-root}
    local -A seen_devices=() seen_labels=([boot_efi]=1 [boot]=1 [root]=1 [root_luks]=1) seen_paths=() seen_luks_names=()
    local index device device_real mount_point filesystem encrypted label label_limit options luks_name luks_label tpm2 tpm2_pcrs tpm2_recovery existing parent device_type credential_variable
    local root_backed root_subvolume root_option_token
    local -a root_option_tokens=()
    seen_luks_names["$root_luks_name"]=1
    if [[ $root_encrypted == true && -e /dev/mapper/$root_luks_name ]]; then
        die "configured root LUKS mapping is already active: $root_luks_name"
    fi
    ext_vol_labels_resolved=()
    ext_vol_sources_resolved=()
    ext_vol_luks_uuids=()
    ext_vol_luks_labels=()
    for ((index = 0; index < count; index++)); do
        device=${ext_vol_devices[$index]}
        mount_point=${ext_vol_mountpoint[$index]}
        filesystem=${ext_vol_fs[$index]}
        luks_name=${ext_vol_luks[$index]:-}
        encrypted=false
        [[ -n $luks_name ]] && encrypted=true
        tpm2=${ext_vol_tpm[$index]:-false}
        tpm2_pcrs=${ext_vol_tpm_pcrs[$index]:-}
        tpm2_recovery=${ext_vol_recovery[$index]:-false}
        existing=${ext_vol_existing[$index]:-false}
        options=${ext_vol_opts[$index]:-defaults}

        root_backed=false
        if root_subvolume=$(root_backed_ext_vol_subvolume "$index"); then
            root_backed=true
        fi

        [[ $device == /dev/* ]] || die "ext_vol_devices[$index] must be a /dev node path"
        if [[ $root_backed == false ]]; then
            device_real=$(readlink -f -- "$device")
            [[ -b $device_real ]] || die "external volume device is not a block device: $device"
            device_type=$(lsblk -ndo TYPE "$device_real")
            if [[ $existing == false ]]; then
                [[ $device_type == disk ]] || die "external volume device must be a whole disk: $device"
            else
                case "$device_type" in
                    disk | part | lvm | crypt | dm) ;;
                    *) die "existing external volume device must be a disk, partition, LV, or mapper: $device" ;;
                esac
            fi
            if [[ $device_real == "$target_disk_real" ]] || device_is_descendant_of "$device_real" "$target_disk_real"; then
                die "external volume device reuses target_disk: $device"
            fi
            [[ -z ${seen_devices[$device_real]:-} ]] || die "external volume device is listed more than once: $device"
            seen_devices[$device_real]=1

            parent=$(lsblk -nrpo MOUNTPOINTS "$device_real" | awk 'NF { print; exit }')
            [[ -z $parent ]] || die "external volume disk has a mounted filesystem at $parent"
            parent=$(lsblk -nrpo TYPE "$device_real" | awk '$1 ~ /^(crypt|lvm|raid)/ { print; exit }')
            if [[ $existing == false ]]; then
                [[ -z $parent ]] || die "external volume disk has an active mapped descendant of type $parent"
            else
                [[ $device_type != crypt && $device_type != dm ]] || [[ -z $luks_name ]] ||
                    die "existing encrypted external volume must use its underlying block device: $device"
                parent=$(lsblk -nrpo TYPE "$device_real" | awk 'NR > 1 && $1 ~ /^(crypt|lvm|raid)/ { print; exit }')
                [[ -z $parent ]] ||
                    die "existing external volume has an active mapped descendant of type $parent"
            fi
        fi

        [[ $mount_point == /* ]] || die "external volume mountpoint must be absolute: $mount_point"
        is_normalized_absolute_path "$mount_point" || die "external volume mountpoint is not normalized: $mount_point"
        if [[ $existing == true ]]; then
            [[ $device != *:* && $device != *$'\n'* ]] ||
                die "existing external volume device cannot contain ':' or a newline: $device"
        fi
        case "$mount_point" in
            /usr/local | /usr/local/*) ;;
            / | /boot | /boot/* | /etc | /etc/* | /usr | /usr/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | /sysroot | /sysroot/*)
                die "external volume mountpoint is not a supported stateful path: $mount_point"
                ;;
        esac
        validate_backend_mount_target "$mount_point"
        [[ -z ${seen_paths[$mount_point]:-} ]] || die "external volume mountpoint is listed more than once: $mount_point"
        seen_paths[$mount_point]=1

        if [[ $existing == false ]]; then
            case "$filesystem" in
                btrfs) require_commands mkfs.btrfs ;;
                ext4) require_commands mkfs.ext4 ;;
                xfs) require_commands mkfs.xfs ;;
                *) die "ext_vol_fs[$index] must be btrfs, ext4, or xfs" ;;
            esac
        else
            [[ -n $filesystem ]] || die "ext_vol_fs[$index] must not be empty for an existing volume"
        fi
        [[ $filesystem != *:* && $filesystem != *$'\n'* ]] ||
            die "ext_vol_fs[$index] cannot contain ':' or a newline"
        if [[ $root_backed == true ]]; then
            IFS=, read -r -a root_option_tokens <<< "$options"
            for root_option_token in "${root_option_tokens[@]}"; do
                [[ $root_option_token != ro && $root_option_token != subvolid=* ]] ||
                    die "external volume options for $mount_point cannot contain installer-incompatible option: $root_option_token"
            done
        elif [[ $existing == false ]]; then
            validate_created_mount_options "$options" "$filesystem" "external volume options for $mount_point"
        fi
        [[ $options != *:* ]] || die "external volume options cannot contain ':': $mount_point"
        is_boolean "$tpm2" || die "ext_vol_tpm[$index] must be true or false"
        is_boolean "$tpm2_recovery" || die "ext_vol_recovery[$index] must be true or false"
        is_boolean "$existing" || die "ext_vol_existing[$index] must be true or false"
        ext_vol_existing[index]=$existing
        [[ $tpm2_pcrs != *$'\n'* ]] || die "ext_vol_tpm_pcrs[$index] cannot contain a newline"
        if [[ $tpm2 == true ]]; then
            [[ $encrypted == true ]] || die "TPM enrollment requires encryption for external volume: $mount_point"
            tpm_enrollment_requested=true
        elif [[ $tpm2_recovery == true ]]; then
            die "TPM recovery enrollment requires ext_vol_tpm[$index]=true: $mount_point"
        elif [[ -n $tpm2_pcrs ]]; then
            die "ext_vol_tpm_pcrs[$index] requires ext_vol_tpm[$index]=true"
        fi

        if [[ $root_backed == true ]]; then
            label=root
        elif [[ $existing == false ]]; then
            label=$(label_for_mount "$mount_point" "$filesystem")
        else
            ext_vol_sources_resolved[index]=$device
        fi
        if [[ $existing == false ]]; then
            [[ $label =~ ^[a-z0-9][a-z0-9_]*$ ]] || die "external volume label must be lower case: $label"
            label_limit=$(filesystem_label_limit "$filesystem")
            ((${#label} <= label_limit)) || die "$filesystem label is too long for $mount_point: $label"
            if [[ $root_backed == true ]]; then
                [[ $label == root ]] || die "root-backed external volume must use label root: $mount_point"
            else
                [[ -z ${seen_labels[$label]:-} ]] || die "external volume label is duplicated: $label"
                seen_labels[$label]=1
                assert_label_available "/dev/disk/by-label/$label" "$device_real"
            fi
            ext_vol_labels_resolved[index]=$label
            ext_vol_sources_resolved[index]=/dev/disk/by-label/$label
        fi

        if [[ $encrypted == true ]]; then
            [[ $luks_name =~ ^[a-z0-9][a-z0-9_]*$ ]] || die "ext_vol_luks[$index] must be lower case: $luks_name"
            credential_variable=lvc_$luks_name
            [[ $credential_variable =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
                die "ext_vol_luks[$index] does not produce a valid credential variable: $luks_name"
            ((${#luks_name} <= 127)) || die "external volume LUKS mapping name is too long: $luks_name"
            [[ -z ${seen_luks_names[$luks_name]:-} ]] || die "external volume LUKS mapping name is duplicated: $luks_name"
            [[ ! -e /dev/mapper/$luks_name ]] || die "external volume LUKS mapping is already active: $luks_name"
            seen_luks_names[$luks_name]=1
            if [[ $existing == false ]]; then
                luks_label=${label:0:43}_luks
                [[ -z ${seen_labels[$luks_label]:-} ]] || die "external volume LUKS label is duplicated: $luks_label"
                seen_labels[$luks_label]=1
                assert_label_available "/dev/disk/by-label/$luks_label" "$device_real"
                ext_vol_luks_labels[index]=$luks_label
            fi
        fi
    done

    local earlier
    for ((index = 0; index < count; index++)); do
        for ((earlier = 0; earlier < index; earlier++)); do
            if [[ ${ext_vol_mountpoint[$earlier]} == "${ext_vol_mountpoint[$index]}"/* ]]; then
                die "parent external volume ${ext_vol_mountpoint[$index]} must precede ${ext_vol_mountpoint[$earlier]}"
            fi
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

materialize_external_credential() {
    local output_name=$1
    local variable_name=$2
    local credential=${!variable_name-}
    local credential_file=

    if [[ -n $credential ]]; then
        credential_file=$(mktemp "$work_root/ext-vol-key.XXXXXX")
        chmod 0600 "$credential_file"
        printf '%s' "$credential" >"$credential_file"
        temporary_credential_files+=("$credential_file")
    fi
    external_credential_variables+=("$variable_name")
    printf -v "$output_name" '%s' "$credential_file"
}

remove_external_credential() {
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

prepare_existing_ext_volumes() {
    local count=${#ext_vol_devices[@]}
    ((count > 0)) || return 0

    local index device device_real luks_name credential_variable key_file uuid
    for ((index = 0; index < count; index++)); do
        [[ ${ext_vol_existing[$index]:-false} == true ]] || continue
        is_root_backed_ext_vol "$index" && continue
        luks_name=${ext_vol_luks[$index]:-}
        if [[ -z $luks_name ]]; then
            ext_vol_sources_resolved[index]=${ext_vol_devices[$index]}
            continue
        fi

        device=${ext_vol_devices[$index]}
        device_real=$(readlink -f -- "$device")
        credential_variable=lvc_$luks_name
        key_file=
        materialize_external_credential key_file "$credential_variable"
        if [[ -n $key_file ]]; then
            log "Opening existing external LUKS volume $luks_name using its configured credential"
            cryptsetup open --type luks --key-file "$key_file" "$device_real" "$luks_name"
        else
            log "Opening existing external LUKS volume $luks_name; enter its passphrase when prompted"
            cryptsetup open --type luks "$device_real" "$luks_name"
        fi
        opened_luks_names+=("$luks_name")
        uuid=$(cryptsetup luksUUID "$device_real")
        [[ -n $uuid ]] || die "could not determine existing external LUKS UUID: $device"
        ext_vol_luks_uuids[index]=$uuid
        ext_vol_sources_resolved[index]=/dev/mapper/$luks_name
        enroll_luks_credentials "${ext_vol_mountpoint[$index]}" "$device_real" "$uuid" \
            "${ext_vol_tpm[$index]:-false}" "${ext_vol_tpm_pcrs[$index]:-}" \
            "${ext_vol_recovery[$index]:-false}" "$key_file"
        [[ -z $key_file ]] || remove_temporary_credential "$key_file"
        remove_external_credential "$credential_variable"
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

prepare_partitions() {
    log "Preparing GPT on $target_disk ($target_disk_real)"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS "$target_disk_real"
    assert_label_available /dev/disk/by-partlabel/boot_efi
    assert_label_available /dev/disk/by-partlabel/boot
    assert_label_available /dev/disk/by-partlabel/root
    assert_label_available /dev/disk/by-label/boot_efi
    assert_label_available /dev/disk/by-label/boot
    assert_label_available /dev/disk/by-label/root
    if [[ $root_encrypted == true ]]; then
        assert_label_available /dev/disk/by-label/root_luks
    fi

    wipefs --all --force "$target_disk_real"
    sgdisk --zap-all "$target_disk_real"
    sgdisk \
        --new=1:0:+"${efi_size_mib}"MiB --typecode=1:EF00 --change-name=1:boot_efi \
        --new=2:0:+"${boot_size_mib}"MiB --typecode=2:BC13C2FF-59E6-4262-A352-B275FD6F7172 --change-name=2:boot \
        --new=3:0:0 --typecode=3:"$(root_partition_guid)" --change-name=3:root \
        "$target_disk_real"

    udevadm settle
    wait_for_device /dev/disk/by-partlabel/boot_efi
    wait_for_device /dev/disk/by-partlabel/boot
    wait_for_device /dev/disk/by-partlabel/root
    verify_partition_path /dev/disk/by-partlabel/boot_efi
    verify_partition_path /dev/disk/by-partlabel/boot
    verify_partition_path /dev/disk/by-partlabel/root

    efi_partition=/dev/disk/by-partlabel/boot_efi
    boot_partition=/dev/disk/by-partlabel/boot
    root_partition=/dev/disk/by-partlabel/root
}

format_filesystems() {
    log "Formatting boot filesystems"
    mkfs.vfat -F 32 -n boot_efi "$efi_partition"
    efi_filesystem_uuid=$(blkid -s UUID -o value "$efi_partition")
    [[ -n $efi_filesystem_uuid ]] || die "could not determine EFI filesystem UUID"
    mkfs.ext4 -F -L boot "$boot_partition"
    boot_filesystem_uuid=$(blkid -s UUID -o value "$boot_partition")
    [[ -n $boot_filesystem_uuid ]] || die "could not determine /boot filesystem UUID"

    root_block_device=$root_partition
    if [[ $root_encrypted == true ]]; then
        local root_key_file=
        luks_key_file_for_volume root_key_file
        if [[ -n $root_key_file ]]; then
            log "Creating LUKS2 container labeled root_luks using a key file"
            cryptsetup luksFormat --batch-mode --type luks2 --label root_luks --key-file "$root_key_file" "$root_partition"
            cryptsetup open --type luks --key-file "$root_key_file" "$root_partition" "$luks_name"
        else
            log "Creating LUKS2 container labeled root_luks; enter its initial passphrase when prompted"
            cryptsetup luksFormat --type luks2 --label root_luks "$root_partition"
            log "Opening root_luks; enter its passphrase when prompted"
            cryptsetup open --type luks "$root_partition" "$luks_name"
        fi
        root_luks_uuid=$(cryptsetup luksUUID "$root_partition")
        opened_luks_names+=("$luks_name")
        root_block_device=/dev/mapper/$luks_name
        enroll_luks_credentials root "$root_partition" "$root_luks_uuid" "$root_tpm2" "$root_tpm2_pcrs" "$root_tpm2_recovery" "$root_key_file"
        if [[ $luks_ephemeral_key == true ]]; then
            systemd-cryptenroll --wipe-slot=password "$root_partition"
            remove_temporary_luks_key "$root_key_file"
        fi
    fi

    log "Creating Btrfs filesystem labeled root"
    mkfs.btrfs -f -L root "$root_block_device"
    udevadm settle
    wait_for_device /dev/disk/by-label/root
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

format_ext_vol_filesystem() {
    local filesystem=$1
    local label=$2
    local device=$3
    case "$filesystem" in
        btrfs) mkfs.btrfs -f -L "$label" "$device" ;;
        ext4) mkfs.ext4 -F -L "$label" "$device" ;;
        xfs) mkfs.xfs -f -L "$label" "$device" ;;
        *) die "unsupported external filesystem: $filesystem" ;;
    esac
}

prepare_ext_vol_filesystems() {
    local count=${#ext_vol_devices[@]}
    ((count > 0)) || return 0

    log "Preparing $count external volume(s)"
    local index device device_real mount_point filesystem encrypted label luks_name luks_label tpm2 tpm2_pcrs tpm2_recovery block_device uuid key_file
    for ((index = 0; index < count; index++)); do
        if is_root_backed_ext_vol "$index"; then
            log "Using root-backed Btrfs subvolume for ${ext_vol_mountpoint[$index]}"
            continue
        fi
        [[ ${ext_vol_existing[$index]:-false} == false ]] || continue
        device=${ext_vol_devices[$index]}
        device_real=$(readlink -f -- "$device")
        mount_point=${ext_vol_mountpoint[$index]}
        filesystem=${ext_vol_fs[$index]}
        luks_name=${ext_vol_luks[$index]:-}
        encrypted=false
        [[ -n $luks_name ]] && encrypted=true
        tpm2=${ext_vol_tpm[$index]:-false}
        tpm2_pcrs=${ext_vol_tpm_pcrs[$index]:-}
        tpm2_recovery=${ext_vol_recovery[$index]:-false}
        label=${ext_vol_labels_resolved[$index]}

        log "Erasing $device and creating $filesystem for $mount_point"
        lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS "$device_real"
        wipefs --all --force "$device_real"
        sgdisk --zap-all "$device_real"
        udevadm settle

        block_device=$device_real
        if [[ $encrypted == true ]]; then
            luks_label=${ext_vol_luks_labels[$index]}
            key_file=
            luks_key_file_for_volume key_file
            if [[ -n $key_file ]]; then
                log "Creating LUKS2 container $luks_label using a key file"
                cryptsetup luksFormat --batch-mode --type luks2 --label "$luks_label" --key-file "$key_file" "$device_real"
                cryptsetup open --type luks --key-file "$key_file" "$device_real" "$luks_name"
            else
                log "Creating LUKS2 container $luks_label; enter its initial passphrase when prompted"
                cryptsetup luksFormat --type luks2 --label "$luks_label" "$device_real"
                log "Opening $luks_label; enter its passphrase when prompted"
                cryptsetup open --type luks "$device_real" "$luks_name"
            fi
            uuid=$(cryptsetup luksUUID "$device_real")
            opened_luks_names+=("$luks_name")
            ext_vol_luks_uuids[index]=$uuid
            block_device=/dev/mapper/$luks_name
            enroll_luks_credentials "$mount_point" "$device_real" "$uuid" "$tpm2" "$tpm2_pcrs" "$tpm2_recovery" "$key_file"
            if [[ $luks_ephemeral_key == true ]]; then
                systemd-cryptenroll --wipe-slot=password "$device_real"
                remove_temporary_luks_key "$key_file"
            fi
        fi

        format_ext_vol_filesystem "$filesystem" "$label" "$block_device"
        udevadm settle
        wait_for_device "/dev/disk/by-label/$label"
        ext_vol_sources_resolved[index]=/dev/disk/by-label/$label
    done
}

create_subvolumes() {
    mkdir -p "$work_root/top"
    mount -o subvolid=5 /dev/disk/by-label/root "$work_root/top"
    cleanup_mounts+=("$work_root/top")

    btrfs subvolume create "$work_root/top/root"

    umount "$work_root/top"
    unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"
}

mount_install_target() {
    log "Mounting installation target at $install_root"
    mkdir -p "$install_root"
    mount -o "subvol=root,$root_mount_options" /dev/disk/by-label/root "$install_root"
    cleanup_mounts+=("$install_root")

    mkdir -p "$install_root/boot/efi"
    mount /dev/disk/by-label/boot "$install_root/boot"
    cleanup_mounts+=("$install_root/boot")
    mkdir -p "$install_root/boot/efi"
    mount /dev/disk/by-label/boot_efi "$install_root/boot/efi"
    cleanup_mounts+=("$install_root/boot/efi")
}

prepare_storage() {
    prepare_existing_ext_volumes
    prepare_partitions
    format_filesystems
    create_subvolumes
    prepare_ext_vol_filesystems
    mount_install_target
}
