#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

# Shared storage and post-install support for the two backend-specific installers.

# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/storage.sh"
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/state.sh"

declare -g install_complete=false
declare -g tpm_enrollment_requested=false
declare -g recovery_enrollment_requested=false
declare -g installer_config_file=

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
    # Keep the exact CLI-supplied path for preflight alias checks.  Set this after
    # sourcing so a configuration setting cannot replace the trusted value.
    installer_config_file=$config_arg
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
    luks_name=${luks_name:-root}
    root_mount_options=${root_mount_options:-compress=zstd,noatime}
    state_mount_options=${state_mount_options:-compress=zstd,noatime}
    user_shell=${user_shell:-/bin/bash}
    user_gecos=${user_gecos:-}
    rust_log=${rust_log:-info}
    source_imgref=${source_imgref:-}
    target_imgref=${target_imgref:-}

    ensure_indexed_array extra_kargs
    ensure_indexed_array ext_vol_devices
    ensure_indexed_array ext_vol_mountpoint
    ensure_indexed_array ext_vol_fs
    ensure_indexed_array ext_vol_luks
    ensure_indexed_array ext_vol_opts
    ensure_indexed_array ext_vol_tpm
    ensure_indexed_array ext_vol_tpm_pcrs
    ensure_indexed_array ext_vol_recovery
    ensure_indexed_array ext_vol_existing
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

is_canonical_guid() {
    [[ ${1:-} =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

# Validate a mount target's spelling without resolving filesystem symlinks.
# Mount targets are interpreted in the installed tree later, where symlink and
# file-type checks must inspect the requested literal path.  Keep this check
# lexical and portable instead of using realpath, which follows live-image
# aliases such as /srv -> /var/srv.
is_normalized_absolute_path() {
    local path=${1:-}
    [[ $path == /* ]] || return 1
    [[ $path == / || $path != */ ]] || return 1
    [[ $path != *//* ]] || return 1
    case "$path" in
        */./* | */../* | */. | */..) return 1 ;;
    esac
}

validate_canonical_guid() {
    local guid=$1 description=${2:-GUID}
    is_canonical_guid "$guid" ||
        die "$description must use canonical 8-4-4-4-12 hexadecimal syntax: $guid"
}

require_readable_file() {
    local path=$1 description=${2:-file}
    [[ -f $path && -r $path ]] || die "$description is not a readable regular file: $path"
}

validate_backend_templates() {
    local description=$1
    shift
    (($# > 0)) || die "at least one backend template is required"
    local path
    for path in "$@"; do
        require_readable_file "$path" "$description"
    done
}

validate_backend_tools() {
    (($# > 0)) || die "at least one backend tool is required"
    require_commands "$@"
}

validate_usable_directory() {
    local path=$1 description=${2:-directory} allow_missing=${3:-false}
    [[ -n $path ]] || die "$description must not be empty"

    if [[ -e $path || -L $path ]]; then
        [[ ! -L $path && -d $path && -r $path && -w $path && -x $path ]] ||
            die "$description is not a usable directory: $path"
        return 0
    fi

    [[ $allow_missing == true ]] || die "$description does not exist: $path"
    local parent=$path
    while [[ ! -e $parent && ! -L $parent ]]; do
        [[ $parent != / ]] || break
        parent=${parent%/*}
        [[ -n $parent ]] || parent=/
    done
    [[ ! -L $parent && -d $parent && -r $parent && -w $parent && -x $parent ]] ||
        die "parent of $description is not a usable directory: $path"
}

validate_work_root() {
    local path=${1:-${work_root:-}}
    validate_usable_directory "$path" work_root true
}

validate_var_tmp() {
    local path=${1:-/var/tmp}
    validate_usable_directory "$path" /var/tmp false
}

validate_recovery_output_target() {
    local path=$1
    [[ $path == /* ]] || die "recovery_key_output_file must be absolute"
    [[ $(realpath -m -- "$path") == "$path" ]] ||
        die "recovery_key_output_file is not normalized: $path"
    [[ ! -L $path ]] || die "recovery_key_output_file must not be a symlink"

    local parent=${path%/*}
    [[ -n $parent ]] || parent=/
    validate_usable_directory "$parent" "recovery output parent" true
    if [[ -e $path ]]; then
        [[ -f $path ]] ||
            die "recovery_key_output_file must be a regular file: $path"
    fi
}

paths_alias() {
    local first=$1 second=$2
    [[ -e $first && -e $second ]] || return 1
    [[ $(realpath -m -- "$first") == "$(realpath -m -- "$second")" ]]
}

validate_recovery_output_aliases() {
    local output=$1 config_file=$2 password_file=${3:-}
    if [[ -n $config_file ]] && paths_alias "$output" "$config_file"; then
        die "recovery_key_output_file must not alias the configuration file: $output"
    fi
    if [[ -n $password_file ]] && paths_alias "$output" "$password_file"; then
        die "recovery_key_output_file must not alias luks_password_file: $output"
    fi
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

backend_callback() {
    local callback=$1
    shift
    local function_name="${installer_backend}_${callback}"
    declare -F "$function_name" >/dev/null 2>&1 ||
        die "backend callback is not defined: $function_name"
    "$function_name" "$@"
}

validate_backend_mount_target() {
    backend_callback validate_mount_target "$1"
}

append_external_var_karg() {
    backend_callback append_external_var_karg "$@"
}


validate_common_config() {
    [[ $destructive_confirmed == true ]] || die "-y is required to authorize erasing the configured disks"
    [[ $EUID -eq 0 ]] || die "this installer must run as root"
    require_full_capabilities
    [[ -n ${target_disk:-} ]] || die "target_disk is required"
    [[ $target_disk == /dev/disk/by-* ]] || die "target_disk must use a /dev/disk/by-* path"
    [[ $luks_name =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "luks_name must be lower case and path-safe"
    validate_created_mount_options "$root_mount_options" btrfs root_mount_options
    [[ $state_mount_options != *:* ]] || die "state_mount_options cannot contain ':'"
    validate_created_mount_options "$state_mount_options" btrfs state_mount_options
    [[ $efi_size_mib =~ ^[0-9]+$ && $efi_size_mib -ge 128 ]] || die "efi_size_mib must be at least 128"
    [[ $boot_size_mib =~ ^[0-9]+$ && $boot_size_mib -ge 512 ]] || die "boot_size_mib must be at least 512"
    # Resolve and validate the root partition type before any storage operation.
    root_partition_guid >/dev/null
    validate_work_root
    validate_var_tmp

    local setting
    for setting in root_encrypted root_tpm2 root_tpm2_recovery luks_ephemeral_key; do
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
        [[ -n ${user_password:-} ]] &&
            die "use user_password_hash, not a plaintext user_password"
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
    validate_ext_vol_config

    local recovery_requested=$root_tpm2_recovery
    local index
    for ((index = 0; index < ${#ext_vol_devices[@]}; index++)); do
        if [[ ${ext_vol_recovery[$index]:-false} == true ]]; then
            recovery_requested=true
        fi
        if [[ $luks_ephemeral_key == true && ${ext_vol_existing[$index]:-false} == false && \
              -n ${ext_vol_luks[$index]:-} && \
              ${ext_vol_recovery[$index]:-false} != true ]]; then
            die "luks_ephemeral_key requires a recovery key for encrypted external volume: ${ext_vol_mountpoint[$index]}"
        fi
    done
    if [[ $luks_ephemeral_key == true && $root_encrypted == true && $root_tpm2_recovery != true ]]; then
        die "luks_ephemeral_key requires root_tpm2_recovery=true for encrypted root"
    fi
    if [[ $recovery_requested == true ]]; then
        [[ -n $recovery_key_output_file ]] ||
            die "recovery_key_output_file is required when recovery enrollment is enabled"
        validate_recovery_output_target "$recovery_key_output_file"
        validate_recovery_output_aliases "$recovery_key_output_file" \
            "$installer_config_file" "$luks_password_file"
    fi
    recovery_enrollment_requested=$recovery_requested
    if [[ $tpm_enrollment_requested == true ]]; then
        require_commands systemd-cryptenroll
    fi
}

append_common_kargs() {
    local physical_var_path=$1
    local root_setup_unit=$2

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

    local index source filesystem options mount_point uuid luks_name luks_options
    for ((index = 0; index < ${#ext_vol_devices[@]}; index++)); do
        source=${ext_vol_sources_resolved[$index]:-}
        filesystem=${ext_vol_fs[$index]}
        options=${ext_vol_opts[$index]:-defaults}
        mount_point=${ext_vol_mountpoint[$index]}
        [[ -n $source ]] || die "external volume source is unavailable for $mount_point"
        if [[ $mount_point == /var ]]; then
            append_external_var_karg "$source" "$filesystem" "$options"
        else
            bootc_args+=("--karg=systemd.mount-extra=${source}:${mount_point}:${filesystem}:${options}")
        fi

        uuid=${ext_vol_luks_uuids[$index]:-}
        if [[ -n $uuid ]]; then
            luks_name=${ext_vol_luks[$index]}
            luks_options=x-initrd.attach
            if [[ ${ext_vol_tpm[$index]:-false} == true ]]; then
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

finish_installation() {
    log "Syncing installed filesystems"
    sync
    install_complete=true
}

cleanup() {
    local status=$?
    local cleanup_status=0
    trap - EXIT INT TERM
    set +e

    local index mountpoint
    for ((index = ${#cleanup_mounts[@]} - 1; index >= 0; index--)); do
        mountpoint=${cleanup_mounts[$index]}
        if findmnt --mountpoint "$mountpoint" >/dev/null 2>&1; then
            if ! umount "$mountpoint"; then
                printf 'Cleanup failed to unmount %s\n' "$mountpoint" >&2
                cleanup_status=1
            fi
        fi
    done

    local luks_index open_name
    for ((luks_index = ${#opened_luks_names[@]} - 1; luks_index >= 0; luks_index--)); do
        open_name=${opened_luks_names[$luks_index]}
        if [[ -e /dev/mapper/$open_name ]]; then
            if ! cryptsetup close "$open_name"; then
                printf 'Cleanup failed to close mapper %s\n' "$open_name" >&2
                cleanup_status=1
            fi
        fi
    done

    local key_file
    for key_file in "${temporary_luks_key_files[@]}"; do
        if [[ -n $key_file ]] && ! rm -f -- "$key_file"; then
            printf 'Cleanup failed to remove temporary key %s\n' "$key_file" >&2
            cleanup_status=1
        fi
    done

    for key_file in "${temporary_credential_files[@]}"; do
        if [[ -n $key_file ]] && ! rm -f -- "$key_file"; then
            printf 'Cleanup failed to remove temporary credential %s\n' "$key_file" >&2
            cleanup_status=1
        fi
    done

    local credential_variable
    for credential_variable in "${external_credential_variables[@]}"; do
        [[ -n $credential_variable ]] && unset "$credential_variable"
    done

    if [[ $status -eq 0 && $cleanup_status -ne 0 ]]; then
        status=$cleanup_status
    fi
    if [[ $status -eq 0 && $install_complete == true ]]; then
        log "Installation completed successfully"
    elif [[ $status -ne 0 ]]; then
        printf 'Installation failed with status %d\n' "$status" >&2
    fi
    exit "$status"
}

run_installer() {
    local backend=$1
    shift
    installer_backend=$backend

    set -Eeuo pipefail
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    parse_options "$@"
    set_defaults
    backend_callback set_defaults
    normalize_ext_vol_shortcuts
    validate_common_config
    backend_callback preflight

    mkdir -p "$work_root"
    [[ $recovery_enrollment_requested == true ]] && initialize_recovery_key_output

    prepare_storage
    backend_callback build_bootc_args
    run_bootc_install

    persistent_var="$install_root$physical_var_path"
    backend_callback locate_deployment
    backend_callback postprocess
    prepare_ext_vol_targets "$config_root" "$persistent_var"
    configure_ext_vols "$config_root" "$persistent_var"
    configure_first_user "$config_root" "$persistent_var"
    relabel_target_paths "$config_root"
    finish_installation
}
