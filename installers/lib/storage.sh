#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2178
declare -ag cleanup_mounts=() opened_luks_names=() temporary_credential_files=() external_credential_variables=() vol_list=()
is_safe_relative_subvolume() {
    local path=${1:-} part
    local -a parts=()
    case $path in
        ''|/*|*/|*//*|*[[:space:]]*|*,*|*:*|*$'\n'*) return 1 ;;
    esac
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -n $part && $part != . && $part != .. ]] || return 1
    done
}
validate_storage_label() {
    local value=$1 description=$2 limit=$3
    [[ $value =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "$description is invalid: $value"
    ((${#value} <= limit)) || die "$description is too long: $value"
}
normalize_volume_record() {
    local record=$1 field
    local -n volume=$record
    for field in encryption credential subvol_action mount_options tpm2 recovery; do
        volume["$field"]=${volume[$field]:-none}
        case $field:${volume[$field]} in
            mount_options:none) volume[mount_options]=defaults ;;
            tpm2:none|recovery:none) volume["$field"]=false ;;
        esac
    done
    if [[ -z ${volume[phase]:-} ]]; then
        volume[phase]=postdeploy
        if [[ $record == vol_root || $record == vol_boot || $record == vol_esp ]]; then
            volume[phase]=predeploy
        fi
    fi
}
validate_volume_mount_options() {
    local record=$1
    local -n volume=$record
    local options=${volume[mount_options]}
    [[ -n $options && $options != *:* && $options != *$'\n'* ]] || die "$record mount_options is invalid"
    local token
    local -a tokens=()
    IFS=, read -r -a tokens <<< "$options"
    for token in "${tokens[@]}"; do
        case "${volume[fs]}:$token" in
            btrfs:subvol=* | btrfs:subvolid=*)
                case ${volume[action]}:${volume[subvol_action]} in
                    create:*|*:none) ;;
                    *) die "$record mount_options must not select a Btrfs subvolume" ;;
                esac ;;
            btrfs:ro | ext4:ro | xfs:ro)
                [[ ${volume[action]} != create ]] ||
                    die "$record mount_options contains an incompatible option: $token" ;;
        esac
    done
}
normalize_volume_shortcuts() {
    local switch value target subvol record
    local -n root=vol_root
    for switch in separate_var separate_home separate_opt; do
        value=${!switch:-false}
        is_boolean "$value" || die "$switch must be true or false"
        [[ $value == true ]] || continue
        case $switch in
            separate_var)
                target=/var; subvol=${root[subvol]:-root}${physical_var_path} ;;
            separate_home)
                target=/var/home; subvol=${root[subvol]:-root}${physical_var_path}/home ;;
            separate_opt)
                target=/var/opt; subvol=${root[subvol]:-root}${physical_var_path}/opt ;;
        esac
        for record in "${vol_list[@]}"; do
            local -n existing=$record
            [[ ${existing[mountpoint]:-} != "$target" ]] || die "$switch conflicts with $target"
        done
        record="vol_${switch#separate_}"
        [[ $(declare -p "$record" 2>/dev/null) != 'declare -A '* ]] ||
            die "$switch conflicts with existing record $record"
        declare -g -A "$record"
        local -n generated=$record
        generated=([action]=relation [backing]=vol_root [mountpoint]=$target
            [fs]=btrfs [mount_options]=${root[mount_options]:-defaults}
            [subvol]=$subvol [subvol_action]=create [phase]=postdeploy)
        vol_list+=("$record")
        normalize_volume_record "$record"
        unset "$switch"
    done
}
record_names_valid() {
    local record declaration
    local -A seen=()
    ((${#vol_list[@]} >= 3)) || die "vol_list must begin with vol_root, vol_boot, vol_esp"
    [[ ${vol_list[0]} == vol_root && ${vol_list[1]} == vol_boot && ${vol_list[2]} == vol_esp ]] ||
        die "vol_list must explicitly begin with vol_root vol_boot vol_esp"
    for record in "${vol_list[@]}"; do
        [[ $record =~ ^vol_[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "invalid volume record name: $record"
        [[ -z ${seen[$record]:-} ]] || die "duplicate volume record: $record"
        seen[$record]=1
        declaration=$(declare -p "$record" 2>/dev/null) || die "$record was not declared by configuration"
        [[ $declaration == 'declare -A '* ]] || die "$record must be an associative array"
    done
}
validate_volume_mount() {
    local record=$1
    local -n volume=$record
    local point=${volume[mountpoint]:-}
    is_normalized_absolute_path "$point" ||
        die "$record mountpoint is invalid: $point"
    case "$point:$record" in
        /:vol_root|/boot:vol_boot|/boot/efi:vol_esp) ;;
        /:*|/boot:*|/boot/*:*|/etc:*|/etc/*:*|/usr:*|/usr/*:*|/proc:*|/proc/*:*|/sys:*|/sys/*:*|/dev:*|/dev/*:*|/run:*|/run/*:*|/state:*|/state/*:*|/sysroot:*|/sysroot/*:*)
            die "$record mountpoint is reserved: $point" ;;
    esac
    [[ -z ${installer_backend:-} ]] || validate_backend_mount_target "$point"
}
require_volume_fields() {
    local record=$1 field
    local -n volume=$record
    shift
    for field; do
        [[ -n ${volume[$field]:-} ]] || die "$record requires $field"
    done
}
remember_volume_key() {
    local map=$1 key=$2 message=$3 record=$4
    local -n seen=$map
    [[ -z ${seen[$key]:-} ]] || die "$message"
    seen[$key]=$record
}
validate_volume_format() {
    local record=$1
    local -n volume=$record
    case ${volume[action]} in
        relation)
            require_volume_fields "$record" backing fs
            [[ ${volume[encryption]} == none ]] || die "$record relation encryption is invalid"
            [[ -z ${volume[device]:-} && ${volume[fs]} == btrfs ]] || die "$record relation fields are invalid"
            ;;
        create)
            local limit
            case ${volume[fs]:-} in
                btrfs) limit=255 ;;
                ext4) limit=16 ;;
                xfs) limit=12 ;;
                vfat) limit=11 ;;
                *) die "$record create filesystem is unsupported: ${volume[fs]:-}" ;;
            esac
            require_volume_fields "$record" fs_label
            validate_storage_label "${volume[fs_label]}" "$record fs_label" "$limit"
            ;;
        retain)
            require_volume_fields "$record" device fs
            ;;
    esac
    if [[ ${volume[subvol_action]} != none ]]; then
        [[ ${volume[fs]} == btrfs ]] || die "$record subvol_action requires btrfs"
        is_safe_relative_subvolume "${volume[subvol]:-}" || die "$record subvol is invalid"
    fi
}
validate_volume_crypto() {
    local record=$1
    local -n volume=$record
    local encryption=${volume[encryption]} credential=${volume[credential]}
    case $credential in
        file)
            require_volume_fields "$record" credential_file
            [[ -f ${volume[credential_file]} && -r ${volume[credential_file]} ]] ||
                die "$record file credential is not readable" ;;
        env)
            [[ ${volume[luks_name]:-} =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
                die "$record env credential requires an identifier-safe luks_name" ;;
        ephemeral)
            [[ ${volume[action]} == create && $encryption == luks-create && ${volume[recovery]} == true ]] ||
                die "$record ephemeral credential requires recovery" ;;
    esac
    [[ $encryption == none && $credential != none ]] &&
        die "$record plaintext volume must use credential=none"
    local tpm=${volume[tpm2]} recovery=${volume[recovery]}
    is_boolean "$tpm" || die "$record tpm2 is invalid"
    is_boolean "$recovery" || die "$record recovery is invalid"
    [[ $tpm == true && $encryption == none ]] && die "$record tpm2 requires encryption"
    [[ $recovery == true && $tpm != true ]] && die "$record recovery requires tpm2"
    return 0
}
validate_volume_record() {
    local record=$1
    normalize_volume_record "$record"
    local -n volume=$record
    case ${volume[action]} in create|retain|relation) ;; *) die "$record action is invalid" ;; esac
    case ${volume[encryption]} in none|luks-create|luks-open) ;; *) die "$record encryption is invalid" ;; esac
    case ${volume[credential]} in none|prompt|file|ephemeral|env) ;; *) die "$record credential is invalid" ;; esac
    case ${volume[subvol_action]} in none|select|create) ;; *) die "$record subvol_action is invalid" ;; esac
    case ${volume[phase]} in predeploy|postdeploy) ;; *) die "$record phase is invalid" ;; esac
    validate_volume_mount "$record"
    validate_volume_format "$record"
    validate_volume_mount_options "$record"
    validate_volume_crypto "$record"
    local number=${volume[partition_number]:-}
    if [[ ${volume[action]} == create && -n $number ]]; then
        require_volume_fields "$record" partition_size partition_type partition_label parent_disk
        [[ $number =~ ^[1-9][0-9]*$ ]] || die "$record partition_number is invalid"
        [[ ${volume[partition_size]} == remainder || ${volume[partition_size]} =~ ^[1-9][0-9]*$ ]] ||
            die "$record partition_size is invalid"
    elif [[ ${volume[action]} == create ]]; then
        require_volume_fields "$record" device
        [[ -z ${volume[parent_disk]:-} ]] || die "$record cannot combine direct device and parent_disk"
    else
        [[ -z $number && -z ${volume[parent_disk]:-} ]] ||
            die "$record partition fields are only valid for created volumes"
    fi
}
validate_relation_graph() {
    local record backing walk
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[action]} == relation ]] || continue
        backing=${volume[backing]:-}
        [[ $backing =~ ^vol_[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "$record backing is invalid"
        [[ $(declare -p "$backing" 2>/dev/null) == 'declare -A '* ]] ||
            die "$record backing is not an associative record"
        walk=$record
        while :; do
            local -n current=$walk
            [[ ${current[action]} == relation ]] || break
            walk=${current[backing]:-}
            [[ $walk != "$record" ]] || die 'relation cycle'
        done
    done
}
validate_volume_devices() {
    local record parent real mounted mapped key
    local -A retain_devices=() create_parents=() direct_parents=() partition_parents=()
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[action]} == create ]] || continue
        parent=${volume[parent_disk]:-${volume[device]}}
        real=$(readlink -f -- "$parent")
        create_parents[$real]=1
        if [[ -n ${volume[parent_disk]:-} ]]; then
            partition_parents[$real]=1
        else
            direct_parents[$real]=1
        fi
    done
    for real in "${!create_parents[@]}"; do
        [[ -b $real && $(lsblk -ndo TYPE "$real") == disk ]] ||
            die "external volume parent is not a whole disk: $real"
        mounted=$(lsblk -nrpo MOUNTPOINTS "$real" | awk 'NF { print; exit }')
        [[ -z $mounted ]] || die "external volume parent has a mounted filesystem: $real"
        case ${direct_parents[$real]:-}:$real in
            1:"${target_disk_real:-}") die 'external volume direct device reuses target_disk' ;;
        esac
        case ${partition_parents[$real]:-} in
            '') continue ;;
            *)
            mapped=$(lsblk -nrpo TYPE "$real" | awk '$1 ~ /^(crypt|lvm|raid)/ { print; exit }')
            [[ -z $mapped ]] || die "external volume parent has an active mapped descendant: $real"
            ;;
        esac
    done
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[action]} == retain ]] || continue
        real=$(readlink -f -- "${volume[device]}")
        [[ -b $real ]] || die "$record device is not a block device: ${volume[device]}"
        [[ $real != "${target_disk_real:-}" ]] || die "$record retain device reuses target_disk"
        [[ -z ${retain_devices[$real]:-} ]] || die "$record retain device is listed more than once"
        retain_devices[$real]=1
        for key in "${!create_parents[@]}"; do
            [[ $real == "$key" ]] ||
                ! lsblk -nrpo NAME "$key" | awk -v wanted="$real" '$1 == wanted { found=1 } END { exit !found }' ||
                die "$record retain device is on a disk that will be erased"
        done
    done
}
validate_vol_config() {
    local record other key
    local -A paths=() names=() partitions=() labels=()
    record_names_valid
    for record in vol_root vol_boot vol_esp; do
        local -n core=$record
        require_volume_fields "$record" parent_disk partition_number partition_size partition_type partition_label
        case "$record:${core[mountpoint]}:${core[fs]}" in
            vol_root:/:btrfs|vol_boot:/boot:ext4|vol_esp:/boot/efi:vfat)
                [[ ${core[action]} == create ]] || die "$record has an invalid core layout" ;;
            *) die "$record has an invalid core layout" ;;
        esac
    done
    local size minimum spec
    for spec in 'vol_esp 128' 'vol_boot 512'; do
        read -r record minimum <<< "$spec"
        local -n core=$record
        size=${core[partition_size]}
        [[ $size =~ ^[0-9]+$ && $size -ge $minimum ]] ||
            die "$record partition_size must be at least $minimum MiB"
    done
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        validate_volume_record "$record"
        if [[ -n ${volume[luks_name]:-} ]]; then
            remember_volume_key names "${volume[luks_name]}" \
                "duplicate luks_name: ${volume[luks_name]}" "$record"
        fi
        remember_volume_key paths "${volume[mountpoint]}" \
            "duplicate mountpoint: ${volume[mountpoint]}" "$record"
        if [[ -n ${volume[partition_number]:-} ]]; then
            key="${volume[parent_disk]}:${volume[partition_number]}"
            remember_volume_key partitions "$key" \
                "duplicate partition_number on parent ${volume[parent_disk]}" "$record"
        fi
        if [[ ${volume[action]} == create ]]; then
            key=$(readlink -f -- "${volume[parent_disk]:-${volume[device]}}")
            remember_volume_key labels "${volume[fs_label]}" \
                "duplicate filesystem label: ${volume[fs_label]}" "$record"
            local label_path="/dev/disk/by-label/${volume[fs_label]}"
            if [[ -e $label_path ]]; then
                local existing parent
                existing=$(readlink -f -- "$label_path")
                parent=$(lsblk -nrpo PKNAME "$existing" | head -n1)
                [[ $existing == "$key" || $parent == "$key" ]] ||
                    die "device label belongs to another disk: $label_path"
            fi
        fi
    done
    validate_relation_graph
    validate_volume_devices
}
wait_for_device() {
    local path=$1
    local remaining=30
    while ((remaining-- > 0)); do
        udevadm settle; [[ -b $path ]] && return 0; sleep 1
    done; die "timed out waiting for $path"
}
vol_clear_parent() {
    local parent=$1
    log "Erasing storage parent $parent"; lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINTS "$parent"
    wipefs --all --force "$parent"; sgdisk --zap-all "$parent"
}
vol_prepare_partitions() {
    local record parent size resolved
    local -A parents=()
    local -a args=()
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[action]} == create && -n ${volume[partition_number]:-} ]] || continue
        parent=$(readlink -f -- "${volume[parent_disk]}"); parents[$parent]=1; done
    for parent in "${!parents[@]}"; do
        vol_clear_parent "$parent"
        args=()
        for record in "${vol_list[@]}"; do
            local -n volume=$record
            [[ $(readlink -f -- "${volume[parent_disk]:-}") == "$parent" &&
                -n ${volume[partition_number]:-} && ${volume[partition_size]} != remainder ]] || continue
            size=${volume[partition_size]}
            args+=("--new=${volume[partition_number]}:0:+${size}MiB"
                "--typecode=${volume[partition_number]}:${volume[partition_type]}"
                "--change-name=${volume[partition_number]}:${volume[partition_label]}")
        done
        for record in "${vol_list[@]}"; do
            local -n volume=$record
            [[ $(readlink -f -- "${volume[parent_disk]:-}") == "$parent" &&
                -n ${volume[partition_number]:-} && ${volume[partition_size]} == remainder ]] || continue
            args+=("--new=${volume[partition_number]}:0:0"
                "--typecode=${volume[partition_number]}:${volume[partition_type]}"
                "--change-name=${volume[partition_number]}:${volume[partition_label]}")
        done
        sgdisk "${args[@]}" "$parent"
    done
    udevadm settle
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ -n ${volume[partition_number]:-} ]] || continue
        volume[_partition_device]=/dev/disk/by-partlabel/${volume[partition_label]}; wait_for_device "${volume[_partition_device]}"
        resolved=$(readlink -f -- "${volume[_partition_device]}")
        [[ $(lsblk -nrpo PKNAME "$resolved" | head -n1) == "$(readlink -f -- "${volume[parent_disk]}")" ]] ||
            die "${volume[_partition_device]} is not on expected parent disk ${volume[parent_disk]}"
    done
}
volume_credential() {
    local output_name=$1
    local record=$2
    local -n volume=$record
    local file=''
    local variable="lvc_${volume[luks_name]:-}"
    case ${volume[credential]} in
        file) file=${volume[credential_file]} ;;
        env)
            [[ -n ${!variable+x} ]] || die "$record env credential variable is not set: $variable"
            file=$(mktemp "$work_root/vol-key.XXXXXX")
            chmod 600 "$file"
            printf '%s' "${!variable-}" > "$file"
            temporary_credential_files+=("$file")
            external_credential_variables+=("$variable")
            unset "$variable"
            ;;
        ephemeral)
            file=$(mktemp "$work_root/vol-key.XXXXXX")
            chmod 600 "$file"
            dd if=/dev/urandom of="$file" bs=64 count=1 status=none
            temporary_credential_files+=("$file")
            ;;
    esac
    printf -v "$output_name" '%s' "$file"
}
enroll_luks_credentials() {
    local record=$1
    local device=$2
    local key=$3
    local -n volume=$record
    local -a unlock=()
    [[ ${volume[tpm2]:-false} == true ]] || return 0
    [[ -n $key ]] && unlock+=("--unlock-key-file=$key")
    if [[ ${volume[recovery]:-false} == true ]]; then
        local output parsed_key recovery_uuid=${volume[_luks_uuid]}
        capture_recovery_key output "$device" "${unlock[@]}" || return $?
        parsed_key=$(grep -Eo '[bcdefghijklnrtuv]{8}(-[bcdefghijklnrtuv]{8}){7}' <<< "$output" | tail -n1)
        validate_recovery_key parsed_key || die 'systemd-cryptenroll returned an invalid recovery key'
        test_recovery_key parsed_key "$device" ||
            die "generated recovery key did not unlock $record"
        write_recovery_key_record recovery_uuid parsed_key "$recovery_key_output_file"
    fi
    local -a enroll=(--tpm2-device=auto)
    [[ -n ${volume[tpm2_pcrs]:-} ]] &&
        enroll+=("--tpm2-pcrs=${volume[tpm2_pcrs]}")
    systemd-cryptenroll "${unlock[@]}" "${enroll[@]}" "$device"
}
vol_activate_luks() {
    local record=$1
    local -n volume=$record
    local device=${volume[_partition_device]:-${volume[device]}}
    local key=''
    volume_credential key "$record"
    local -a args=()
    if [[ ${volume[encryption]} == luks-create ]]; then
        args=(--type luks2 --label "${volume[luks_label]}")
        [[ -n $key ]] && args+=(--batch-mode --key-file "$key")
        cryptsetup luksFormat "${args[@]}" "$device"
    fi
    args=(--type luks)
    [[ -n $key ]] && args+=(--key-file "$key")
    cryptsetup open "${args[@]}" "$device" "${volume[luks_name]}"
    opened_luks_names+=("${volume[luks_name]}")
    volume[_luks_uuid]=$(cryptsetup luksUUID "$device")
    [[ -n ${volume[_luks_uuid]} ]] || die "could not determine LUKS UUID for $record"
    volume[_source]=/dev/mapper/${volume[luks_name]}
    enroll_luks_credentials "$record" "$device" "$key"
    if [[ ${volume[credential]} == ephemeral ]]; then
        systemd-cryptenroll --wipe-slot=password "$device"
    fi
}
vol_format_filesystem() {
    local record=$1
    local device=$2
    local -n volume=$record
    case ${volume[fs]} in
        btrfs) mkfs.btrfs -f -L "${volume[fs_label]}" "$device" ;;
        ext4) mkfs.ext4 -F -L "${volume[fs_label]}" "$device" ;;
        xfs) mkfs.xfs -f -L "${volume[fs_label]}" "$device" ;;
        vfat) mkfs.vfat -F 32 -n "${volume[fs_label]}" "$device" ;;
        *) die "unsupported filesystem: ${volume[fs]}" ;;
    esac
}
vol_prepare_existing() {
    local record actual
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[action]} == retain ]] || continue
        if [[ ${volume[encryption]} == none ]]; then volume[_source]=${volume[device]}; else vol_activate_luks "$record"; fi
        actual=$(blkid -s TYPE -o value "${volume[_source]}")
        [[ $actual == "${volume[fs]}" ]] || die "$record filesystem mismatch (expected ${volume[fs]}, found ${actual:-unknown})"
        volume[_fs_uuid]=$(blkid -s UUID -o value "${volume[_source]}")
        if [[ ${volume[subvol_action]} != none ]]; then
            [[ $actual == btrfs ]] || die "$record subvolume requires Btrfs"
        fi
    done
}
vol_prepare_filesystems() {
    local record device label
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[action]} == create ]] || continue
        if [[ -n ${volume[partition_number]:-} ]]; then device=${volume[_partition_device]}; else
            device=${volume[device]}; vol_clear_parent "$(readlink -f -- "$device")"
        fi
        if [[ ${volume[encryption]} == luks-create ]]; then
            vol_activate_luks "$record"
            device=${volume[_source]}
        fi
        vol_format_filesystem "$record" "$device"
        label=${volume[fs_label]}
        udevadm settle
        wait_for_device "/dev/disk/by-label/$label"
        volume[_source]=/dev/disk/by-label/$label; volume[_fs_uuid]=$(blkid -s UUID -o value "${volume[_source]}")
        [[ -n ${volume[_fs_uuid]} ]] || die "could not determine filesystem UUID for $record"
        case ${volume[mountpoint]} in /boot) boot_filesystem_uuid=${volume[_fs_uuid]} ;; /boot/efi) efi_filesystem_uuid=${volume[_fs_uuid]} ;; esac
    done
}
vol_mount_filesystem() {
    local source=$1
    local filesystem=$2
    local options=$3
    local target=$4
    mkdir -p -- "$target"
    mount -t "$filesystem" -o "$options" "$source" "$target"
}
vol_create_subvolume() {
    local source=$1
    local path=$2
    local staging=$3
    local target old_path migrated=false
    mkdir -p -- "$staging"
    vol_mount_filesystem "$source" btrfs subvolid=5 "$staging"
    cleanup_mounts+=("$staging")
    target=$staging/$path
    while [[ $target != "$staging" ]]; do
        [[ ! -L $target ]] || die "volume subvolume is a symlink: ${target#"$staging/"}"
        if [[ -e $target ]]; then [[ -d $target ]] || die "volume subvolume is not a directory: ${target#"$staging/"}"; fi
        target=${target%/*}; [[ -n $target ]] || target=$staging; done
    target=$staging/$path
    if ! btrfs subvolume show "$target" >/dev/null 2>&1; then
        if [[ -e $target ]]; then
            old_path=${target}.bootc-installer-old
            [[ ! -e $old_path && ! -L $old_path ]] || die "temporary migration path already exists: $old_path"; mv "$target" "$old_path"; migrated=true
        fi
        mkdir -p -- "$(dirname -- "$target")"; btrfs subvolume create "$target"
        if [[ $migrated == true ]]; then chown root:root "$target"; chmod 0755 "$target"; cp -a --reflink=auto "$old_path/." "$target/"; rm -rf -- "$old_path"; fi
    fi
    umount "$staging"
    unset "cleanup_mounts[$((${#cleanup_mounts[@]} - 1))]"
}
vol_mount_options() {
    local output_name=$1
    local record=$2
    local -n volume=$record
    local computed_options=${volume[mount_options]:-defaults}
    if [[ ${volume[subvol_action]:-none} != none ]]; then
        case ",$computed_options," in *,subvol=*, | *,subvolid=*,) ;; *) computed_options="$computed_options,subvol=${volume[subvol]}" ;; esac
    fi
    printf -v "$output_name" '%s' "$computed_options"
}
volume_phase_order() {
    local phase=$1 path slashes
    local record
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[phase]:-predeploy} == "$phase" ]] || continue
        path=${volume[mountpoint]}
        slashes=${path//[^\/]}
        [[ $path == / ]] && slashes=
        printf '%s\t%s\n' "${#slashes}" "$record"
    done |
        sort -n -k1,1 -k2,2 | cut -f2-
}
vol_mount_phase() {
    local phase=$1
    local record options target
    local -a order=()
    mapfile -t order < <(volume_phase_order "$phase")
    for record in "${order[@]}"; do
        local -n volume=$record
        vol_mount_options options "$record"; target=$install_root${volume[mountpoint]}
        vol_mount_filesystem "${volume[_source]}" "${volume[fs]}" "$options" "$target"; cleanup_mounts+=("$target")
    done
}
vol_prepare_storage() {
    local record backing rounds unresolved
    vol_prepare_existing
    vol_prepare_partitions
    vol_prepare_filesystems
    for ((rounds = 0; rounds <= ${#vol_list[@]}; rounds++)); do
        unresolved=false
        for record in "${vol_list[@]}"; do
            local -n volume=$record
            [[ ${volume[action]} == relation && -z ${volume[_source]:-} ]] || continue
            backing=${volume[backing]}
            local -n source=$backing
            [[ -n ${source[_source]:-} ]] && volume[_source]=${source[_source]} || unresolved=true
        done
        [[ $unresolved == true ]] || break
    done
    [[ $unresolved == false ]] || die 'relation backing source is unavailable'
    for record in "${vol_list[@]}"; do
        local -n volume=$record
        [[ ${volume[subvol_action]} == create ]] || continue
        [[ -n ${volume[_source]:-} ]] || die "volume source is unavailable for $record"
        vol_create_subvolume "${volume[_source]}" "${volume[subvol]}" "$work_root/$record-top"
    done
    vol_mount_phase predeploy
}
