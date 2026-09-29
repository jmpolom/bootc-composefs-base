#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091
source "$root/installers/install-composefs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
die() { printf '%s\n' "$*" >&2; exit 97; }
assert_eq() { [[ $1 == "$2" ]] || die "expected '$2', got '$1'"; }
reject() { if ("$@"); then die 'expected failure'; fi; }
id=$(printf 'a%.0s' {1..64})
fixture_digest=$(printf 'b%.0s' {1..128})
source_imgref='' target_imgref='' rust_log=info bootloader=grub allow_missing_verity=false
physical_var_path=/state/os/default/var root_setup_unit=bootc-root-setup.service
install_root=$tmp/root
mkdir -p "$install_root/state/deploy/$fixture_digest/etc" "$install_root/state/deploy/other/etc"
require_commands() { :; }
append_common_kargs() { :; }
podman() {
    printf '%s\n' "$*" >>"$tmp/podman"
    [[ ${pull_fail:-false} == false ]] || return 1
    printf '%s\n' "$id"
}
bootc() {
    printf '%s\n' "$*" >>"$tmp/bootc"
    [[ ${compute_fail:-false} == false ]] || return 1
    printf '%s\n' "${compute_output:-$fixture_digest}"
}
composefs_prepare_source
composefs_build_bootc_args
[[ ${bootc_args[*]} != *--source-imgref* ]] || die 'self source argument added'
composefs_locate_deployment
assert_eq "$config_root" "$install_root/state/deploy/$fixture_digest"
assert_eq "$(<"$tmp/bootc")" 'container compute-composefs-digest-from-storage'
source_imgref=docker://registry/example:latest
composefs_prepare_source
assert_eq "$source_imgref" docker://registry/example:latest
assert_eq "$composefs_effective_target" registry/example:latest
assert_eq "$composefs_effective_source" "containers-storage:sha256:$id"
# A moved tag must not change the captured ID or cause a second lookup.
id=$(printf 'c%.0s' {1..64})
composefs_build_bootc_args
composefs_locate_deployment
[[ ${bootc_args[*]} == *"--source-imgref=$composefs_effective_source"* ]] || die 'source ID not installed'
[[ $(tail -n 1 "$tmp/bootc") == *"${composefs_source_id}" ]] || die 'source ID not computed'
assert_eq "$(wc -l <"$tmp/podman" | tr -d ' ')" 1
source_imgref=containers-storage:local:tag target_imgref=registry/update:stable
composefs_prepare_source
assert_eq "$composefs_effective_target" "$target_imgref"
assert_eq "$(tail -n 1 "$tmp/podman")" 'image inspect --format {{.Id}} local:tag'
composefs_build_bootc_args
[[ ${bootc_args[*]} == *"--target-imgref=$target_imgref"* ]] || die 'explicit update target not installed'
target_imgref=
composefs_prepare_source
assert_eq "$composefs_effective_target" local:tag
source_imgref=docker://registry/example@sha256:$id
composefs_prepare_source
assert_eq "$composefs_effective_target" "registry/example@sha256:$id"
pull_fail=true
reject composefs_prepare_source
pull_fail=false id=invalid
reject composefs_prepare_source
id=$(printf 'a%.0s' {1..64})
# Exercise real callback ordering without touching disks.
parse_options() { :; }; set_defaults() { :; }; normalize_volume_shortcuts() { :; }
validate_common_config() { :; }; composefs_set_defaults() { :; }; composefs_preflight() { :; }
cleanup() { :; }; vol_prepare_storage() { touch "$tmp/storage"; }
work_root=$tmp/work recovery_enrollment_requested=false pull_fail=true
reject run_installer composefs
[[ ! -e $tmp/storage ]] || die 'storage reached after preparation failure'
pull_fail=false source_imgref='' composefs_source_id=''
rm -rf -- "$install_root/state/deploy/other"
compute_fail=true
composefs_locate_deployment
mkdir -p "$install_root/state/deploy/other/etc"
reject composefs_locate_deployment
rm -rf -- "$install_root/state/deploy/other"
compute_fail=false compute_output=malformed
composefs_locate_deployment
compute_output=$fixture_digest
rm -d -- "$install_root/state/deploy/$fixture_digest/etc"
reject composefs_locate_deployment
mv "$install_root/state/deploy/$fixture_digest" "$install_root/state/deploy/single"
mkdir -p "$install_root/state/deploy/single/etc"
reject composefs_locate_deployment
source_imgref=oci:/external composefs_source_id=
before=$(wc -l <"$tmp/bootc")
composefs_prepare_source
assert_eq "$composefs_effective_source" "$source_imgref"
composefs_locate_deployment
assert_eq "$(wc -l <"$tmp/bootc")" "$before"
mkdir -p "$install_root/state/deploy/second/etc"
reject composefs_locate_deployment
rm -rf -- "$install_root/state/deploy/single" "$install_root/state/deploy/second"
reject composefs_locate_deployment
# shellcheck disable=SC1091
source "$root/installers/install-ostree.sh"
mkdir -p "$install_root/ostree/deploy/default/etc"
ostree() { printf '%s\n' /ostree/deploy/default; }
ostree_prepare_source
ostree_locate_deployment
assert_eq "$config_root" "$install_root/ostree/deploy/default"
printf 'composefs deployment mocks passed\n'
