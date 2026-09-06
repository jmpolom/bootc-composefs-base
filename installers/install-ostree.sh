#!/usr/bin/env bash
# shellcheck disable=SC2154

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/lib/common.sh"

ostree_set_defaults() {
    bootloader=${bootloader:-grub}
    stateroot=${stateroot:-default}
    physical_var_path="/ostree/deploy/$stateroot/var"
    root_setup_unit=ostree-prepare-root.service
}

ostree_preflight() {
    [[ $bootloader == grub ]] || die "the OSTree installer only supports bootloader=grub"
    [[ $stateroot =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "stateroot must be lower case and path-safe"
    require_commands ostree
    require_bootc_options bootloader boot-mount-spec karg root-mount-spec skip-finalize \
        source-imgref target-imgref
}

ostree_validate_mount_target() {
    local mount_point=$1
    case "$mount_point" in
        /ostree | /ostree/*)
            die "extra mount point is not a supported stateful path: $mount_point"
            ;;
    esac
}

ostree_build_bootc_args() {
    # shellcheck disable=SC2154
    declare -ga bootc_args=(
        install to-filesystem
        --skip-finalize
        --bootloader=grub
        "--stateroot=$stateroot"
    )
    [[ -n $source_imgref ]] && bootc_args+=("--source-imgref=$source_imgref")
    [[ -n $target_imgref ]] && bootc_args+=("--target-imgref=$target_imgref")
    append_common_kargs "$physical_var_path" "$root_setup_unit"
    append_state_kargs "$physical_var_path" "$root_setup_unit"
}

ostree_append_external_var_karg() {
    local label=$1
    local filesystem=$2
    local options=$3
    bootc_args+=("--karg=systemd.mount-extra=/dev/disk/by-label/${label}:/var:${filesystem}:${options}")
}

ostree_append_separate_var_karg() {
    local source=$1
    local options=$2
    local subvolume=$3
    bootc_args+=("--karg=systemd.mount-extra=${source}:/var:btrfs:subvol=${subvolume},${options}")
}

ostree_locate_deployment() {
    local deployment_path
    deployment_path=$(ostree admin --sysroot="$install_root" --print-current-dir)
    [[ -n $deployment_path ]] || die "OSTree did not report a current deployment"
    if [[ $deployment_path == "$install_root"/* ]]; then
        config_root=$deployment_path
    else
        config_root=$install_root/${deployment_path#/}
    fi
    [[ -d $config_root/etc ]] || die "OSTree deployment configuration root is missing: $config_root"
}

ostree_postprocess() {
    return 0
}

run_installer ostree "$@"
