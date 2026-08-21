#!/usr/bin/env bash
# shellcheck disable=SC2154

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/lib/common.sh"

initialize_installer "$@"

[[ ${bootloader:-grub} == grub ]] || die "the OSTree installer only supports bootloader=grub"
require_commands ostree
require_bootc_options bootloader boot-mount-spec karg root-mount-spec skip-finalize source-imgref target-imgref

prepare_storage

# Variables below are populated by the sourced configuration and common defaults.
# shellcheck disable=SC2034,SC2154
declare -a bootc_args=(
    install to-filesystem
    --skip-finalize
    --bootloader=grub
    "--stateroot=$stateroot"
)
[[ -n $source_imgref ]] && bootc_args+=("--source-imgref=$source_imgref")
[[ -n $target_imgref ]] && bootc_args+=("--target-imgref=$target_imgref")
physical_var_path="/ostree/deploy/$stateroot/var"
append_common_kargs "$physical_var_path"
append_state_kargs "$physical_var_path"
run_bootc_install

persistent_var="$install_root$physical_var_path"
configure_state_subvolumes "$persistent_var"

deployment_path=$(ostree admin --sysroot="$install_root" --print-current-dir)
[[ -n $deployment_path ]] || die "OSTree did not report a current deployment"
if [[ $deployment_path == "$install_root"/* ]]; then
    config_root=$deployment_path
else
    config_root=$install_root/${deployment_path#/}
fi
[[ -d $config_root/etc ]] || die "OSTree deployment configuration root is missing: $config_root"

configure_extra_mounts "$persistent_var"
configure_first_user "$config_root" "$persistent_var"
relabel_target_paths "$config_root"
finish_installation
