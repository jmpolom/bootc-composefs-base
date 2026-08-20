#!/usr/bin/env bash
# shellcheck disable=SC2154

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/lib/common.sh"

initialize_installer "$@"

bootloader=${bootloader:-grub}
[[ $bootloader == grub || $bootloader == systemd ]] ||
    die "the composefs installer requires bootloader=grub or bootloader=systemd"
allow_missing_verity=${allow_missing_verity:-false}
is_boolean "$allow_missing_verity" || die "allow_missing_verity must be true or false"
require_bootc_options bootloader boot-mount-spec composefs-backend karg root-mount-spec skip-finalize source-imgref target-imgref

prepare_storage

# Variables below are populated by the sourced configuration and common defaults.
# shellcheck disable=SC2154
declare -a bootc_args=(
    install to-filesystem
    --skip-finalize
    --composefs-backend
    "--bootloader=$bootloader"
)
[[ -n $source_imgref ]] && bootc_args+=("--source-imgref=$source_imgref")
[[ -n $target_imgref ]] && bootc_args+=("--target-imgref=$target_imgref")
[[ $allow_missing_verity == true ]] && bootc_args+=(--allow-missing-verity)
append_common_kargs
append_state_kargs /state/os/default/var
run_bootc_install

persistent_var="$install_root/state/os/default/var"
configure_state_subvolumes "$persistent_var"

mapfile -t composefs_states < <(find "$install_root/state/deploy" -mindepth 1 -maxdepth 1 -type d -print)
((${#composefs_states[@]} == 1)) ||
    die "expected exactly one composefs deployment state, found ${#composefs_states[@]}"
config_root=${composefs_states[0]}
[[ -d $config_root/etc ]] || die "composefs deployment configuration root is missing: $config_root"

configure_composefs_boot_mounts "$config_root" "$script_dir/systemd"
configure_extra_mounts "$persistent_var"
configure_first_user "$config_root" "$persistent_var"
relabel_target_paths "$config_root"
finish_installation
