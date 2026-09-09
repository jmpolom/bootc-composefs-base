#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
production_files=(
    "$root/installers/lib/storage.sh"
    "$root/installers/lib/state.sh"
    "$root/installers/lib/common.sh"
)

# These are the direct replacements for the baseline lifecycle functions. The
# small vol_* helpers are checked independently below, while this set is used
# for the aggregate gate so the before/after comparison has the same scope.
gate_specs=(
    "${production_files[0]}:validate_vol_config"
    "${production_files[0]}:vol_prepare_existing"
    "${production_files[0]}:vol_prepare_partitions"
    "${production_files[0]}:vol_prepare_filesystems"
    "${production_files[0]}:vol_prepare_subvolumes"
    "${production_files[0]}:vol_mount_phase"
    "${production_files[1]}:vol_migrate_mounts"
    "${production_files[2]}:append_common_kargs"
)
lifecycle_specs=(
    "${production_files[0]}:vol_is_root_relation"
    "${production_files[0]}:vol_validate_device"
    "${production_files[0]}:vol_validate_mount_target"
    "${production_files[0]}:vol_validate_mount_format"
    "${production_files[0]}:vol_validate_mount"
    "${production_files[0]}:vol_validate_crypto"
    "${production_files[0]}:vol_resolve_record"
    "${production_files[0]}:validate_vol_config"
    "${production_files[0]}:vol_clear_parent"
    "${production_files[0]}:vol_prepare_partitions"
    "${production_files[0]}:vol_format_filesystem"
    "${production_files[0]}:vol_materialize_credential"
    "${production_files[0]}:vol_activate_luks"
    "${production_files[0]}:vol_verify_subvolume"
    "${production_files[0]}:vol_prepare_existing"
    "${production_files[0]}:vol_prepare_filesystems"
    "${production_files[0]}:vol_create_subvolume"
    "${production_files[0]}:vol_prepare_subvolumes"
    "${production_files[0]}:vol_mount_options"
    "${production_files[0]}:vol_mount_phase"
    "${production_files[0]}:vol_prepare_storage"
    "${production_files[1]}:vol_prepare_targets"
    "${production_files[1]}:vol_migrate_mounts"
    "${production_files[2]}:append_common_kargs"
)

measure() {
    local file=$1 name=$2
    awk -v wanted="$name" '
        BEGIN { cc=1 }
        /^[A-Za-z_][A-Za-z0-9_]*\([[:space:]]*\)[[:space:]]*\{/ {
            on=($1 == wanted "()")
            next
        }
        on && /^}/ { print exec + 1, cc; exit }
        on {
            if ($0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/) exec++
            line=$0
            if (line ~ /(^|[[:space:]])(if|elif|for|while|until)([[:space:]]|\(|\[|$)/) cc++
            cc += gsub(/&&|\|\|/, "")
            if (line ~ /^[[:space:]]*case[[:space:]]/) in_case=1
            else if (in_case && line ~ /^[[:space:]]*esac/) in_case=0
            else if (in_case && line ~ /^[[:space:]]*[^*#[:space:]][^#]*\)[[:space:]]*(;;|$)/) cc++
        }
    ' "$file"
}

aggregate_loc=0
aggregate_cc=0
for spec in "${gate_specs[@]}"; do
    file=${spec%:*}; name=${spec#*:}
    read -r loc cc <<<"$(measure "$file" "$name")"
    aggregate_loc=$((aggregate_loc + loc))
    aggregate_cc=$((aggregate_cc + cc))
done
((aggregate_loc <= 350 && aggregate_cc <= 103)) || {
    printf 'lifecycle gate failed: executable LOC=%d (max 350), CC=%d (max 103)\n' "$aggregate_loc" "$aggregate_cc" >&2
    exit 1
}
for spec in "${lifecycle_specs[@]}"; do
    file=${spec%:*}; name=${spec#*:}
    read -r loc cc <<<"$(measure "$file" "$name")"
    ((loc <= 80 && cc <= 15)) || {
        printf 'lifecycle function exceeds gate: %s LOC=%d CC=%d\n' "$name" "$loc" "$cc" >&2
        exit 1
    }
done

old_names=(
    validate_ext_vol_config prepare_existing_ext_volumes prepare_partitions format_filesystems
    prepare_ext_vol_filesystems create_subvolumes mount_install_target
    configure_ext_vols format_ext_vol_filesystem root_backed_ext_vol_subvolume prepare_root_backed_ext_vol
)
for name in "${old_names[@]}"; do
    ! rg -n "^${name}[[:space:]]*\(\)" "${production_files[@]}" >/dev/null ||
        { printf 'old lifecycle function remains: %s\n' "$name" >&2; exit 1; }
done

# Public ext_vol_* arrays are an input/configuration interface. After
# normalization, lifecycle functions must consume only vol_* records; this
# catches accidental reintroduction of public-array reads with normalized
# record indexes.
allowed_public_readers='normalize_ext_vol_shortcuts|normalize_internal_volumes|validate_ext_vol_array_indexes|validate_vol_config'
for file in "${production_files[@]}"; do
    awk -v allowed="$allowed_public_readers" '
        /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)[[:space:]]*\{/ {
            name=$1; sub(/\(.*/, "", name); on=1; permitted=(name ~ ("^(" allowed ")$")); next
        }
        on && /^}/ { on=0; next }
        on && !permitted && $0 ~ /\$\{ext_vol_[A-Za-z0-9_]+/ {
            printf "%s:%d: public ext_vol_* read in lifecycle function %s\n", FILENAME, FNR, name
            found=1
        }
        END { exit found }
    ' "$file" || exit 1
done

formatter=$(rg -l '^vol_format_filesystem[[:space:]]*\(\)' "${production_files[@]}")
if [[ $(rg -n '\)[[:space:]]+mkfs\.(btrfs|ext4|xfs|vfat)' "$root/installers/lib/storage.sh" | wc -l | tr -d ' ') != 4 ]] ||
    rg -n 'mkfs\.(btrfs|ext4|xfs|vfat)' "$root/installers/lib/state.sh" >/dev/null; then
    printf 'mkfs dispatch escaped the unified formatter\n' >&2
    exit 1
fi
[[ $(rg -n 'cryptsetup luksFormat' "${production_files[@]}" | wc -l | tr -d ' ') == 1 ]] ||
    { printf 'expected one cryptsetup luksFormat call site\n' >&2; exit 1; }
[[ $(rg -n 'systemd-cryptenroll --wipe-slot=password' "${production_files[@]}" | wc -l | tr -d ' ') == 1 ]] ||
    { printf 'expected one password-slot removal call site\n' >&2; exit 1; }
[[ $(rg -n 'wipefs --all|sgdisk --zap-all' "$root/installers/lib/storage.sh" | wc -l | tr -d ' ') == 2 ]] ||
    { printf 'destructive disk operations must have one helper call site each\n' >&2; exit 1; }
[[ $(rg -n 'btrfs subvolume create' "${production_files[@]}" | wc -l | tr -d ' ') == 1 ]] ||
    { printf 'expected one btrfs subvolume create call site\n' >&2; exit 1; }
[[ $(rg -n 'cryptsetup open' "$root/installers/lib/storage.sh" | rg -v -- '--test-passphrase' | wc -l | tr -d ' ') == 1 ]] ||
    { printf 'expected one volume LUKS activation call site\n' >&2; exit 1; }
! rg -n 'ext_vol_(labels|sources|luks_uuids|luks_labels)_resolved' "${production_files[@]}" >/dev/null ||
    { printf 'legacy resolved external-volume lifecycle bridge remains\n' >&2; exit 1; }
[[ $(rg -n '^append_volume_luks_kargs[[:space:]]*\(\)' "${production_files[@]}" | wc -l | tr -d ' ') == 1 ]] ||
    { printf 'expected one common encrypted-karg emitter\n' >&2; exit 1; }
[[ $(rg -n 'append_volume_luks_kargs' "$root/installers/lib/common.sh" | wc -l | tr -d ' ') -ge 3 ]] ||
    { printf 'root and external volumes do not use the common encrypted-karg emitter\n' >&2; exit 1; }

# Generic operations are data driven. Role-specific decisions belong at the
# normalized-record boundaries, not inside formatting, encryption, or
# subvolume helpers.
for name in vol_format_filesystem vol_activate_luks vol_create_subvolume vol_prepare_subvolumes; do
    if awk -v wanted="$name" '
        /^[A-Za-z_][A-Za-z0-9_]*\([[:space:]]*\)[[:space:]]*\{/ { on=($1 == wanted "()"); next }
        on && /^}/ { exit }
        on && $0 ~ /root_subvol|root_fs_label|root_partition|root_luks|separate_|vol_backing_index|ext_vol_|\/boot|\/efi|\/var/ { found=1 }
        END { exit found }
    ' "$root/installers/lib/storage.sh"; then :; else
        printf 'role-specific branch leaked into generic helper: %s\n' "$name" >&2
        exit 1
    fi
done

printf 'storage architecture checks passed (%s), lifecycle executable LOC=%d CC=%d\n' "$formatter" "$aggregate_loc" "$aggregate_cc"
