#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

declare -ag cleanup_mounts=()
declare -ag opened_luks_names=()
declare -ag temporary_luks_key_files=()
declare -ag extra_mount_labels_resolved=()
declare -ag extra_mount_runtime_paths=()
declare -ag extra_mount_luks_uuids=()
declare -ag extra_mount_luks_labels=()

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
        *) die "unsupported extra filesystem: $1" ;;
    esac
}

runtime_path_for_mount() {
    local mount_point=$1
    case "$mount_point" in
        /home) printf '%s\n' /var/home ;;
        /home/*) printf '/var/home/%s\n' "${mount_point#/home/}" ;;
        /opt) printf '%s\n' /var/opt ;;
        /opt/*) printf '/var/opt/%s\n' "${mount_point#/opt/}" ;;
        /root) printf '%s\n' /var/roothome ;;
        /root/*) printf '/var/roothome/%s\n' "${mount_point#/root/}" ;;
        /usr/local) printf '%s\n' /var/usrlocal ;;
        /usr/local/*) printf '/var/usrlocal/%s\n' "${mount_point#/usr/local/}" ;;
        /srv) printf '%s\n' /var/srv ;;
        /srv/*) printf '/var/srv/%s\n' "${mount_point#/srv/}" ;;
        /mnt) printf '%s\n' /var/mnt ;;
        /mnt/*) printf '/var/mnt/%s\n' "${mount_point#/mnt/}" ;;
        /media) printf '%s\n' /var/media ;;
        /media/*) printf '/var/media/%s\n' "${mount_point#/media/}" ;;
        *) printf '%s\n' "$mount_point" ;;
    esac
}

# Validate the indexes of one of the per-extra-mount indexed arrays.  Required
# arrays must be dense because all storage operations consume them by position;
# optional arrays may omit an entry, but an entry must still belong to a real
# extra-mount record.
validate_extra_mount_array_indexes() {
    local name=$1
    local count=$2
    local required=$3
    local index
    local -n values=$name

    for index in "${!values[@]}"; do
        [[ $index =~ ^[0-9]+$ ]] || die "$name has an invalid index: $index"
        ((index < count)) || die "${name}[$index] is outside extra mount range 0..$((count - 1))"
    done

    if [[ $required == true ]]; then
        ((${#values[@]} == count)) || die "$name must match extra_mount_devices length"
        for ((index = 0; index < count; index++)); do
            [[ -v "values[$index]" ]] || die "$name is missing required index: $index"
        done
    fi
}

# Arrays in this function are initialized dynamically by ensure_indexed_array.
# shellcheck disable=SC2154
validate_extra_mount_config() {
    local count=${#extra_mount_devices[@]}
    local required_array optional_array
    for required_array in extra_mount_devices extra_mount_points extra_mount_filesystems; do
        validate_extra_mount_array_indexes "$required_array" "$count" true
    done
    for optional_array in extra_mount_encrypted extra_mount_labels extra_mount_options extra_mount_luks_names \
        extra_mount_tpm2 extra_mount_tpm2_pcrs extra_mount_tpm2_recovery; do
        validate_extra_mount_array_indexes "$optional_array" "$count" false
    done

    local root_luks_name=${luks_name:-root}
    local -A seen_devices=() seen_labels=([boot_efi]=1 [boot]=1 [root]=1 [root_luks]=1) seen_paths=() seen_runtime_paths=() seen_luks_names=()
    local index device device_real mount_point runtime_path filesystem encrypted label label_limit options luks_name luks_label tpm2 tpm2_pcrs tpm2_recovery parent
    seen_luks_names["$root_luks_name"]=1
    if [[ $root_encrypted == true && -e /dev/mapper/$root_luks_name ]]; then
        die "configured root LUKS mapping is already active: $root_luks_name"
    fi
    for ((index = 0; index < count; index++)); do
        device=${extra_mount_devices[$index]}
        mount_point=${extra_mount_points[$index]}
        filesystem=${extra_mount_filesystems[$index]}
        encrypted=${extra_mount_encrypted[$index]:-false}
        tpm2=${extra_mount_tpm2[$index]:-false}
        tpm2_pcrs=${extra_mount_tpm2_pcrs[$index]:-}
        tpm2_recovery=${extra_mount_tpm2_recovery[$index]:-false}
        options=${extra_mount_options[$index]:-defaults}

        [[ $device == /dev/* ]] || die "extra_mount_devices[$index] must be a /dev node path"
        device_real=$(readlink -f -- "$device")
        [[ -b $device_real ]] || die "extra mount device is not a block device: $device"
        [[ $(lsblk -ndo TYPE "$device_real") == disk ]] || die "extra mount device must be a whole disk: $device"
        [[ $device_real != "$target_disk_real" ]] || die "extra mount device reuses target_disk: $device"
        [[ -z ${seen_devices[$device_real]:-} ]] || die "extra mount device is listed more than once: $device"
        seen_devices[$device_real]=1

        parent=$(lsblk -nrpo MOUNTPOINTS "$device_real" | awk 'NF { print; exit }')
        [[ -z $parent ]] || die "extra mount disk has a mounted filesystem at $parent"
        parent=$(lsblk -nrpo TYPE "$device_real" | awk '$1 ~ /^(crypt|lvm|raid)/ { print; exit }')
        [[ -z $parent ]] || die "extra mount disk has an active mapped descendant of type $parent"

        [[ $mount_point == /* ]] || die "extra mount point must be absolute: $mount_point"
        [[ $(realpath -m -- "$mount_point") == "$mount_point" ]] || die "extra mount point is not normalized: $mount_point"
        case "$mount_point" in
            /usr/local | /usr/local/*) ;;
            / | /boot | /boot/* | /etc | /etc/* | /usr | /usr/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/*)
                die "extra mount point is not a supported stateful path: $mount_point"
                ;;
        esac
        validate_backend_mount_target "$mount_point"
        [[ -z ${seen_paths[$mount_point]:-} ]] || die "extra mount point is listed more than once: $mount_point"
        seen_paths[$mount_point]=1
        runtime_path=$(runtime_path_for_mount "$mount_point")
        [[ -z ${seen_runtime_paths[$runtime_path]:-} ]] || die "extra mount point aliases an existing target: $mount_point"
        seen_runtime_paths[$runtime_path]=1

        case "$filesystem" in
            btrfs) require_commands mkfs.btrfs ;;
            ext4) require_commands mkfs.ext4 ;;
            xfs) require_commands mkfs.xfs ;;
            *) die "extra_mount_filesystems[$index] must be btrfs, ext4, or xfs" ;;
        esac
        [[ $options != *:* ]] || die "extra mount options cannot contain ':': $mount_point"
        is_boolean "$encrypted" || die "extra_mount_encrypted[$index] must be true or false"
        is_boolean "$tpm2" || die "extra_mount_tpm2[$index] must be true or false"
        is_boolean "$tpm2_recovery" || die "extra_mount_tpm2_recovery[$index] must be true or false"
        [[ $tpm2_pcrs != *$'\n'* ]] || die "extra_mount_tpm2_pcrs[$index] cannot contain a newline"
        if [[ $tpm2 == true ]]; then
            [[ $encrypted == true ]] || die "TPM enrollment requires encryption for extra mount: $mount_point"
            tpm_enrollment_requested=true
        elif [[ $tpm2_recovery == true ]]; then
            die "TPM recovery enrollment requires extra_mount_tpm2[$index]=true: $mount_point"
        elif [[ -n $tpm2_pcrs ]]; then
            die "extra_mount_tpm2_pcrs[$index] requires extra_mount_tpm2[$index]=true"
        fi

        label=${extra_mount_labels[$index]:-$(label_for_mount "$mount_point" "$filesystem")}
        [[ $label =~ ^[a-z0-9][a-z0-9_]*$ ]] || die "extra mount label must be lower case: $label"
        label_limit=$(filesystem_label_limit "$filesystem")
        ((${#label} <= label_limit)) || die "$filesystem label is too long for $mount_point: $label"
        [[ -z ${seen_labels[$label]:-} ]] || die "extra mount label is duplicated: $label"
        seen_labels[$label]=1
        assert_label_available "/dev/disk/by-label/$label" "$device_real"

        luks_name=${extra_mount_luks_names[$index]:-${label}_crypt}
        if [[ $encrypted == true ]]; then
            [[ $luks_name =~ ^[a-z0-9][a-z0-9_]*$ ]] || die "extra LUKS name must be lower case: $luks_name"
            ((${#luks_name} <= 127)) || die "extra LUKS mapping name is too long: $luks_name"
            [[ -z ${seen_luks_names[$luks_name]:-} ]] || die "extra LUKS mapping name is duplicated: $luks_name"
            [[ ! -e /dev/mapper/$luks_name ]] || die "extra LUKS mapping is already active: $luks_name"
            seen_luks_names[$luks_name]=1
            luks_label=${label:0:43}_luks
            [[ -z ${seen_labels[$luks_label]:-} ]] || die "extra LUKS label is duplicated: $luks_label"
            seen_labels[$luks_label]=1
            assert_label_available "/dev/disk/by-label/$luks_label" "$device_real"
            extra_mount_luks_labels[index]=$luks_label
        fi

        extra_mount_labels_resolved[index]=$label
        extra_mount_runtime_paths[index]=$runtime_path
    done

    local earlier
    for ((index = 0; index < count; index++)); do
        for ((earlier = 0; earlier < index; earlier++)); do
            if [[ ${extra_mount_runtime_paths[$earlier]} == "${extra_mount_runtime_paths[$index]}"/* ]]; then
                die "parent extra mount ${extra_mount_points[$index]} must precede ${extra_mount_points[$earlier]}"
            fi
        done
    done

    if [[ $separate_var == true && -n ${seen_runtime_paths["/var"]:-} ]]; then
        die "separate_var conflicts with an extra disk mounted at /var"
    fi
    if [[ $separate_home == true && -n ${seen_runtime_paths["/var/home"]:-} ]]; then
        die "separate_home conflicts with an extra disk mounted at /home"
    fi
    if [[ $separate_opt == true && -n ${seen_runtime_paths["/var/opt"]:-} ]]; then
        die "separate_opt conflicts with an extra disk mounted at /opt"
    fi
    if [[ -n ${seen_runtime_paths["/var"]:-} && ($separate_home == true || $separate_opt == true) ]]; then
        die "an extra /var disk cannot be combined with separate_home or separate_opt subvolumes"
    fi
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
    local trace_was_enabled=false
    local captured_output status

    if xtrace_secret_start; then
        trace_was_enabled=true
    fi
    if captured_output=$(SYSTEMD_COLORS=0 systemd-cryptenroll "$@" --recovery-key "$device"); then
        status=0
    else
        status=$?
    fi
    printf -v "$output_name" '%s' "$captured_output"
    xtrace_secret_restore "$trace_was_enabled"
    return "$status"
}

test_recovery_key() {
    local key_name=$1
    local device=$2
    local trace_was_enabled=false
    local status

    if xtrace_secret_start; then
        trace_was_enabled=true
    fi
    if printf '%s' "${!key_name}" | cryptsetup open --test-passphrase --key-file=- "$device"; then
        status=0
    else
        status=$?
    fi
    xtrace_secret_restore "$trace_was_enabled"
    return "$status"
}

validate_recovery_key() {
    local key_name=$1
    local trace_was_enabled=false
    local status

    if xtrace_secret_start; then
        trace_was_enabled=true
    fi
    if [[ ${!key_name} =~ ^[bcdefghijklnrtuv]{8}(-[bcdefghijklnrtuv]{8}){7}$ ]]; then
        status=0
    else
        status=1
    fi
    xtrace_secret_restore "$trace_was_enabled"
    return "$status"
}

write_recovery_key_record() {
    local uuid_name=$1
    local key_name=$2
    local output_file=$3
    local trace_was_enabled=false
    local status

    if xtrace_secret_start; then
        trace_was_enabled=true
    fi
    if printf '%s %s\n' "${!uuid_name}" "${!key_name}" >>"$output_file"; then
        status=0
    else
        status=$?
    fi
    xtrace_secret_restore "$trace_was_enabled"
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

format_extra_filesystem() {
    local filesystem=$1
    local label=$2
    local device=$3
    case "$filesystem" in
        btrfs) mkfs.btrfs -f -L "$label" "$device" ;;
        ext4) mkfs.ext4 -F -L "$label" "$device" ;;
        xfs) mkfs.xfs -f -L "$label" "$device" ;;
        *) die "unsupported extra filesystem: $filesystem" ;;
    esac
}

prepare_extra_filesystems() {
    local count=${#extra_mount_devices[@]}
    ((count > 0)) || return 0

    log "Preparing $count additional state disk(s)"
    local index device device_real mount_point filesystem encrypted label luks_name luks_label tpm2 tpm2_pcrs tpm2_recovery block_device uuid key_file
    for ((index = 0; index < count; index++)); do
        device=${extra_mount_devices[$index]}
        device_real=$(readlink -f -- "$device")
        mount_point=${extra_mount_points[$index]}
        filesystem=${extra_mount_filesystems[$index]}
        encrypted=${extra_mount_encrypted[$index]:-false}
        tpm2=${extra_mount_tpm2[$index]:-false}
        tpm2_pcrs=${extra_mount_tpm2_pcrs[$index]:-}
        tpm2_recovery=${extra_mount_tpm2_recovery[$index]:-false}
        label=${extra_mount_labels_resolved[$index]}

        log "Erasing $device and creating $filesystem for $mount_point"
        lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS "$device_real"
        wipefs --all --force "$device_real"
        sgdisk --zap-all "$device_real"
        udevadm settle

        block_device=$device_real
        if [[ $encrypted == true ]]; then
            luks_name=${extra_mount_luks_names[$index]:-${label}_crypt}
            luks_label=${extra_mount_luks_labels[$index]}
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
            extra_mount_luks_uuids[index]=$uuid
            block_device=/dev/mapper/$luks_name
            enroll_luks_credentials "$mount_point" "$device_real" "$uuid" "$tpm2" "$tpm2_pcrs" "$tpm2_recovery" "$key_file"
            if [[ $luks_ephemeral_key == true ]]; then
                systemd-cryptenroll --wipe-slot=password "$device_real"
                remove_temporary_luks_key "$key_file"
            fi
        fi

        format_extra_filesystem "$filesystem" "$label" "$block_device"
        udevadm settle
        wait_for_device "/dev/disk/by-label/$label"
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
    prepare_partitions
    format_filesystems
    create_subvolumes
    prepare_extra_filesystems
    mount_install_target
}
