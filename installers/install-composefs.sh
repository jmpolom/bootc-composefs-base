#!/usr/bin/env bash
# shellcheck disable=SC2154

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$script_dir/lib/common.sh"

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

composefs_set_defaults() {
    bootloader=${bootloader:-grub}
    allow_missing_verity=${allow_missing_verity:-false}
    physical_var_path=/state/os/default/var
    root_setup_unit=bootc-root-setup.service
}

composefs_preflight() {
    local unit_source_dir=$script_dir/backends/composefs/systemd

    [[ $bootloader == grub || $bootloader == systemd ]] ||
        die "the composefs installer requires bootloader=grub or bootloader=systemd"
    is_boolean "$allow_missing_verity" || die "allow_missing_verity must be true or false"
    [[ -r $unit_source_dir/sysroot-boot.mount.in ]] ||
        die "composefs boot mount unit template is missing: $unit_source_dir/sysroot-boot.mount.in"
    [[ -r $unit_source_dir/boot.mount ]] ||
        die "composefs boot bind mount unit is missing: $unit_source_dir/boot.mount"
    [[ -r $unit_source_dir/boot-efi.mount.in ]] ||
        die "composefs EFI mount unit template is missing: $unit_source_dir/boot-efi.mount.in"
    require_bootc_options bootloader boot-mount-spec composefs-backend karg root-mount-spec \
        skip-finalize source-imgref target-imgref
}

composefs_prepare_source() {
    composefs_source_id=
    composefs_effective_source=$source_imgref
    composefs_effective_target=$target_imgref
    case $source_imgref in
        '') return 0 ;;
        docker://*)
            require_commands podman
            if ! composefs_source_id=$(TMPDIR=/var/tmp podman pull --quiet --policy=always "$source_imgref"); then
                die "failed to pull composefs source: $source_imgref"
            fi
            ;;
        containers-storage:*)
            require_commands podman
            if ! composefs_source_id=$(podman image inspect --format '{{.Id}}' "${source_imgref#containers-storage:}"); then
                die "failed to resolve composefs source: $source_imgref"
            fi
            ;;
        *) return 0 ;;
    esac
    composefs_source_id=${composefs_source_id#sha256:}
    [[ $composefs_source_id =~ ^[[:xdigit:]]{64}$ ]] || die "invalid composefs source image ID"
    composefs_source_id=sha256:${composefs_source_id,,}
    # The storage transport accepts a bare ID; sha256: is parsed as a tag.
    composefs_effective_source=containers-storage:${composefs_source_id#sha256:}
    if [[ -z $composefs_effective_target ]]; then
        composefs_effective_target=${source_imgref#docker://}
        composefs_effective_target=${composefs_effective_target#containers-storage:}
    fi
    log "Prepared composefs source image ID: $composefs_source_id"
}

composefs_install_target_path() {
    local target_root=$1 mount_point=$2
    printf '%s/state/os/default/var%s\n' "$target_root" "${mount_point#/var}"
}

composefs_build_bootc_args() {
    # shellcheck disable=SC2154
    declare -ga bootc_args=(
        install to-filesystem
        --skip-finalize
        --composefs-backend
        "--bootloader=$bootloader"
    )

    [[ -n $composefs_effective_source ]] && bootc_args+=("--source-imgref=$composefs_effective_source")
    [[ -n $composefs_effective_target ]] && bootc_args+=("--target-imgref=$composefs_effective_target")
    [[ $allow_missing_verity == true ]] && bootc_args+=(--allow-missing-verity)
    append_common_kargs "$physical_var_path" "$root_setup_unit"
}

composefs_append_external_var_karg() {
    local source=$1
    local filesystem=$2
    local options=$3

    bootc_args+=("--karg=rd.systemd.mount-extra=${source}:/sysroot${physical_var_path}:${filesystem}:${options},x-systemd.before=${root_setup_unit}")
}

composefs_locate_deployment() {
    local -a composefs_states=()
    local -a digest_args=(container compute-composefs-digest-from-storage)
    local digest

    # Unsupported external transports must never select the installer's image.
    if [[ -z $source_imgref || -n $composefs_source_id ]]; then
        [[ -n $composefs_source_id ]] && digest_args+=("$composefs_source_id")
        if digest=$(RUST_LOG=$rust_log TMPDIR=/var/tmp bootc "${digest_args[@]}"); then
            if [[ $digest =~ ^[[:xdigit:]]{128}$ ]]; then
                config_root=$install_root/state/deploy/$digest
                [[ -d $config_root/etc ]] || die "composefs digest configuration root is missing: $config_root"
                log "Composefs deployment lookup: computed digest $digest; directory $config_root; source ID ${composefs_source_id:-self}"
                return 0
            fi
            log "Warning: malformed composefs digest; using singleton deployment fallback"
        else
            log "Warning: composefs digest computation failed; using singleton deployment fallback"
        fi
    else
        log "Warning: unsupported composefs source transport; using singleton deployment fallback"
    fi

    mapfile -t composefs_states < <(find "$install_root/state/deploy" -mindepth 1 -maxdepth 1 -type d -print)
    ((${#composefs_states[@]} == 1)) ||
        die "expected exactly one composefs deployment state, found ${#composefs_states[@]}"
    config_root=${composefs_states[0]}
    [[ -d $config_root/etc ]] || die "composefs deployment configuration root is missing: $config_root"
    log "Composefs deployment lookup: singleton fallback; directory $config_root"
}

composefs_postprocess() {
    configure_composefs_boot_mounts "$config_root" "$script_dir/backends/composefs/systemd"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    run_installer composefs "$@"
fi
