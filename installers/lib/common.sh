#!/usr/bin/env bash

# Shared storage and post-install support for the two backend-specific installers.

declare -ag cleanup_mounts=()
declare -ag opened_luks_names=()
declare -ag temporary_luks_key_files=()
declare -ag extra_mount_labels_resolved=()
declare -ag extra_mount_runtime_paths=()
declare -ag extra_mount_luks_uuids=()
declare -ag extra_mount_luks_labels=()
declare -g install_complete=false
declare -g tpm_enrollment_requested=false

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") -c CONFIG -y [-t]

  -c FILE  Source installation settings from FILE.
  -y       Confirm that all configured target disks may be erased.
  -t       Enable shell tracing (set -x).
  -h       Show this help.
EOF
}

parse_options() {
    local config_arg=
    local trace_arg=false
    local yes_arg=false

    while getopts ':c:yth' option; do
        case "$option" in
            c) config_arg=$OPTARG ;;
            y) yes_arg=true ;;
            t) trace_arg=true ;;
            h)
                usage
                exit 0
                ;;
            :) die "option -$OPTARG requires an argument" ;;
            \?) die "unknown option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    (($# == 0)) || die "unexpected positional arguments: $*"
    [[ -n $config_arg ]] || die "-c CONFIG is required"
    [[ -r $config_arg ]] || die "configuration is not readable: $config_arg"

    # The configuration is intentionally a shell environment file and is trusted code.
    # shellcheck source=/dev/null
    source "$config_arg"
    destructive_confirmed=$yes_arg
    if [[ $trace_arg == true ]]; then
        set -x
    fi
}

set_defaults() {
    root_encrypted=${root_encrypted:-false}
    root_tpm2=${root_tpm2:-false}
    root_tpm2_pcrs=${root_tpm2_pcrs:-}
    root_tpm2_recovery=${root_tpm2_recovery:-false}
    luks_ephemeral_key=${luks_ephemeral_key:-false}
    luks_password_file=${luks_password_file:-}
    recovery_key_output_file=${recovery_key_output_file:-}
    separate_var=${separate_var:-false}
    separate_home=${separate_home:-false}
    separate_opt=${separate_opt:-false}
    efi_size_mib=${efi_size_mib:-600}
    boot_size_mib=${boot_size_mib:-1024}
    install_root=${install_root:-/mnt/bootc-install}
    work_root=${work_root:-/run/bootc-installer}
    stateroot=${stateroot:-default}
    luks_name=${luks_name:-root}
    root_mount_options=${root_mount_options:-compress=zstd,noatime}
    state_mount_options=${state_mount_options:-compress=zstd,noatime}
    user_shell=${user_shell:-/bin/bash}
    user_gecos=${user_gecos:-}
    rust_log=${rust_log:-info}
    source_imgref=${source_imgref:-}
    target_imgref=${target_imgref:-}

    ensure_indexed_array extra_kargs
    ensure_indexed_array extra_mount_devices
    ensure_indexed_array extra_mount_points
    ensure_indexed_array extra_mount_filesystems
    ensure_indexed_array extra_mount_encrypted
    ensure_indexed_array extra_mount_labels
    ensure_indexed_array extra_mount_options
    ensure_indexed_array extra_mount_luks_names
    ensure_indexed_array extra_mount_tpm2
    ensure_indexed_array extra_mount_tpm2_pcrs
    ensure_indexed_array extra_mount_tpm2_recovery
}

ensure_indexed_array() {
    local name=$1 declaration
    if ! declaration=$(declare -p "$name" 2>/dev/null); then
        declare -g -a "$name=()"
    elif [[ $declaration != 'declare -a '* ]]; then
        die "$name must use Bash indexed-array syntax"
    fi
}

is_boolean() {
    [[ $1 == true || $1 == false ]]
}

require_commands() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
    done
}

require_full_capabilities() {
    local last_cap expected_hex cap_eff cap_bnd

    read -r last_cap </proc/sys/kernel/cap_last_cap
    ((last_cap < 63)) || die "cannot verify a capability set wider than 63 bits"
    printf -v expected_hex '%016x' "$(((1 << (last_cap + 1)) - 1))"
    cap_eff=$(awk '$1 == "CapEff:" { print tolower($2) }' /proc/self/status)
    cap_bnd=$(awk '$1 == "CapBnd:" { print tolower($2) }' /proc/self/status)
    [[ $cap_eff == "$expected_hex" && $cap_bnd == "$expected_hex" ]] ||
        die "installer requires all capabilities (expected=$expected_hex CapEff=$cap_eff CapBnd=$cap_bnd)"
    log "Installer privilege check passed: uid=$EUID CapEff=$cap_eff CapBnd=$cap_bnd"
}

require_bootc_options() {
    local help_text option
    help_text=$(bootc install to-filesystem --help)
    for option in "$@"; do
        grep -q -- "--$option" <<<"$help_text" ||
            die "installed bootc does not support --$option for install to-filesystem"
    done
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

# Arrays in this function are initialized dynamically by ensure_indexed_array.
# shellcheck disable=SC2154
validate_extra_mount_config() {
    local count=${#extra_mount_devices[@]}
    ((${#extra_mount_points[@]} == count)) || die "extra_mount_points must match extra_mount_devices length"
    ((${#extra_mount_filesystems[@]} == count)) || die "extra_mount_filesystems must match extra_mount_devices length"

    local -A seen_devices=() seen_labels=([boot_efi]=1 [boot]=1 [root]=1 [root_luks]=1) seen_paths=() seen_runtime_paths=() seen_luks_names=([root]=1)
    local index device device_real mount_point runtime_path filesystem encrypted label label_limit options luks_name luks_label tpm2 tpm2_pcrs tpm2_recovery parent
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
            / | /boot | /boot/* | /etc | /etc/* | /usr | /usr/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /run | /run/* | \
                /ostree | /ostree/* | /composefs | /composefs/* | /state | /state/*)
                die "extra mount point is not a supported stateful path: $mount_point"
                ;;
        esac
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

validate_common_config() {
    [[ $destructive_confirmed == true ]] || die "-y is required to authorize erasing the configured disks"
    [[ $EUID -eq 0 ]] || die "this installer must run as root"
    require_full_capabilities
    [[ -n ${target_disk:-} ]] || die "target_disk is required"
    [[ $target_disk == /dev/disk/by-* ]] || die "target_disk must use a /dev/disk/by-* path"
    [[ $stateroot =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "stateroot must be lower case and path-safe"
    [[ $luks_name =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "luks_name must be lower case and path-safe"
    [[ $root_mount_options != *:* ]] || die "root_mount_options cannot contain ':'"
    [[ $state_mount_options != *:* ]] || die "state_mount_options cannot contain ':'"
    [[ $efi_size_mib =~ ^[0-9]+$ && $efi_size_mib -ge 128 ]] || die "efi_size_mib must be at least 128"
    [[ $boot_size_mib =~ ^[0-9]+$ && $boot_size_mib -ge 512 ]] || die "boot_size_mib must be at least 512"

    local setting
    for setting in root_encrypted root_tpm2 root_tpm2_recovery luks_ephemeral_key separate_var separate_home separate_opt; do
        is_boolean "${!setting}" || die "$setting must be true or false"
    done

    [[ ! ($luks_ephemeral_key == true && -n $luks_password_file) ]] ||
        die "luks_ephemeral_key and luks_password_file are mutually exclusive"
    if [[ -n $luks_password_file ]]; then
        [[ -f $luks_password_file && -r $luks_password_file ]] ||
            die "luks_password_file is not a readable regular file: $luks_password_file"
    fi

    [[ $root_tpm2_pcrs != *$'\n'* ]] || die "root_tpm2_pcrs cannot contain a newline"
    if [[ $root_tpm2 == true ]]; then
        [[ $root_encrypted == true ]] || die "root_tpm2 requires root_encrypted=true"
        tpm_enrollment_requested=true
    elif [[ $root_tpm2_recovery == true ]]; then
        die "root_tpm2_recovery requires root_tpm2=true"
    elif [[ -n $root_tpm2_pcrs ]]; then
        die "root_tpm2_pcrs requires root_tpm2=true"
    fi

    if [[ -n ${user_name:-} ]]; then
        [[ $user_name =~ ^[a-z_][a-z0-9_-]*$ ]] || die "user_name is invalid"
        [[ -z ${user_password:-} ]] || die "use user_password_hash, not a plaintext user_password"
    fi

    target_disk_real=$(readlink -f -- "$target_disk")
    [[ -b $target_disk_real ]] || die "target_disk does not resolve to a block device: $target_disk"
    [[ $(lsblk -ndo TYPE "$target_disk_real") == disk ]] || die "target_disk must identify a whole disk"
    [[ -d /sys/firmware/efi ]] || die "the installation environment must be booted in UEFI mode"

    local mounted_path active_type disk_size minimum_size
    mounted_path=$(lsblk -nrpo MOUNTPOINTS "$target_disk_real" | awk 'NF { print; exit }')
    [[ -z $mounted_path ]] || die "target disk has a mounted filesystem at $mounted_path"
    active_type=$(lsblk -nrpo TYPE "$target_disk_real" | awk '$1 ~ /^(crypt|lvm|raid)/ { print; exit }')
    [[ -z $active_type ]] || die "target disk has an active mapped descendant of type $active_type"
    disk_size=$(lsblk -bdno SIZE "$target_disk_real")
    minimum_size=$(((efi_size_mib + boot_size_mib + 2048) * 1024 * 1024))
    ((disk_size >= minimum_size)) || die "target disk is too small for the requested layout"

    require_commands awk blkid bootc btrfs chmod chown cp cryptsetup find findmnt getent grep \
        dd install ln lsblk mkfs.btrfs mkfs.ext4 mkfs.vfat mktemp mount mv readlink realpath rm sed sgdisk sync udevadm umount \
        touch useradd usermod wipefs
    validate_extra_mount_config

    local recovery_requested=$root_tpm2_recovery
    local index
    for ((index = 0; index < ${#extra_mount_devices[@]}; index++)); do
        if [[ ${extra_mount_tpm2_recovery[$index]:-false} == true ]]; then
            recovery_requested=true
        fi
        if [[ $luks_ephemeral_key == true && ${extra_mount_encrypted[$index]:-false} == true && \
              ${extra_mount_tpm2_recovery[$index]:-false} != true ]]; then
            die "luks_ephemeral_key requires a recovery key for encrypted extra mount: ${extra_mount_points[$index]}"
        fi
    done
    if [[ $luks_ephemeral_key == true && $root_encrypted == true && $root_tpm2_recovery != true ]]; then
        die "luks_ephemeral_key requires root_tpm2_recovery=true for encrypted root"
    fi
    if [[ $recovery_requested == true ]]; then
        [[ -n $recovery_key_output_file ]] ||
            die "recovery_key_output_file is required when recovery enrollment is enabled"
        [[ $recovery_key_output_file == /* ]] || die "recovery_key_output_file must be absolute"
        [[ $(realpath -m -- "$recovery_key_output_file") == "$recovery_key_output_file" ]] ||
            die "recovery_key_output_file is not normalized: $recovery_key_output_file"
        [[ ! -L $recovery_key_output_file ]] || die "recovery_key_output_file must not be a symlink"
    fi
    if [[ $tpm_enrollment_requested == true ]]; then
        require_commands systemd-cryptenroll
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
        recovery_key=$(SYSTEMD_COLORS=0 systemd-cryptenroll "${unlock_args[@]}" --recovery-key "$device")
        [[ $recovery_key =~ ^[bcdefghijklnrtuv]{8}(-[bcdefghijklnrtuv]{8}){7}$ ]] ||
            die "systemd-cryptenroll returned an invalid recovery key for $volume"
        printf '%s' "$recovery_key" | cryptsetup open --test-passphrase --key-file=- "$device" ||
            die "generated recovery key did not unlock $volume"
        printf '%s %s\n' "$luks_uuid" "$recovery_key" >>"$recovery_key_output_file"
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

# extra_kargs and extra_mount_* are initialized dynamically by ensure_indexed_array.
# shellcheck disable=SC2154
append_common_kargs() {
    bootc_args+=(
        "--root-mount-spec=/dev/disk/by-label/root"
        "--boot-mount-spec=UUID=$boot_filesystem_uuid"
        "--karg=rootfstype=btrfs"
        "--karg=rootflags=subvol=root,$root_mount_options"
    )

    if [[ $root_encrypted == true ]]; then
        local root_luks_options=x-initrd.attach
        if [[ $root_tpm2 == true ]]; then
            root_luks_options='tpm2-device=auto,x-initrd.attach'
        fi
        bootc_args+=(
            "--karg=rd.luks.uuid=${root_luks_uuid}"
            "--karg=rd.luks.name=${root_luks_uuid}=${luks_name}"
            "--karg=rd.luks.options=${root_luks_uuid}=${root_luks_options}"
        )
    fi

    local karg
    for karg in "${extra_kargs[@]}"; do
        [[ -n $karg ]] && bootc_args+=("--karg=$karg")
    done

    local index label filesystem options runtime_path uuid luks_name luks_options
    for ((index = 0; index < ${#extra_mount_devices[@]}; index++)); do
        label=${extra_mount_labels_resolved[$index]}
        filesystem=${extra_mount_filesystems[$index]}
        options=${extra_mount_options[$index]:-defaults}
        runtime_path=${extra_mount_runtime_paths[$index]}
        bootc_args+=("--karg=systemd.mount-extra=/dev/disk/by-label/${label}:${runtime_path}:${filesystem}:${options}")

        uuid=${extra_mount_luks_uuids[$index]:-}
        if [[ -n $uuid ]]; then
            luks_name=${extra_mount_luks_names[$index]:-${label}_crypt}
            luks_options=x-initrd.attach
            if [[ ${extra_mount_tpm2[$index]:-false} == true ]]; then
                luks_options='tpm2-device=auto,x-initrd.attach'
            fi
            bootc_args+=(
                "--karg=rd.luks.uuid=${uuid}"
                "--karg=rd.luks.name=${uuid}=${luks_name}"
                "--karg=rd.luks.options=${uuid}=${luks_options}"
            )
        fi
    done
}

append_state_kargs() {
    local physical_var_path=$1
    local source=/dev/disk/by-label/root
    local options=$state_mount_options
    local var_subvolume="root$physical_var_path"

    if [[ $separate_var == true ]]; then
        bootc_args+=("--karg=rd.systemd.mount-extra=${source}:${physical_var_path}:btrfs:subvol=${var_subvolume},${options}")
    fi
    if [[ $separate_home == true ]]; then
        bootc_args+=("--karg=systemd.mount-extra=${source}:/var/home:btrfs:subvol=${var_subvolume}/home,${options}")
    fi
    if [[ $separate_opt == true ]]; then
        bootc_args+=("--karg=systemd.mount-extra=${source}:/var/opt:btrfs:subvol=${var_subvolume}/opt,${options}")
    fi
}

run_bootc_install() {
    local status

    log "bootc arguments: ${bootc_args[*]}"
    log "Starting bootc deployment"
    if RUST_LOG=$rust_log TMPDIR=/var/tmp bootc "${bootc_args[@]}" "$install_root"; then
        status=0
    else
        status=$?
    fi
    return "$status"
}

move_state_to_subvolume() {
    local name=$1
    local state_path=$2
    local old_path="${state_path}.bootc-installer-old"

    log "Moving $state_path into Btrfs subvolume $name"
    [[ -d $state_path && ! -L $state_path ]] || die "state path is not a directory: $state_path"
    [[ ! -e $old_path ]] || die "temporary migration path already exists: $old_path"
    mv "$state_path" "$old_path"
    btrfs subvolume create "$state_path"
    chmod --reference="$old_path" "$state_path"
    chown --reference="$old_path" "$state_path"
    touch --reference="$old_path" "$state_path"
    if command -v chcon >/dev/null 2>&1; then
        chcon --reference="$old_path" "$state_path" || log "SELinux context copy was unavailable for $state_path"
    fi
    cp -a --reflink=auto "$old_path/." "$state_path/"
    rm -rf -- "$old_path"
}

configure_state_subvolumes() {
    local persistent_var=$1

    [[ -d $persistent_var ]] || die "bootc did not create persistent var at $persistent_var"
    if [[ $separate_var == true ]]; then
        move_state_to_subvolume var "$persistent_var"
    fi
    if [[ $separate_home == true ]]; then
        move_state_to_subvolume home "$persistent_var/home"
    fi
    if [[ $separate_opt == true ]]; then
        move_state_to_subvolume opt "$persistent_var/opt"
    fi
}

configure_composefs_boot_mounts() {
    local config_root=$1
    local unit_source_dir=$2
    local unit_dir=$config_root/etc/systemd/system
    local requires_dir=$unit_dir/local-fs.target.requires
    local unit

    [[ -n ${boot_filesystem_uuid:-} ]] || die "boot filesystem UUID is unavailable"
    [[ -n ${efi_filesystem_uuid:-} ]] || die "EFI filesystem UUID is unavailable"
    [[ -r $unit_source_dir/sysroot-boot.mount.in ]] ||
        die "composefs boot mount unit template is missing: $unit_source_dir/sysroot-boot.mount.in"
    [[ -r $unit_source_dir/boot.mount ]] ||
        die "composefs boot bind mount unit is missing: $unit_source_dir/boot.mount"
    [[ -r $unit_source_dir/boot-efi.mount.in ]] ||
        die "composefs EFI mount unit template is missing: $unit_source_dir/boot-efi.mount.in"

    log "Configuring composefs boot filesystem mounts"
    install -d -m 0755 "$unit_dir" "$requires_dir"
    sed "s|@BOOT_FILESYSTEM_UUID@|$boot_filesystem_uuid|g" \
        "$unit_source_dir/sysroot-boot.mount.in" >"$unit_dir/sysroot-boot.mount"
    install -m 0644 "$unit_source_dir/boot.mount" "$unit_dir/boot.mount"
    sed "s|@EFI_FILESYSTEM_UUID@|$efi_filesystem_uuid|g" \
        "$unit_source_dir/boot-efi.mount.in" >"$unit_dir/boot-efi.mount"
    chmod 0644 "$unit_dir/sysroot-boot.mount" "$unit_dir/boot-efi.mount"

    for unit in sysroot-boot.mount boot.mount boot-efi.mount; do
        ln -sfn "../$unit" "$requires_dir/$unit"
    done
}

state_path_for_mount() {
    local persistent_var=$1
    local mount_point=$2
    local runtime_path
    runtime_path=$(runtime_path_for_mount "$mount_point")

    case "$runtime_path" in
        /var) printf '%s\n' "$persistent_var" ;;
        /var/*) printf '%s/%s\n' "$persistent_var" "${runtime_path#/var/}" ;;
        *) return 1 ;;
    esac
}

clear_directory() {
    local directory=$1
    find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

configure_extra_mounts() {
    local persistent_var=$1
    local count=${#extra_mount_devices[@]}
    ((count > 0)) || return 0

    local index label filesystem options mount_point source staging state_path
    for ((index = 0; index < count; index++)); do
        label=${extra_mount_labels_resolved[$index]}
        filesystem=${extra_mount_filesystems[$index]}
        options=${extra_mount_options[$index]:-defaults}
        mount_point=${extra_mount_points[$index]}
        source=/dev/disk/by-label/$label
        staging=$work_root/extra-$index

        mkdir -p "$staging"
        mount -t "$filesystem" -o "$options" "$source" "$staging"
        cleanup_mounts+=("$staging")

        if state_path=$(state_path_for_mount "$persistent_var" "$mount_point"); then
            log "Moving existing state for $mount_point onto $source"
            mkdir -p "$state_path"
            chmod --reference="$state_path" "$staging"
            chown --reference="$state_path" "$staging"
            touch --reference="$state_path" "$staging"
            if command -v chcon >/dev/null 2>&1; then
                chcon --reference="$state_path" "$staging" || log "SELinux context copy was unavailable for $mount_point"
            fi
            cp -a --reflink=auto "$state_path/." "$staging/"
            clear_directory "$state_path"
            umount "$staging"
            unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"

            mount -t "$filesystem" -o "$options" "$source" "$state_path"
            cleanup_mounts+=("$state_path")
        else
            log "$mount_point has no pre-existing bootc state path to migrate"
            umount "$staging"
            unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"
        fi
    done
}

configure_first_user() {
    local config_root=$1
    local persistent_var=$2
    [[ -n ${user_name:-} ]] || return 0

    [[ -f $config_root/etc/passwd ]] || die "target passwd file is missing"
    grep -q '^wheel:' "$config_root/etc/group" || die "target image does not define the wheel group"
    if grep -q "^${user_name}:" "$config_root/etc/passwd"; then
        die "target image already defines user $user_name"
    fi

    log "Creating initial administrative user $user_name"
    local -a useradd_args=(
        --root "$config_root"
        --no-create-home
        --groups wheel
        --shell "$user_shell"
        --comment "$user_gecos"
    )
    if grep -q "^${user_name}:" "$config_root/etc/group"; then
        useradd_args+=(--gid "$user_name")
    else
        useradd_args+=(--user-group)
    fi
    useradd "${useradd_args[@]}" "$user_name"

    if [[ -n ${user_password_hash:-} ]]; then
        usermod --root "$config_root" --password "$user_password_hash" "$user_name"
    else
        usermod --root "$config_root" --lock "$user_name"
    fi

    local uid gid
    uid=$(awk -F: -v user="$user_name" '$1 == user { print $3 }' "$config_root/etc/passwd")
    gid=$(awk -F: -v user="$user_name" '$1 == user { print $4 }' "$config_root/etc/passwd")
    [[ -n $uid && -n $gid ]] || die "could not resolve the new user's uid/gid"
    mkdir -p "$persistent_var/home/$user_name"
    chmod 0700 "$persistent_var/home/$user_name"
    chown "$uid:$gid" "$persistent_var/home/$user_name"
}

relabel_target_paths() {
    local config_root=$1
    local contexts=$config_root/etc/selinux/targeted/contexts/files/file_contexts
    command -v setfiles >/dev/null 2>&1 || return 0
    [[ -r $contexts ]] || return 0

    log "Applying target SELinux labels to mutable state"
    setfiles -F -r "$config_root" "$contexts" "$config_root/etc" ||
        die "failed to label target configuration"
}

finish_installation() {
    log "Syncing installed filesystems"
    sync
    install_complete=true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e

    local index mountpoint
    for ((index = ${#cleanup_mounts[@]} - 1; index >= 0; index--)); do
        mountpoint=${cleanup_mounts[$index]}
        if findmnt --mountpoint "$mountpoint" >/dev/null 2>&1; then
            umount "$mountpoint"
        fi
    done

    local luks_index open_name
    for ((luks_index = ${#opened_luks_names[@]} - 1; luks_index >= 0; luks_index--)); do
        open_name=${opened_luks_names[$luks_index]}
        if [[ -e /dev/mapper/$open_name ]]; then
            cryptsetup close "$open_name"
        fi
    done

    local key_file
    for key_file in "${temporary_luks_key_files[@]}"; do
        [[ -n $key_file ]] && rm -f -- "$key_file"
    done

    if [[ $status -eq 0 && $install_complete == true ]]; then
        log "Installation completed successfully"
    elif [[ $status -ne 0 ]]; then
        printf 'Installation failed with status %d\n' "$status" >&2
    fi
    exit "$status"
}

initialize_installer() {
    set -Eeuo pipefail
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    parse_options "$@"
    set_defaults
    validate_common_config
    mkdir -p "$work_root"
    initialize_recovery_key_output
}
